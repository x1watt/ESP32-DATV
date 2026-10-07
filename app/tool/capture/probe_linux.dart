// Dev-only check of the Linux capture paths on real hardware (no Flutter needed):
//
//   dart run tool/capture/probe_linux.dart [--seconds 2] [--mjpeg] [--save DIR]
//
// Lists cameras, screens and microphones, then captures from the first screen, the default
// microphone and the first camera into a counting sink and prints frame counts, fps,
// sizes, timestamp jitter and the audio level. --mjpeg forces the camera to MJPEG (tests
// the pure-Dart JPEG decoder); --save writes the last picture of each source as PGM/PPM.
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:typed_data';

import 'package:esp32_datv/platform/capture/linux_pulse.dart';
import 'package:esp32_datv/platform/capture/linux_v4l2.dart';
import 'package:esp32_datv/platform/capture/linux_x11.dart';
import 'package:esp32_datv/platform/capture/media_source.dart';
import 'package:esp32_datv/platform/capture/pixel_pack.dart';

class CountingSink implements MediaSink {
  CountingSink(this.name);
  final String name;
  final Stopwatch clock = Stopwatch()..start();
  int frames = 0, blocks = 0, samples = 0;
  int firstPts = -1, lastPts = -1, maxGap = 0, backwards = 0;
  String shape = '';
  double peak = -120, rmsSum = 0;
  Uint8List? last;
  RawFormat? lastFmt;
  int lw = 0, lh = 0, ls = 0;

  @override
  int nowUs() => clock.elapsedMicroseconds;

  void _pts(int pts) {
    if (firstPts < 0) firstPts = pts;
    if (lastPts >= 0) {
      if (pts < lastPts) backwards++;
      if (pts - lastPts > maxGap) maxGap = pts - lastPts;
    }
    lastPts = pts;
  }

  @override
  void video(RawFormat fmt, Uint8List data, int width, int height, int stride, int ptsUs) {
    frames++;
    _pts(ptsUs);
    shape = '${fmt.name} ${width}x$height stride $stride (${data.length} bytes)';
    last = data;
    lastFmt = fmt;
    lw = width;
    lh = height;
    ls = stride;
  }

  @override
  void audio(Int16List pcm, int sampleRate, int channels, int ptsUs) {
    blocks++;
    samples += pcm.length ~/ channels;
    _pts(ptsUs);
    shape = '$sampleRate Hz x$channels, ${pcm.length ~/ channels} frames/block';
    final p = peakDbfs(pcm);
    if (p > peak) peak = p;
    rmsSum += rmsDbfs(pcm);
  }

  void report(double seconds) {
    if (frames > 0) {
      final span = (lastPts - firstPts) / 1e6;
      print('  $name: $frames frames in ${seconds}s = ${(frames / seconds).toStringAsFixed(1)} fps; $shape');
      print(
        '    pts span ${span.toStringAsFixed(2)} s, max gap ${(maxGap / 1000).toStringAsFixed(1)} ms, '
        'backwards $backwards',
      );
    } else if (blocks > 0) {
      print(
        '  $name: $blocks blocks, $samples sample frames in ${seconds}s '
        '(${(samples / seconds).round()} Hz effective); $shape',
      );
      print(
        '    peak ${peak.toStringAsFixed(1)} dBFS, mean RMS ${(rmsSum / blocks).toStringAsFixed(1)} dBFS, '
        'max gap ${(maxGap / 1000).toStringAsFixed(1)} ms, backwards $backwards',
      );
    } else {
      print('  $name: nothing received');
    }
  }

