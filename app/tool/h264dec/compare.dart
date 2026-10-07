// Dev tool: decodes an MP4 (via the pure Dart demuxer) or a raw Annex B
// .h264 file with the pure Dart H.264 decoder and compares every frame with
// the output of the system ffmpeg (yuv420p rawvideo).
//
// Usage: dart run tool/h264dec/compare.dart <file.mp4|file.h264> [--no-ref] [--max N]
//        [--yuv reference.yuv]  (compare with a raw yuv420p file instead)
import 'dart:async';
import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';

import 'package:esp32_datv/core/codec/frame.dart';
import 'package:esp32_datv/core/codec/h264dec/h264dec.dart';
import 'package:esp32_datv/core/codec/mp4/mp4.dart';

/// Reads exact byte counts from a byte stream.
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

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: compare.dart <file> [--no-ref] [--max N]');
    exit(2);
  }
  final path = args[0];
  final useRef = !args.contains('--no-ref');
  final maxIdx = args.indexOf('--max');
  final maxFrames = maxIdx >= 0 ? int.parse(args[maxIdx + 1]) : 1 << 30;
  final bytes = File(path).readAsBytesSync();

  ExactReader? ref;
  Process? proc;
  final yuvIdx = args.indexOf('--yuv');
  if (yuvIdx >= 0) {
    ref = ExactReader(File(args[yuvIdx + 1]).openRead());
  } else if (useRef) {
    proc = await Process.start('ffmpeg', [
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
    proc.stderr.listen((d) => stderr.add(d));
    ref = ExactReader(proc.stdout);
  }

  final dec = H264Decoder();
  final sw = Stopwatch();
  var frameNo = 0;
  var mismatches = 0;
  var firstMismatch = '';
  double minPsnr = 1e9;

  Future<void> check(List<I420Frame> frames) async {
    for (final f in frames) {
      if (frameNo >= maxFrames) return;
      if (ref != null) {
        final size = f.width * f.height * 3 ~/ 2;
        final r = await ref.read(size);
        if (r == null) {
          if (firstMismatch.isEmpty) firstMismatch = 'frame $frameNo: reference ended';
          mismatches++;
        } else {
          final planes = [f.y, f.u, f.v];
          final offs = [0, f.width * f.height, f.width * f.height * 5 ~/ 4];
          final ws = [f.width, f.width >> 1, f.width >> 1];
          var bad = false;
          var sse = 0;
          for (var p = 0; p < 3; p++) {
            final pl = planes[p];
            for (var i = 0; i < pl.length; i++) {
              final d = pl[i] - r[offs[p] + i];
              if (d != 0) {
                sse += d * d;
                if (!bad && firstMismatch.isEmpty) {
                  firstMismatch =
                      'frame $frameNo plane $p x ${i % ws[p]} y ${i ~/ ws[p]} '
                      '(got ${pl[i]} want ${r[offs[p] + i]})';
                }
                bad = true;
              }
            }
          }
          if (bad) {
            mismatches++;
            final n = f.width * f.height * 3 ~/ 2;
            final mse = sse / n;
            final psnr = mse == 0 ? 99.0 : 10 * (log10(255 * 255 / mse));
            if (psnr < minPsnr) minPsnr = psnr;
          }
        }
      }
      frameNo++;
    }
  }

  var w = 0, h = 0;
  if (path.endsWith('.mp4') || path.endsWith('.mov') || path.endsWith('.m4v')) {
    final mp4 = await Mp4File.open(MemoryByteSource(bytes));
    final track = mp4.firstVideoTrack!;
    final avc = track.avc!;
    w = track.width;
    h = track.height;
    sw.start();
    dec.decodeNals([...avc.sps, ...avc.pps]);
    sw.stop();
    await for (final s in mp4.samples(track.id)) {
      final nals = splitLengthPrefixedNals(s.data, avc.nalLengthSize);
      sw.start();
      final frames = dec.decodeNals(nals, ptsUs: s.ptsUs);
      sw.stop();
      await check(frames);
      if (frameNo >= maxFrames) break;
    }
  } else {
    // Feed the Annex B stream in moderately sized chunks of whole NAL units.
    final nals = H264Decoder.splitAnnexB(bytes);
    for (var i = 0; i < nals.length; i++) {
      sw.start();
      final frames = dec.decodeNals([nals[i]], ptsUs: i);
      sw.stop();
      await check(frames);
      if (frameNo >= maxFrames) break;
    }
  }
  sw.start();
  final rest = dec.flush();
  sw.stop();
  await check(rest);
  if (ref != null) {
    final extra = await ref.read(1);
    if (extra != null && frameNo < maxFrames) {
      mismatches++;
      if (firstMismatch.isEmpty) {
        firstMismatch = 'reference has more frames than decoded ($frameNo)';
      }
    }
    await ref.cancel();
    proc?.kill();
  }
  final secs = sw.elapsedMicroseconds / 1e6;
  stdout.writeln('file: $path ${w}x$h');
  stdout.writeln(
    'frames: $frameNo  decode time: ${secs.toStringAsFixed(2)} s  '
    'fps: ${(frameNo / secs).toStringAsFixed(1)}  errors: ${dec.errorCount}',
  );
  if (useRef) {
    stdout.writeln(
      mismatches == 0
          ? 'BIT-EXACT vs ${yuvIdx >= 0 ? 'reference yuv' : 'ffmpeg'}'
          : 'MISMATCH: $mismatches frames differ, min PSNR ${minPsnr.toStringAsFixed(2)} dB, first: $firstMismatch',
    );
  }
  exit(mismatches == 0 ? 0 : 1);
}

double log10(double x) => math.log(x) / math.ln10;
