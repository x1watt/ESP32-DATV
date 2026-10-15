/// The on-air monitor isolate: gets a copy of the transport stream exactly as it goes into
/// the DVB encoder, demultiplexes it and decodes the H.264 video, so the transmit page shows
/// what is being sent (not the camera or file before encoding). It reports a picture a few
/// times per second and the stream contents once per second.
library;

import 'dart:isolate';

import '../core/codec/frame.dart';
import '../core/codec/h264dec/h264_decoder.dart';
import '../core/codec/image/convert.dart';
import '../core/ts/demux.dart';

class MonitorIsolateArgs {
  MonitorIsolateArgs(this.events);
  final SendPort events; // to the UI
}

void monitorIsolateMain(MonitorIsolateArgs a) {
  final rp = ReceivePort();
  final m = _Monitor(a.events);
  a.events.send({'ev': 'monitorReady', 'port': rp.sendPort});
  rp.listen((msg) {
    final x = (msg as Map).cast<String, Object?>();
    if (x['k'] == 'stop') {
      rp.close();
      Isolate.exit();
    }
    try {
      m.onTs(x);
    } catch (err, st) {
      a.events.send({'ev': 'isolateError', 'where': 'monitor', 'msg': '$err', 'stack': '$st'});
    }
    (x['ack'] as SendPort?)?.send(null);
  });
}

class _Monitor {
  _Monitor(this.events) {
    _demux = TsDemuxer(onPes: _onPes);
  }

  final SendPort events;
  late final TsDemuxer _demux;
  H264Decoder _dec = H264Decoder();
  bool _waitIdr = true;
  final Stopwatch _clock = Stopwatch()..start();
  int _lastPreviewMs = -1000, _lastInfoMs = 0;
  int _frames = 0, _framesSince = 0, _gaps = 0, _audioPes = 0;
  int _w = 0, _h = 0;
  String? _videoNote;
  I420Frame? _last;

  void onTs(Map<String, Object?> x) {
    if (x['gap'] == true) {
      // the link skipped data while this isolate was busy: restart at the next IDR picture
      _gaps++;
      _demux.discontinuity();
      _waitIdr = true;
    }
    _demux.feed((x['data'] as TransferableTypedData).materialize().asUint8List());
    final now = _clock.elapsedMilliseconds;
    final f = _last;
    if (f != null && now - _lastPreviewMs >= 250) {
      _lastPreviewMs = now;
      _last = null;
      final (rgba, pw, ph) = i420ToRgbaPreview(f, 480);
      events.send({'ev': 'preview', 'data': TransferableTypedData.fromList([rgba]), 'w': pw, 'h': ph});
    }
    if (now - _lastInfoMs >= 1000) {
      final secs = (now - _lastInfoMs) / 1000;
      _lastInfoMs = now;
      final d = _demux;
      events.send({
        'ev': 'monitorInfo',
        'service': d.serviceName,
        'provider': d.providerName,
        'streams': [for (final s in d.streams) '${s.label} (PID 0x${s.pid.toRadixString(16).padLeft(4, '0')})'],
        'packets': d.packets,
        'null': d.nullPackets,
        'ccErrors': d.ccErrors + d.syncErrors + d.crcErrors,
        'frames': _frames,
        'fps': _framesSince / secs,
        'w': _w,
        'h': _h,
        'decErrors': _dec.errorCount,
        'gaps': _gaps,
        'audioPes': _audioPes,
        'note': _videoNote,
      });
      _framesSince = 0;
    }
  }

  void _onPes(PesPacket p) {
    final s = _demux.streams.firstWhere((s) => s.pid == p.pid);
    if (!s.isVideo) {
      _audioPes++;
      return;
    }
    if (_demux.streams.firstWhere((s) => s.isVideo).pid != p.pid) return; // first video only
    if (s.type != 0x1B) {
      _videoNote = '${s.label} cannot be shown (only H.264)';
      return;
    }
    final nals = H264Decoder.splitAnnexB(p.data);
    if (_waitIdr) {
      if (!nals.any((n) => n.isNotEmpty && (n[0] & 0x1F) == 5)) return;
      _waitIdr = false;
      _dec = H264Decoder();
    }
    try {
      for (final f in _dec.decodeNals(nals, ptsUs: p.ptsUs ?? 0)) {
        _frames++;
        _framesSince++;
        _w = f.width;
        _h = f.height;
        _last = f;
      }
      _videoNote = null;
    } on UnsupportedError catch (e) {
      _videoNote = 'The video cannot be shown: ${e.message}';
      _waitIdr = true;
    }
  }
}
