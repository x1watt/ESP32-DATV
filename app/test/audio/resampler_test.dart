// ignore_for_file: avoid_print

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:esp32_datv/core/codec/audio/resampler.dart';
import 'package:esp32_datv/core/codec/audio/tone.dart';
import 'package:esp32_datv/core/codec/frame.dart';
import 'package:flutter_test/flutter_test.dart';

Int16List sine(int rate, int n, double f, double amp, {int channels = 1}) {
  final out = Int16List(n * channels);
  for (var i = 0; i < n; i++) {
    final v = (amp * 32767 * math.sin(2 * math.pi * f * i / rate)).round();
    for (var c = 0; c < channels; c++) {
      out[i * channels + c] = v;
    }
  }
  return out;
}

double rmsDb(Int16List x, int from, int to) {
  var s = 0.0;
  for (var i = from; i < to; i++) {
    s += x[i] * x[i].toDouble();
  }
  return 10 * math.log(s / (to - from) / (32768.0 * 32768.0) + 1e-30) / math.ln10;
}

/// Least squares fit of a sinusoid at [f]; returns residual power relative
/// to the fitted tone power in dB.
double residualDb(Int16List y, int rate, double f, int from, int to) {
  var ss = 0.0, cc = 0.0, sc = 0.0, ys = 0.0, yc = 0.0;
  for (var i = from; i < to; i++) {
    final s = math.sin(2 * math.pi * f * i / rate), c = math.cos(2 * math.pi * f * i / rate);
    ss += s * s;
    cc += c * c;
    sc += s * c;
    ys += y[i] * s;
    yc += y[i] * c;
  }
  final det = ss * cc - sc * sc;
  final a = (ys * cc - yc * sc) / det, b = (yc * ss - ys * sc) / det;
  var er = 0.0, pw = 0.0;
  for (var i = from; i < to; i++) {
    final m = a * math.sin(2 * math.pi * f * i / rate) + b * math.cos(2 * math.pi * f * i / rate);
    er += (y[i] - m) * (y[i] - m);
    pw += m * m;
  }
  return 10 * math.log(er / pw) / math.ln10;
}

Int16List runChunked(Resampler r, Int16List x, int chunk) {
  final b = <int>[];
  for (var p = 0; p < x.length; p += chunk * r.channels) {
    b.addAll(r.process(Int16List.sublistView(x, p, math.min(x.length, p + chunk * r.channels))));
  }
  b.addAll(r.flush());
  return Int16List.fromList(b);
}

