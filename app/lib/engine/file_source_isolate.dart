/// The file-source isolate: demuxes an MP4, then either passes H.264/AAC through to the
/// mux (when the file fits the channel) or decodes it for the encoder isolate. Loops the file.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../core/codec/audio/aac_decoder.dart';
import '../core/codec/frame.dart';
import '../core/codec/h264dec/h264_decoder.dart';
import '../core/codec/mp4/avcc.dart';
import '../core/codec/mp4/mp4_file.dart';
import '../core/esp/tx_config.dart';
import '../platform/files/file_byte_source.dart';
import 'encoder_isolate.dart' show RawFormat;

class FileSourceArgs {
  FileSourceArgs({
    required this.path,
    required this.events,
    required this.encoder,
    required this.link,
    required this.passthrough,
    required this.audio,
  });

  final String path;
  final SendPort events;

  /// Decoded pictures and PCM go here (transcoding).
  final SendPort? encoder;

  /// Encoded access units go here (passthrough).
  final SendPort link;
  final bool passthrough, audio;
}

class FileSourceProbe {
  /// True if the file's own H.264 + AAC streams fit the channel budget (no re-encoding).
  static Future<bool> fits(String path, StreamBudget b) async {
    FileByteSource? src;
    try {
      src = FileByteSource.open(path);
      final mp4 = await Mp4File.open(src);
      final v = mp4.firstVideoTrack;
      if (v == null || v.avc == null) return false;
      final a = mp4.firstAudioTrack;
      final audioRate = a != null && a.audioObjectType == 2 ? a.avgBitrate : 0;
      // PES and TS headers cost about 5 %
      return (v.avgBitrate + audioRate) * 1.05 <= b.muxRate * 0.92;
    } catch (_) {
      return false;
    } finally {
      src?.close();
    }
  }
}

/// Seconds of media the mux may hold ahead before the file source waits.
const double _aheadSeconds = 1.5;

void fileSourceIsolateMain(FileSourceArgs a) {
  final rp = ReceivePort();
  final s = _FileSource(a);
  a.events.send({'ev': 'fileReady', 'port': rp.sendPort});
  rp.listen((m) {
    final msg = (m as Map).cast<String, Object?>();
    switch (msg['k']) {
      case 'stop':
        s.stop = true;
        rp.close();
      case 'buf':
        s.onBuffered((msg['s'] as num).toDouble());
    }
  });
  s.run().catchError((Object e, StackTrace st) {
    a.events.send({'ev': 'isolateError', 'where': 'file', 'msg': '$e', 'stack': '$st'});
  }).whenComplete(() {
    rp.close();
    Isolate.exit();
  });
}

class _FileSource {
  _FileSource(this.a);

  final FileSourceArgs a;
  bool stop = false;
  /// Highest timestamp (with the loop offset) sent so far.
  int _lastSentUs = 0;

  /// Samples up to this timestamp may be sent; set from the mux reports. Until the first
  /// report arrives nothing is sent.
  int _budgetUs = -(1 << 62);

  /// A mux report: [s] seconds are queued ahead, so another (ahead - s) may be sent.
  void onBuffered(double s) {
    _budgetUs = _lastSentUs + ((_aheadSeconds - s) * 1e6).round();
  }

  void _sent(int ptsUs) {
    if (ptsUs > _lastSentUs) _lastSentUs = ptsUs;
  }
  int _inFlight = 0;
  final ReceivePort _acks = ReceivePort();

