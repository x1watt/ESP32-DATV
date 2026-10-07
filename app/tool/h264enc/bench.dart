// Encoder speed benchmark. For AOT numbers compile it first:
//   dart compile exe tool/h264enc/bench.dart -o /tmp/h264bench
//   /tmp/h264bench [raw640x272.yuv] [raw320x136.yuv]
// Optional raw I420 inputs (e.g. made with ffmpeg from media/) are encoded
// at 640x272 and 320x136, 24 fps; otherwise only synthetic content is used.

import 'dart:io';
import 'dart:typed_data';

import 'package:esp32_datv/core/codec/frame.dart';
import 'package:esp32_datv/core/codec/h264enc/h264_encoder.dart';

import '../../test/h264enc/synth_source.dart';

void _run(String label, int w, int h, int fps, int br, H264Preset preset,
    List<I420Frame> frames) {
  final enc = H264Encoder(H264EncoderConfig(
      width: w, height: h, fps: fps, bitrate: br, preset: preset));
  // Warm up (JIT / caches) on a few frames with a separate encoder.
  final warm = H264Encoder(H264EncoderConfig(
      width: w, height: h, fps: fps, bitrate: br, preset: preset));
  for (var i = 0; i < 5 && i < frames.length; i++) {
    warm.encode(frames[i]);
  }
  var bytes = 0;
  final sw = Stopwatch()..start();
  for (final f in frames) {
    bytes += enc.encode(f).data.length;
  }
  sw.stop();
  final n = frames.length;
  final encFps = n * 1e6 / sw.elapsedMicroseconds;
  stdout.writeln('${label.padRight(34)} ${preset.name.padRight(6)} '
      '${encFps.toStringAsFixed(1).padLeft(7)} fps  '
      '(${(encFps / fps).toStringAsFixed(2)}x realtime)  '
      '${(bytes * 8 * fps / n / 1000).toStringAsFixed(1)} kb/s');
}

List<I420Frame> _synth(int w, int h, int fps, int n) {
  final s = SynthSource(w, h);
  return [for (var i = 0; i < n; i++) s.frame(i, fps: fps)];
}

List<I420Frame> _raw(String path, int w, int h, int fps, int maxFrames) {
  final d = File(path).readAsBytesSync();
  final fs = w * h * 3 ~/ 2;
  final out = <I420Frame>[];
  for (var i = 0; i < d.length ~/ fs && i < maxFrames; i++) {
    final o = i * fs;
    out.add(I420Frame(
        w,
        h,
        Uint8List.sublistView(d, o, o + w * h),
        Uint8List.sublistView(d, o + w * h, o + w * h * 5 ~/ 4),
        Uint8List.sublistView(d, o + w * h * 5 ~/ 4, o + fs),
        ptsUs: i * 1000000 ~/ fps));
  }
  return out;
}

void main(List<String> args) {
  for (final p in H264Preset.values) {
    _run('synthetic 640x360 25fps 1M', 640, 360, 25, 1000000, p,
        _synth(640, 360, 25, 150));
    _run('synthetic 854x480 25fps 2M', 854, 480, 25, 2000000, p,
        _synth(854, 480, 25, 100));
    _run('synthetic 320x180 15fps 300k', 320, 180, 15, 300000, p,
        _synth(320, 180, 15, 150));
    _run('synthetic 160x90 10fps 40k', 160, 90, 10, 40000, p,
        _synth(160, 90, 10, 150));
    if (args.isNotEmpty) {
      _run('raw 640x272 24fps 800k', 640, 272, 24, 800000, p,
          _raw(args[0], 640, 272, 24, 300));
    }
    if (args.length > 1) {
      _run('raw 320x136 24fps 250k', 320, 136, 24, 250000, p,
          _raw(args[1], 320, 136, 24, 300));
    }
  }
}
