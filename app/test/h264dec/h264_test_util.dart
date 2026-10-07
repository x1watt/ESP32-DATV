import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:esp32_datv/core/codec/frame.dart';
import 'package:esp32_datv/core/codec/h264dec/h264dec.dart';

const String kSintel = '../media/sintel_trailer.mp4';

bool? _ffmpegOk;

/// True if system ffmpeg with libx264 is available.
bool ffmpegWithX264() {
  if (_ffmpegOk != null) return _ffmpegOk!;
  try {
    final r = Process.runSync('ffmpeg', ['-hide_banner', '-encoders']);
    _ffmpegOk = r.exitCode == 0 && (r.stdout as String).contains('libx264');
  } catch (_) {
    _ffmpegOk = false;
  }
  return _ffmpegOk!;
}

/// Reads exact byte counts from a byte stream (e.g. ffmpeg stdout).
class ExactReader {
  ExactReader(Stream<List<int>> s) {
    _sub = s.listen(
      (d) {
        _chunks.add(d is Uint8List ? d : Uint8List.fromList(d));
        _avail += d.length;
        _wake();
      },
      onDone: () {
        _done = true;
        _wake();
      },
    );
  }
  late final StreamSubscription<List<int>> _sub;
  final List<Uint8List> _chunks = [];
  int _avail = 0;
  int _off = 0;
  bool _done = false;
  Completer<void>? _waiter;

  void _wake() {
    final w = _waiter;
    _waiter = null;
    w?.complete();
  }

  Future<Uint8List?> read(int n) async {
    while (_avail < n) {
      if (_done) return null;
      _waiter = Completer<void>();
      await _waiter!.future;
    }
    final out = Uint8List(n);
    var o = 0;
    while (o < n) {
      final c = _chunks.first;
      final take = (c.length - _off) < (n - o) ? (c.length - _off) : (n - o);
      out.setRange(o, o + take, c, _off);
      o += take;
      _off += take;
      if (_off == c.length) {
        _chunks.removeAt(0);
        _off = 0;
      }
    }
    _avail -= n;
    return out;
  }

  Future<void> cancel() => _sub.cancel();
}

/// Streams ffmpeg's yuv420p decode of [path] and compares frame by frame.
class FfmpegReference {
  FfmpegReference._(this._proc, this._reader);

  static Future<FfmpegReference> start(String path) async {
    final p = await Process.start('ffmpeg', [
      '-v',
      'error',
      '-flags',
      'unaligned',
      '-i',
      path,
      '-f',
      'rawvideo',
      '-pix_fmt',
      'yuv420p',
      '-fps_mode',
      'passthrough',
      '-',
    ]);
    p.stderr.drain<void>();
    return FfmpegReference._(p, ExactReader(p.stdout));
  }

  final Process _proc;
  final ExactReader _reader;
  int frames = 0;
  int mismatches = 0;
  String firstMismatch = '';

  Future<void> check(I420Frame f) async {
    final size = f.width * f.height * 3 ~/ 2;
    final r = await _reader.read(size);
    if (r == null) {
      mismatches++;
      if (firstMismatch.isEmpty) firstMismatch = 'frame $frames: reference ended';
      frames++;
      return;
    }
    final planes = [f.y, f.u, f.v];
    var off = 0;
    for (var p = 0; p < 3; p++) {
      final pl = planes[p];
      for (var i = 0; i < pl.length; i++) {
        if (pl[i] != r[off + i]) {
          mismatches++;
          if (firstMismatch.isEmpty) {
            final w = p == 0 ? f.width : f.width >> 1;
            firstMismatch =
                'frame $frames plane $p at (${i % w},${i ~/ w}): '
                'got ${pl[i]} want ${r[off + i]}';
          }
          frames++;
          return;
        }
      }
      off += pl.length;
    }
    frames++;
  }

  /// Returns true if the reference has frames left (count mismatch).
  Future<bool> finish() async {
    final extra = await _reader.read(1);
    await _reader.cancel();
    _proc.kill();
    return extra != null;
  }
}

/// Generates an H.264 elementary stream from the sintel trailer.
String? generateStream(
  Directory dir,
  String name,
  List<String> args, {
  String scale = '160:96',
  double seconds = 1.5,
  double start = 20,
}) {
  if (!File(kSintel).existsSync()) return null;
  final out = '${dir.path}/$name.h264';
  final r = Process.runSync('ffmpeg', [
    '-v',
    'error',
    '-y',
    '-ss',
    '$start',
    '-i',
    kSintel,
    '-t',
    '$seconds',
    '-an',
    '-vf',
    'scale=$scale',
    '-c:v',
    'libx264',
    ...args,
    '-f',
    'h264',
    out,
  ]);
  if (r.exitCode != 0) throw StateError('ffmpeg failed: ${r.stderr}');
  return out;
}

/// Decodes an Annex B file NAL by NAL and compares with ffmpeg.
Future<FfmpegReference> decodeAndCompare(String path) async {
  final ref = await FfmpegReference.start(path);
  final dec = H264Decoder();
  final bytes = File(path).readAsBytesSync();
  var i = 0;
  for (final nal in H264Decoder.splitAnnexB(bytes)) {
    for (final f in dec.decodeNals([nal], ptsUs: i++)) {
      await ref.check(f);
    }
  }
  for (final f in dec.flush()) {
    await ref.check(f);
  }
  if (await ref.finish()) {
    ref.mismatches++;
    if (ref.firstMismatch.isEmpty) ref.firstMismatch = 'reference has extra frames';
  }
  return ref;
}
