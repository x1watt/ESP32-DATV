// Dev-only AOT benchmark for the MP2 encoder, resampler and tone generator.
// Build and run (output binary outside the repo):
//   dart compile exe tool/audio/bench.dart -o <scratch>/bench && <scratch>/bench
// ignore_for_file: avoid_print

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:esp32_datv/core/codec/audio/mp2_encoder.dart';
import 'package:esp32_datv/core/codec/audio/resampler.dart';
import 'package:esp32_datv/core/codec/audio/tone.dart';

Int16List noise(int frames, int channels) {
  final r = math.Random(7);
  final out = Int16List(frames * channels);
  var lp = 0.0;
  for (var i = 0; i < out.length; i++) {
    lp = 0.8 * lp + 0.2 * (r.nextDouble() * 2 - 1);
    out[i] = (lp * 20000).round();
  }
  return out;
}

double best(void Function() f, {int runs = 3}) {
  var b = double.infinity;
  for (var i = 0; i < runs; i++) {
    final sw = Stopwatch()..start();
    f();
    b = math.min(b, sw.elapsedMicroseconds / 1e6);
  }
  return b;
}

void main() {
  const secs = 60;
  for (final t in const [
    [16000, 1, 8],
    [16000, 1, 16],
    [24000, 1, 32],
    [48000, 2, 96],
    [48000, 1, 64],
    [48000, 2, 128],
    [48000, 2, 192],
    [44100, 2, 128],
  ]) {
    final pcm = noise(t[0] * secs, t[1]);
    final s = best(() {
      final e = Mp2Encoder(t[0], t[1], t[2]);
      for (var p = 0; p < pcm.length; p += 4096 * t[1]) {
        e.encode(Int16List.sublistView(pcm, p, math.min(pcm.length, p + 4096 * t[1])));
      }
      e.flush();
    });
    print('mp2 ${t[0]} Hz ${t[1]} ch ${t[2]} kbps: ${(secs / s).toStringAsFixed(0)}x realtime');
  }
  for (final r in const [
    [48000, 16000, 2],
    [48000, 24000, 2],
    [44100, 24000, 2],
    [44100, 16000, 2],
    [44100, 48000, 2],
    [16000, 48000, 1],
  ]) {
    final pcm = noise(r[0] * secs, r[2]);
    final s = best(() {
      final rs = Resampler(r[0], r[1], r[2]);
      for (var p = 0; p < pcm.length; p += 4096 * r[2]) {
        rs.process(Int16List.sublistView(pcm, p, math.min(pcm.length, p + 4096 * r[2])));
      }
      rs.flush();
    });
    print('resample ${r[0]}->${r[1]} ${r[2]} ch: ${(secs / s).toStringAsFixed(0)}x realtime');
  }
  final s = best(() {
    final g = ToneGenerator(sampleRate: 48000, channels: 2);
    for (var i = 0; i < secs * 48000 ~/ 1152; i++) {
      g.next(1152);
    }
  });
  print('tone 48000 Hz 2 ch: ${(secs / s).toStringAsFixed(0)}x realtime');
}
