/// The encoder isolate: raw pictures and PCM in, H.264 access units and MP2 frames out
/// (to the link isolate's mux). Also generates the test pattern and tone.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../core/codec/audio/mp2_encoder.dart';
import '../core/codec/audio/resampler.dart';
import '../core/codec/audio/tone.dart';
import '../core/codec/frame.dart';
import '../core/codec/h264enc/h264_encoder.dart';
import '../core/codec/image/convert.dart';

/// Encoder settings (sendable).
class EncoderSpec {
  const EncoderSpec({
    required this.maxWidth,
    required this.fps,
    required this.videoBitrate,
    required this.audioKbps,
    required this.audioRate,
    required this.audioChannels,
    required this.testPattern,
    this.preset = 'fast',
    this.text = '',
  });

  final int maxWidth, fps, videoBitrate;

  /// 0 = no audio.
  final int audioKbps, audioRate, audioChannels;
  final bool testPattern;
  final String preset;

  /// Text shown in the middle of the test pattern (may contain newlines).
  final String text;
}

class EncoderIsolateArgs {
  EncoderIsolateArgs(this.events, this.media, this.spec);
  final SendPort events; // to the UI
  final SendPort media; // to the link isolate
  final EncoderSpec spec;
}

/// Picture formats a source may send.
enum RawFormat { rgba, bgra, yuyv, uyvy, i420 }

void encoderIsolateMain(EncoderIsolateArgs a) {
  final rp = ReceivePort();
  final e = _Encoder(a);
  a.media.send({'k': 'feedback', 'port': rp.sendPort});
  a.events.send({'ev': 'encReady', 'port': rp.sendPort});
  rp.listen((m) {
    final msg = (m as Map).cast<String, Object?>();
    if (msg['k'] == 'stop') {
      e.stop();
      rp.close();
      Isolate.exit();
    }
    try {
      e.onMessage(msg);
    } catch (err, st) {
      a.events.send({'ev': 'isolateError', 'where': 'encoder', 'msg': '$err', 'stack': '$st'});
    }
  });
  if (a.spec.testPattern) e.startTestPattern();
}

class _Encoder {
  _Encoder(this.a);

  final EncoderIsolateArgs a;
  EncoderSpec get s => a.spec;

  H264Encoder? _h264;
  int _w = 0, _h = 0;
  int _nextPts = -1;
  int _frames = 0, _dropped = 0, _bytes = 0, _lastQp = 0;
  final Stopwatch _clock = Stopwatch()..start();
  int _lastPreviewMs = -1000, _lastStatsMs = 0;
  double _buffered = 0;
  SendPort? _sourceFeedback;

  Mp2Encoder? _mp2;
  Resampler? _rs;
  int _rsRate = 0, _rsCh = 0;
  int _audioBasePts = -1;
  int _audioFrames = 0;

  Timer? _testTimer;
  late String _text = s.text;
  ToneGenerator? _tone;

  int get _frameUs => 1000000 ~/ s.fps;

  void stop() {
    _testTimer?.cancel();
  }

  void onMessage(Map<String, Object?> m) {
    switch (m['k']) {
      case 'buf':
        _buffered = (m['s'] as num).toDouble();
        _sourceFeedback?.send({'k': 'buf', 's': _buffered});
      case 'text':
        _text = m['t'] as String? ?? '';
      case 'sourceFeedback':
        _sourceFeedback = m['port'] as SendPort?;
      case 'v':
        final fmt = RawFormat.values[m['fmt'] as int];
        final data = (m['data'] as TransferableTypedData).materialize().asUint8List();
        final pts = m['pts'] as int;
        final w = m['w'] as int, h = m['h'] as int;
        final realtime = m['live'] == true;
        _onPicture(fmt, data, w, h, m['stride'] as int? ?? w * 4, pts, realtime);
        (m['ack'] as SendPort?)?.send(pts);
      case 'a':
        final data = (m['data'] as TransferableTypedData).materialize().asInt16List();
        _onPcm(PcmBlock(data, m['rate'] as int, m['ch'] as int, ptsUs: m['pts'] as int));
    }
  }

  void startTestPattern() {
    if (s.audioKbps > 0) _tone = ToneGenerator(sampleRate: s.audioRate, channels: s.audioChannels);
    final (w, h) = fitSize(1280, 720, s.maxWidth);
    var n = 0;
    _testTimer = Timer.periodic(Duration(microseconds: _frameUs), (_) {
      // catch up on the wall clock, one frame per tick at most
      final pts = n * _frameUs;
      if (pts > _clock.elapsedMicroseconds + _frameUs) return;
      _encodeFrame(testPattern(w, h, n, s.fps, ptsUs: pts, text: _text));
      final tone = _tone;
      if (tone != null) {
        final want = ((n + 1) * _frameUs * s.audioRate / 1e6).round() - (n * _frameUs * s.audioRate / 1e6).round();
        final blk = tone.next(want)..ptsUs = pts;
        _onPcm(blk);
      }
      n++;
    });
  }

