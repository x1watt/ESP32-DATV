// Prints encode speed under the test runner (JIT). For AOT numbers use
// tool/h264enc/bench.dart compiled with `dart compile exe`.

import 'package:esp32_datv/core/codec/h264enc/h264_encoder.dart';
import 'package:test/test.dart';

import 'synth_source.dart';

void main() {
  for (final c in const [
    (640, 360, 25, 1000000),
    (320, 180, 15, 300000),
    (160, 90, 10, 40000),
  ]) {
    final (w, h, fps, br) = c;
    for (final preset in H264Preset.values) {
      test('benchmark ${w}x$h ${fps}fps ${preset.name}', () {
        final src = SynthSource(w, h);
        final frames = [for (var i = 0; i < 60; i++) src.frame(i, fps: fps)];
        final enc = H264Encoder(H264EncoderConfig(
            width: w, height: h, fps: fps, bitrate: br, preset: preset));
        // Warm up the JIT.
        for (var i = 0; i < 10; i++) {
          enc.encode(frames[i]);
        }
        final sw = Stopwatch()..start();
        for (var i = 10; i < frames.length; i++) {
          enc.encode(frames[i]);
        }
        sw.stop();
        final encFps = (frames.length - 10) * 1e6 / sw.elapsedMicroseconds;
        // ignore: avoid_print
        print('benchmark ${w}x$h ${fps}fps ${preset.name}: '
            '${encFps.toStringAsFixed(1)} fps '
            '(${(encFps / fps).toStringAsFixed(2)}x realtime, JIT)');
        expect(encFps, greaterThan(0));
      }, timeout: const Timeout(Duration(minutes: 5)));
    }
  }
}
