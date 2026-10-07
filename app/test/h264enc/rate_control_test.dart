// Regression: the transport mux has no headroom, so the long-term average
// must never exceed the target and short windows must stay close to it.

import 'package:esp32_datv/core/codec/h264enc/h264_encoder.dart';
import 'package:esp32_datv/core/codec/image/convert.dart';
import 'package:test/test.dart';

import 'synth_source.dart';

class _RcResult {
  _RcResult(this.avg, this.maxWindow, this.minWindow, this.peak, this.vbv,
      this.violations);
  final double avg, maxWindow, minWindow;
  final double peak;
  final int vbv, violations;
}

_RcResult _run(int w, int h, int fps, int br, H264Preset preset,
    {bool synthetic = false, int seconds = 10, int? feedFps}) {
  final enc = H264Encoder(H264EncoderConfig(
      width: w, height: h, fps: fps, bitrate: br, preset: preset));
  final synth = synthetic ? SynthSource(w, h) : null;
  // Frames may be fed at a different rate than configured; windows and
  // averages are measured on the pts time line.
  final rate = feedFps ?? fps;
  final n = rate * seconds;
  final sizes = <int>[];
  for (var i = 0; i < n; i++) {
    final f = synthetic
        ? (synth!.frame(i, fps: rate)..ptsUs = i * 1000000 ~/ rate)
        : testPattern(w, h, i, rate, ptsUs: i * 1000000 ~/ rate);
    sizes.add(enc.encode(f).data.length * 8);
  }
  final total = sizes.fold<int>(0, (a, b) => a + b);
  final win = 2 * rate;
  var maxW = 0.0, minW = double.infinity;
  var s = 0;
  for (var i = 0; i < n; i++) {
    s += sizes[i];
    if (i >= win) s -= sizes[i - win];
    if (i >= win - 1) {
      final r = s / 2.0;
      if (r > maxW) maxW = r;
      if (r < minW) minW = r;
    }
  }
  return _RcResult(total / seconds, maxW, minW, enc.vbvPeak,
      enc.config.vbvBits, enc.vbvViolations);
}

void main() {
  test('frames fed faster than the configured fps stay within budget', () {
    final r = _run(160, 90, 10, 34000, H264Preset.fast, feedFps: 15);
    // ignore: avoid_print
    print('160x90 cfg 10fps fed 15fps 34k: avg '
        '${(r.avg / 1000).toStringAsFixed(1)} kb/s, max 2s window '
        '${(r.maxWindow / 1000).toStringAsFixed(1)} kb/s');
    expect(r.avg, lessThanOrEqualTo(34000));
    expect(r.maxWindow, lessThanOrEqualTo(34000 * 1.15));
  });

  const cases = <List<int>>[
    [160, 90, 10, 34000],
    [320, 180, 15, 150000],
    [640, 360, 25, 600000],
  ];
  for (final c in cases) {
    for (final preset in H264Preset.values) {
      for (final synthetic in [false, true]) {
        final name = '${c[0]}x${c[1]} ${c[2]}fps ${c[3] ~/ 1000}k '
            '${preset.name} ${synthetic ? "synthetic" : "testPattern"}';
        test('rate: $name', () {
          final r = _run(c[0], c[1], c[2], c[3], preset, synthetic: synthetic);
          // ignore: avoid_print
          print('$name: avg ${(r.avg / 1000).toStringAsFixed(1)} kb/s, '
              '2s windows ${(r.minWindow / 1000).toStringAsFixed(1)}..'
              '${(r.maxWindow / 1000).toStringAsFixed(1)} kb/s, '
              'vbv peak ${r.peak.round()}/${r.vbv}');
          expect(r.avg, lessThanOrEqualTo(c[3]));
          expect(r.maxWindow, lessThanOrEqualTo(c[3] * 1.15));
          expect(r.peak, lessThanOrEqualTo(r.vbv));
          expect(r.violations, 0);
        }, timeout: const Timeout(Duration(minutes: 5)));
      }
    }
  }
}