  Future<void> _waitRoom(int ptsUs) async {
    // A timer, not a microtask: the reads complete synchronously, and without going through
    // the event loop the 'buf' and 'stop' messages would never be delivered.
    await Future<void>.delayed(Duration.zero);
    while (!stop && (ptsUs > _budgetUs || _inFlight >= 3)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> run() async {
    _acks.listen((_) => _inFlight--);
    final src = FileByteSource.open(a.path);
    try {
      final mp4 = await Mp4File.open(src);
      final v = mp4.firstVideoTrack;
      final au = a.audio ? mp4.firstAudioTrack : null;
      if (v == null || v.avc == null) {
        throw StateError('no H.264 video track (found: ${mp4.tracks.map((t) => t.codec).join(', ')})');
      }
      final useAudio = au != null && au.audioObjectType == 2 && au.audioSpecificConfig != null;
      a.events.send({
        'ev': 'fileInfo',
        'text': '${v.width}x${v.height} H.264 ${v.frameRate?.toStringAsFixed(2) ?? '?'} fps, '
            '${(v.avgBitrate / 1000).round()} kb/s'
            '${useAudio ? ' + AAC ${au.sampleRate} Hz ${(au.avgBitrate / 1000).round()} kb/s' : ''}, '
            '${a.passthrough ? 'sent as is' : 'transcoded'}',
      });
      final duration = v.durationUs > 0 ? v.durationUs : 1;
      var loop = 0;
      while (!stop) {
        await _playOnce(mp4, v, useAudio ? au : null, loop * duration);
        loop++;
      }
    } finally {
      src.close();
      _acks.close();
    }
  }

  Future<void> _playOnce(Mp4File mp4, Mp4Track v, Mp4Track? au, int offsetUs) async {
    final avc = v.avc!;
    final ids = {v.id, if (au != null) au.id};
    final dec = a.passthrough ? null : H264Decoder();
    // MP4 keeps SPS and PPS in the avcC box, not in the samples
    dec?.decodeNals([...avc.sps, ...avc.pps]);
    final aac = au == null ? null : AacDecoder.fromAudioSpecificConfig(au.audioSpecificConfig!);
    final asc = au?.audioSpecificConfig;
    void sendPictures(List<I420Frame> frames) {
      for (final f in frames) {
        final w = f.width, h = f.height;
        final buf = Uint8List(w * h * 3 ~/ 2)
          ..setRange(0, w * h, f.y)
          ..setRange(w * h, w * h + f.u.length, f.u)
          ..setRange(w * h + f.u.length, w * h + 2 * f.u.length, f.v);
        _inFlight++;
        a.encoder!.send({
          'k': 'v',
          'fmt': RawFormat.i420.index,
          'data': TransferableTypedData.fromList([buf]),
          'w': w,
          'h': h,
          'pts': f.ptsUs + offsetUs,
          'ack': _acks.sendPort,
        });
      }
    }

    await for (final s in mp4.interleaved(trackIds: ids)) {
      if (stop) return;
      final pts = s.ptsUs + offsetUs;
      await _waitRoom(pts);
      _sent(pts);
      if (s.trackId == v.id) {
        if (a.passthrough) {
          final annexB = avccToAnnexB(s.data, avc.nalLengthSize,
              prepend: s.isSync ? [_aud, ...avc.sps, ...avc.pps] : [_aud]);
          a.link.send({
            'k': 'v',
            'data': TransferableTypedData.fromList([annexB]),
            'pts': s.ptsUs + offsetUs,
            'dts': s.dtsUs + offsetUs,
            'key': s.isSync,
          });
        } else {
          sendPictures(dec!.decodeNals(splitLengthPrefixedNals(s.data, avc.nalLengthSize), ptsUs: s.ptsUs));
        }
      } else if (aac != null) {
        if (a.passthrough) {
          final hdr = adtsHeader(asc!, s.data.length);
          final frame = Uint8List(hdr.length + s.data.length)
            ..setAll(0, hdr)
            ..setAll(hdr.length, s.data);
          a.link.send({'k': 'a', 'data': TransferableTypedData.fromList([frame]), 'pts': s.ptsUs + offsetUs});
        } else {
          final pcm = aac.decodeFrame(s.data, ptsUs: s.ptsUs + offsetUs);
          if (pcm.samples.isNotEmpty) {
            a.encoder!.send({
              'k': 'a',
              'data': TransferableTypedData.fromList([pcm.samples]),
              'rate': pcm.sampleRate,
              'ch': pcm.channels,
              'pts': pcm.ptsUs,
            });
          }
        }
      }
    }
    if (dec != null) sendPictures(dec.flush());
  }
}

/// Access unit delimiter (primary_pic_type 7: any slice type).
final Uint8List _aud = Uint8List.fromList([0x09, 0xF0]);