  void save(String dir) {
    final d = last;
    if (d == null) return;
    final f = lastFmt!;
    final base = '$dir/${name.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')}';
    if (f == RawFormat.i420) {
      _pgm('$base.pgm', d, lw, lh, lw);
    } else if (f == RawFormat.yuyv || f == RawFormat.uyvy) {
      final y = Uint8List(lw * lh);
      final o = f == RawFormat.yuyv ? 0 : 1;
      for (var r = 0; r < lh; r++) {
        for (var c = 0; c < lw; c++) {
          y[r * lw + c] = d[r * ls + 2 * c + o];
        }
      }
      _pgm('$base.pgm', y, lw, lh, lw);
    } else {
      final rgb = Uint8List(lw * lh * 3);
      final bgr = f == RawFormat.bgra;
      for (var r = 0; r < lh; r++) {
        for (var c = 0; c < lw; c++) {
          final s = r * ls + 4 * c, t = (r * lw + c) * 3;
          rgb[t] = d[s + (bgr ? 2 : 0)];
          rgb[t + 1] = d[s + 1];
          rgb[t + 2] = d[s + (bgr ? 0 : 2)];
        }
      }
      File('$base.ppm').writeAsBytesSync([...'P6\n$lw $lh\n255\n'.codeUnits, ...rgb]);
      print('    saved $base.ppm');
    }
  }

  void _pgm(String path, Uint8List y, int w, int h, int stride) {
    File(path).writeAsBytesSync([...'P5\n$w $h\n255\n'.codeUnits, ...y.sublist(0, w * h)]);
    print('    saved $path');
  }
}

Future<void> main(List<String> args) async {
  var seconds = 2.0;
  String? saveDir;
  final mjpeg = args.contains('--mjpeg');
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--seconds') seconds = double.parse(args[++i]);
    if (args[i] == '--save') saveDir = args[++i];
  }
  print(
    'Session: XDG_SESSION_TYPE=${Platform.environment['XDG_SESSION_TYPE']} '
    'DISPLAY=${Platform.environment['DISPLAY']}',
  );
  final cams = await listV4l2Cameras();
  final screens = await listX11Screens();
  final mics = await listPulseSources();
  print('Cameras:');
  for (final c in cams) {
    print('  ${c.id}  ${c.name}');
  }
  print('Screens:${x11Unsupported() != null ? ' (${x11Unsupported()})' : ''}');
  for (final s in screens) {
    print('  ${s.id}  ${s.name}');
  }
  print('Microphones:');
  for (final m in mics) {
    print('  "${m.id}"  ${m.name}');
  }

  final runs = <(MediaSource, CountingSink)>[];
  if (screens.isNotEmpty) runs.add((x11ScreenSource(screens.first, fps: 15), CountingSink('screen')));
  if (mics.isNotEmpty) runs.add((pulseMicSource(mics.first), CountingSink('microphone')));
  if (cams.isNotEmpty) {
    runs.add((
      v4l2CameraSource(cams.first, maxWidth: 1280, fps: 25, forceFourcc: mjpeg ? 'MJPG' : null),
      CountingSink(mjpeg ? 'camera_mjpeg' : 'camera'),
    ));
  }
  print('\nCapturing ${seconds}s from ${runs.length} sources at once...');
  final started = <(MediaSource, CountingSink)>[];
  for (final (src, sink) in runs) {
    final sw = Stopwatch()..start();
    try {
      await src.start(sink);
      print('  started ${sink.name} "${src.label}" in ${sw.elapsedMilliseconds} ms');
      started.add((src, sink));
    } on CaptureError catch (e) {
      print('  ${sink.name}: $e');
    }
  }
  // reset counters so the startup time does not count
  for (final (_, sink) in started) {
    sink.frames = sink.blocks = sink.samples = 0;
    sink.firstPts = sink.lastPts = -1;
    sink.maxGap = sink.backwards = 0;
  }
  await Future<void>.delayed(Duration(milliseconds: (seconds * 1000).round()));
  for (final (src, sink) in started) {
    final sw = Stopwatch()..start();
    await src.stop();
    print('  stopped ${sink.name} in ${sw.elapsedMilliseconds} ms');
  }
  print('\nResults:');
  for (final (_, sink) in started) {
    sink.report(seconds);
    if (saveDir != null) sink.save(saveDir);
  }
}