  void _onPicture(RawFormat fmt, Uint8List data, int w, int h, int stride, int pts, bool realtime) {
    // frame rate conversion: keep a frame per output slot
    if (_nextPts < 0) _nextPts = pts;
    if (pts < _nextPts - _frameUs ~/ 2) {
      _dropped++;
      return;
    }
    if (realtime && _buffered > 1.5) {
      _dropped++;
      return; // the channel cannot keep up: drop instead of building delay
    }
    _nextPts += _frameUs;
    if (pts - _nextPts > 2 * _frameUs) _nextPts = pts + _frameUs; // a gap in the source
    final (ow, oh) = _h264 == null ? fitSize(w, h, s.maxWidth) : (_w, _h);
    final I420Frame f;
    if (fmt == RawFormat.i420) {
      final cs = (w >> 1) * (h >> 1);
      final src = I420Frame(w, h, Uint8List.sublistView(data, 0, w * h), Uint8List.sublistView(data, w * h, w * h + cs),
          Uint8List.sublistView(data, w * h + cs, w * h + 2 * cs), ptsUs: pts);
      f = (w == ow && h == oh) ? src : scaleI420(src, ow, oh);
    } else {
      final pf = switch (fmt) {
        RawFormat.rgba => PackedFormat.rgba,
        RawFormat.bgra => PackedFormat.bgra,
        RawFormat.yuyv => PackedFormat.yuyv,
        _ => PackedFormat.uyvy,
      };
      f = packedToI420(data, w, h, stride, pf, ow, oh, ptsUs: pts);
    }
    _encodeFrame(f);
  }

  void _encodeFrame(I420Frame f) {
    var enc = _h264;
    if (enc == null) {
      _w = f.width;
      _h = f.height;
      enc = _h264 = H264Encoder(H264EncoderConfig(
        width: _w,
        height: _h,
        fps: s.fps,
        bitrate: s.videoBitrate,
        preset: H264Preset.values.firstWhere((p) => p.name == s.preset, orElse: () => H264Preset.fast),
      ));
    }
    if (f.width != _w || f.height != _h) f = scaleI420(f, _w, _h);
    final out = enc.encode(f);
    _frames++;
    _bytes += out.data.length;
    _lastQp = out.qp;
    a.media.send({
      'k': 'v',
      'data': TransferableTypedData.fromList([out.data]),
      'pts': f.ptsUs,
      'key': out.keyframe,
    });
    final now = _clock.elapsedMilliseconds;
    if (now - _lastPreviewMs >= 200) {
      _lastPreviewMs = now;
      final (rgba, pw, ph) = i420ToRgbaPreview(f, 320);
      a.events.send({'ev': 'preview', 'data': TransferableTypedData.fromList([rgba]), 'w': pw, 'h': ph});
    }
    if (now - _lastStatsMs >= 1000) {
      final secs = (now - _lastStatsMs) / 1000;
      a.events.send({
        'ev': 'encStats',
        'fps': _frames / secs,
        'kbps': _bytes * 8 / secs / 1000,
        'qp': _lastQp,
        'dropped': _dropped,
        'w': _w,
        'h': _h,
      });
      _lastStatsMs = now;
      _frames = 0;
      _bytes = 0;
    }
  }

  void _onPcm(PcmBlock b) {
    if (s.audioKbps <= 0) return;
    final enc = _mp2 ??= Mp2Encoder(s.audioRate, s.audioChannels, s.audioKbps);
    var samples = b.samples;
    if (b.channels != s.audioChannels) samples = ChannelMixer.convert(samples, b.channels, s.audioChannels);
    if (b.sampleRate != s.audioRate) {
      if (_rs == null || _rsRate != b.sampleRate || _rsCh != s.audioChannels) {
        _rs = Resampler(b.sampleRate, s.audioRate, s.audioChannels);
        _rsRate = b.sampleRate;
        _rsCh = s.audioChannels;
      }
      samples = _rs!.process(samples);
    }
    if (_audioBasePts < 0) _audioBasePts = b.ptsUs;
    for (final fr in enc.encode(samples)) {
      final pts = _audioBasePts + (_audioFrames * 1152 * 1000000 ~/ s.audioRate);
      _audioFrames++;
      a.media.send({'k': 'a', 'data': TransferableTypedData.fromList([fr]), 'pts': pts});
    }
  }
}