void main() {
  const ratios = [
    [48000, 16000],
    [48000, 24000],
    [44100, 24000],
    [44100, 16000],
    [44100, 48000],
    [16000, 48000],
    [24000, 48000],
    [22050, 16000],
    [8000, 44100],
  ];

  for (final r in ratios) {
    final inR = r[0], outR = r[1];
    test('resample $inR -> $outR passband, length, aliasing', () {
      final n = inR * 2;
      final lowNyq = math.min(inR, outR) / 2;
      final rs = Resampler(inR, outR, 1);
      final sw = Stopwatch()..start();
      // Passband tone at 1 kHz.
      final y = runChunked(rs, sine(inR, n, 1000, 0.8), 997);
      sw.stop();
      expect(y.length, (n * outR + inR - 1) ~/ inR);
      final edge = outR ~/ 10;
      final res = residualDb(y, outR, 1000, edge, y.length - edge);
      // Gain check: tone level preserved (passband ripple tiny).
      final lvl = rmsDb(y, edge, y.length - edge);
      final ideal = 20 * math.log(0.8 / math.sqrt2) / math.ln10;

      // Near-edge passband tone (85 percent of low Nyquist).
      final fHi = 0.85 * lowNyq;
      final y2 = runChunked(Resampler(inR, outR, 1), sine(inR, n, fHi, 0.8), 4096);
      final res2 = residualDb(y2, outR, fHi, edge, y2.length - edge);
      final lvl2 = rmsDb(y2, edge, y2.length - edge);

      String alias = '';
      if (outR < inR) {
        // Tones above the output Nyquist must vanish (aliasing rejection).
        var worst = -1000.0;
        for (final frac in [1.02, 1.1, 1.3, 1.6, 1.95]) {
          final f = frac * lowNyq;
          if (f >= inR / 2) continue;
          final ya = runChunked(Resampler(inR, outR, 1), sine(inR, n, f, 0.9), 1500);
          final l = rmsDb(ya, edge, ya.length - edge) - 20 * math.log(0.9 / math.sqrt2) / math.ln10;
          worst = math.max(worst, l);
        }
        alias = 'alias rejection ${(-worst).toStringAsFixed(1)} dB';
        expect(worst, lessThan(-85));
      } else {
        // Upsampling: images of a tone at 0.85 Nyquist must vanish; the
        // residual after fitting the tone includes them.
        alias = 'image rejection ${(-res2).toStringAsFixed(1)} dB';
      }
      print('RS $inR->$outR taps ${rs.tapsPerPhase}: 1k residual ${res.toStringAsFixed(1)} dB, '
          'gain err ${(lvl - ideal).toStringAsFixed(3)} dB; ${fHi.round()} Hz residual '
          '${res2.toStringAsFixed(1)} dB gain err ${(lvl2 - ideal).toStringAsFixed(3)} dB; $alias; '
          'JIT ${(2 / (sw.elapsedMicroseconds / 1e6)).toStringAsFixed(0)}x RT');
      expect(res, lessThan(-85));
      expect(res2, lessThan(-80));
      expect((lvl - ideal).abs(), lessThan(0.01));
      expect((lvl2 - ideal).abs(), lessThan(0.05));
    });
  }

  test('streaming equals one-shot, stereo, timestamps', () {
    final x = sine(44100, 30000, 440, 0.5, channels: 2);
    final a = runChunked(Resampler(44100, 24000, 2), x, 1 << 30);
    final b = runChunked(Resampler(44100, 24000, 2), x, 37);
    expect(a, b);
    for (var i = 0; i < a.length; i += 2) {
      expect(a[i], a[i + 1]);
    }
    final rs = Resampler(48000, 16000, 1);
    final p1 = rs.processBlock(PcmBlock(Int16List(4800), 48000, 1, ptsUs: 1000000));
    final p2 = rs.processBlock(PcmBlock(Int16List(4800), 48000, 1, ptsUs: 1100000));
    expect(p1.ptsUs, 1000000);
    expect(p2.ptsUs, 1000000 + p1.frames * 1000000 ~/ 16000);
    expect(p1.sampleRate, 16000);
  });

  test('channel mixer', () {
    final st = Int16List.fromList([100, 300, -5, -6, 32767, 32767]);
    expect(ChannelMixer.toMono(st, 2), [200, -6, 32767]);
    expect(ChannelMixer.monoToStereo(Int16List.fromList([1, 2])), [1, 1, 2, 2]);
    expect(ChannelMixer.convert(Int16List.fromList([1, 2, 3, 4, 5, 6]), 3, 2), [1, 2, 4, 5]);
    expect(ChannelMixer.convert(Int16List.fromList([7]), 1, 2), [7, 7]);
    final b = ChannelMixer.convertBlock(PcmBlock(st, 48000, 2, ptsUs: 5), 1);
    expect(b.channels, 1);
    expect(b.ptsUs, 5);
  });

  test('tone generator', () {
    final g = ToneGenerator(sampleRate: 48000, channels: 2, frequencyHz: 800, amplitude: 0.5);
    final a = g.next(1000), b = g.next(23000);
    expect(a.ptsUs, 0);
    expect(b.ptsUs, 1000 * 1000000 ~/ 48000);
    final all = Int16List.fromList([...a.samples, ...b.samples]);
    final mono = ChannelMixer.toMono(all, 2);
    expect(residualDb(mono, 48000, 800, 0, mono.length), lessThan(-80));
    expect(rmsDb(mono, 0, mono.length), closeTo(20 * math.log(0.5 / math.sqrt2) / math.ln10, 0.01));
    final g16 = ToneGenerator(sampleRate: 16000, startPtsUs: 77);
    expect(g16.next(160).ptsUs, 77);
    expect(g16.next(160).ptsUs, 77 + 10000);
  });
}
