/// Shared plumbing for capture sources whose loop blocks (ioctl, XShmGetImage, pa_simple_read,
/// ReadSample...): the loop runs in its own isolate and posts pictures/PCM as
/// TransferableTypedData; the main isolate only re-stamps them and hands them to the sink.
///
/// Stop and back-pressure use a tiny block of native memory shared with the isolate (each
/// word has exactly one writer, so no atomics are needed):
///   [0] stop flag     (main writes, isolate polls between frames)
///   [1] frames sent   (isolate writes)
///   [2] frames taken  (main writes)
/// The isolate drops a picture when more than [maxPendingFrames] are still queued, so a
/// busy UI isolate never accumulates a backlog of large frames.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'media_source.dart';

const int maxPendingFrames = 2;

/// Arguments handed to a capture isolate entry point.
class CaptureIsolateArgs {
  CaptureIsolateArgs(this.port, this.ctrlAddress, this.cfg);
  final SendPort port;
  final int ctrlAddress;
  final Map<String, Object?> cfg;
}

/// Isolate side helper: stop flag, frame credits, timestamps and posting.
class CaptureIsolateContext {
  CaptureIsolateContext(this.args) : _ctrl = Pointer<Int32>.fromAddress(args.ctrlAddress) {
    _clock.start();
  }

  final CaptureIsolateArgs args;
  final Pointer<Int32> _ctrl;
  final Stopwatch _clock = Stopwatch();
  int _sent = 0;

  Map<String, Object?> get cfg => args.cfg;
  bool get stopRequested => _ctrl[0] != 0;

  /// Microseconds on this isolate's monotonic clock.
  int nowUs() => _clock.elapsedMicroseconds;

  /// True when the main isolate still has [maxPendingFrames] or more pictures queued.
  bool get congested => _sent - _ctrl[2] >= maxPendingFrames;

  void ready([String info = '']) => args.port.send({'k': 'ready', 'info': info});
  void fail(String msg) => args.port.send({'k': 'err', 'msg': msg});
  void ended([String? msg]) => args.port.send({'k': 'end', 'msg': msg});

  /// Posts a picture taken at [tUs] (this isolate's clock). Returns false when dropped.
  bool video(RawFormat fmt, Uint8List data, int w, int h, int stride, int tUs) {
    if (congested) return false;
    _sent++;
    _ctrl[1] = _sent;
    args.port.send({
      'k': 'v',
      'f': fmt.index,
      'd': TransferableTypedData.fromList([data]),
      'w': w,
      'h': h,
      's': stride,
      't': tUs,
    });
    return true;
  }

  void audio(Int16List pcm, int rate, int ch, int tUs) {
    args.port.send({
      'k': 'a',
      'd': TransferableTypedData.fromList([pcm]),
      'r': rate,
      'c': ch,
      't': tUs,
    });
  }
}

/// Keeps audio timestamps on a sample counter (smooth) and re-anchors on drift.
class AudioClock {
  AudioClock(this.rate);
  final int rate;
  int _anchorUs = 0, _samples = 0;
  bool _anchored = false;

  /// [endUs] is the time the block of [frames] samples finished arriving.
  int ptsFor(int frames, int endUs) {
    final measured = endUs - frames * 1000000 ~/ rate;
    var pts = _anchorUs + _samples * 1000000 ~/ rate;
    if (!_anchored || (pts - measured).abs() > 100000) {
      _anchored = true;
      _anchorUs = measured;
      _samples = 0;
      pts = measured;
    }
    _samples += frames;
    return pts;
  }
}

/// A [MediaSource] that runs [entry] in a new isolate.
class IsolateCaptureSource implements MediaSource {
  IsolateCaptureSource(this.label, this._entry, this._cfg, {this.onFailure});

  @override
  final String label;
  final void Function(CaptureIsolateArgs) _entry;
  final Map<String, Object?> _cfg;

  /// Called when the capture stops on its own (device unplugged, server gone...).
  void Function(String message)? onFailure;

  Isolate? _iso;
  ReceivePort? _rp, _exit, _err;
  Pointer<Int32>? _ctrl;
  int _taken = 0;
  int? _offset; // sink clock minus isolate clock, minimum observed
  bool _stopping = false;

  @override
  Future<void> start(MediaSink sink) async {
    if (_iso != null) throw CaptureError('$label is already running');
    final ctrl = calloc<Int32>(4);
    _ctrl = ctrl;
    _taken = 0;
    _offset = null;
    _stopping = false;
    final rp = ReceivePort(), exit = ReceivePort(), err = ReceivePort();
    _rp = rp;
    _exit = exit;
    _err = err;
    // uncaught isolate errors arrive as [message, stack]
    err.listen((m) => rp.sendPort.send({'k': 'err', 'msg': 'Capture failed: ${(m as List).first}'}));
    final ready = Completer<void>();
    rp.listen((m) {
      final msg = (m as Map).cast<String, Object?>();
      switch (msg['k']) {
        case 'v':
          _taken++;
          final c = _ctrl;
          if (c != null) c[2] = _taken;
          final data = (msg['d'] as TransferableTypedData).materialize().asUint8List();
          sink.video(
            RawFormat.values[msg['f'] as int],
            data,
            msg['w'] as int,
            msg['h'] as int,
            msg['s'] as int,
            _stamp(sink, msg['t'] as int),
          );
        case 'a':
          final pcm = (msg['d'] as TransferableTypedData).materialize().asInt16List();
          sink.audio(pcm, msg['r'] as int, msg['c'] as int, _stamp(sink, msg['t'] as int));
        case 'ready':
          if (!ready.isCompleted) ready.complete();
        case 'err':
          final e = CaptureError(msg['msg'] as String);
          if (!ready.isCompleted) {
            ready.completeError(e);
          } else if (!_stopping) {
            onFailure?.call(e.message);
          }
        case 'end':
          if (!_stopping && ready.isCompleted) onFailure?.call((msg['msg'] as String?) ?? '$label stopped');
      }
    });
    exit.listen((_) {
      if (!ready.isCompleted) ready.completeError(CaptureError('$label: capture isolate exited unexpectedly'));
      _cleanup();
    });
    try {
      _iso = await Isolate.spawn(
        _entry,
        CaptureIsolateArgs(rp.sendPort, ctrl.address, _cfg),
        onExit: exit.sendPort,
        onError: err.sendPort,
        debugName: 'capture: $label',
      );
      await ready.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw CaptureError('$label: device did not start within 15 s'),
      );
    } catch (e) {
      await stop();
      if (e is CaptureError) rethrow;
      throw CaptureError('$label: $e');
    }
  }

  int _stamp(MediaSink sink, int tIso) {
    final d = sink.nowUs() - tIso;
    final o = _offset;
    if (o == null || d < o) _offset = d;
    return tIso + _offset!;
  }

  @override
  Future<void> stop() async {
    final iso = _iso;
    _stopping = true;
    final ctrl = _ctrl;
    if (ctrl != null) ctrl[0] = 1;
    if (iso == null) {
      _cleanup();
      return;
    }
    // the loop checks the flag between frames; give it time to release the device
    final sw = Stopwatch()..start();
    while (_iso != null && sw.elapsedMilliseconds < 3000) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (_iso != null) {
      // stuck in a blocking call: kill it (native memory stays allocated, it may still be read)
      iso.kill(priority: Isolate.immediate);
      _iso = null;
      _rp?.close();
      _exit?.close();
      _err?.close();
      _rp = _exit = _err = null;
      _ctrl = null;
    }
  }

  void _cleanup() {
    _iso = null;
    _rp?.close();
    _exit?.close();
    _err?.close();
    _rp = _exit = _err = null;
    final c = _ctrl;
    _ctrl = null;
    if (c != null) calloc.free(c);
  }
}
