import 'dart:math' as math;
import 'dart:typed_data';

import 'package:esp32_datv/core/rx/burst.dart';
import 'package:esp32_datv/core/rx/qpsk_analyzer.dart';
import 'package:esp32_datv/core/ts/crc32_zlib.dart';
import 'package:test/test.dart';

double rrc(double t, double b) {
  if (t.abs() < 1e-9) return 1 - b + 4 * b / math.pi;
  if ((t.abs() - 1 / (4 * b)).abs() < 1e-6) {
    return b / math.sqrt2 * ((1 + 2 / math.pi) * math.sin(math.pi / (4 * b)) + (1 - 2 / math.pi) * math.cos(math.pi / (4 * b)));
  }
  return (math.sin(math.pi * t * (1 - b)) + 4 * b * t * math.cos(math.pi * t * (1 + b))) /
      (math.pi * t * (1 - (4 * b * t) * (4 * b * t)));
}

/// QPSK, RRC 0.35, at [fs] with [baud], shifted by [f0], plus white noise for [snrDb] in the symbol bandwidth.
Float32List synth(double fs, double baud, double f0, double snrDb, int n, {int seed = 1}) {
  final rnd = math.Random(seed);
  final sps = fs / baud;
  final nsym = (n / sps).ceil() + 20;
  final si = List.generate(nsym, (_) => rnd.nextBool() ? 1.0 : -1.0);
  final sq = List.generate(nsym, (_) => rnd.nextBool() ? 1.0 : -1.0);
  final out = Float32List(2 * n);
  final span = (6 * sps).ceil();
  final yr = Float64List(n), yi = Float64List(n);
  for (var k = 0; k < nsym; k++) {
    final c = ((k - 10) * sps).round();
    for (var t = -span; t <= span; t++) {
      final i = c + t;
      if (i < 0 || i >= n) continue;
      final h = rrc(t / sps, 0.35);
      yr[i] += si[k] * h;
      yi[i] += sq[k] * h;
    }
  }
  var p = 0.0;
  for (var i = 0; i < n; i++) {
    p += yr[i] * yr[i] + yi[i] * yi[i];
  }
  p /= n;
  // noise density so that SNR in the symbol bandwidth is snrDb
  final noiseTotal = p / math.pow(10, snrDb / 10) * (fs / baud);
  final sd = math.sqrt(noiseTotal / 2);
  double g() => math.sqrt(-2 * math.log(rnd.nextDouble() + 1e-300)) * math.cos(2 * math.pi * rnd.nextDouble());
  final a = 0.05 / math.sqrt(p);
  for (var i = 0; i < n; i++) {
    final ph = 2 * math.pi * f0 * i / fs;
    final c = math.cos(ph), s = math.sin(ph);
    final r = yr[i] * c - yi[i] * s, im = yr[i] * s + yi[i] * c;
    out[2 * i] = (a * (r + sd * g())).toDouble();
    out[2 * i + 1] = (a * (im + sd * g())).toDouble();
  }
  return out;
}

void main() {
  test('burst packing: 20-bit pairs, CRC, conjugation', () {
    // pairs (I,Q): (1,2) (-1,-512) (511,-3)
    final pairs = [(1, 2), (-1, -512), (511, -3)];
    final words = [for (final (i, q) in pairs) (i & 0x3ff) | ((q & 0x3ff) << 10)];
    final b = <int>[];
    for (var j = 0; j < words.length; j += 2) {
      final a = words[j], c = j + 1 < words.length ? words[j + 1] : 0;
      b.addAll([a & 255, (a >> 8) & 255, ((a >> 16) | (c << 4)) & 255]);
      if (j + 1 < words.length) b.addAll([(c >> 4) & 255, (c >> 12) & 255]);
    }
    final payload = Uint8List.fromList(b);
    final h = RxHeader(3, 16, 2340e6, 74, crc32Zlib(payload));
    expect(h.payloadBytes, payload.length);
    final burst = decodeBurst(h, payload)!;
    for (var k = 0; k < 3; k++) {
      expect(burst.iq[2 * k], closeTo(pairs[k].$1 / 512, 1e-9));
      expect(burst.iq[2 * k + 1], closeTo(-pairs[k].$2 / 512, 1e-9));
    }
    expect(decodeBurst(RxHeader(3, 16, 2340e6, 74, h.crc ^ 1), payload), isNull);
    expect(RxHeader.parse('RXDATA 16383 16 2340000000 74 1a2b3c4d')!.n, 16383);
  });

  test('QPSK analysis finds the signal and its MER', () {
    for (final (baud, snr) in [(125000.0, 15.0), (250000.0, 20.0), (66000.0, 12.0)]) {
      final iq = synth(16e6, baud, 530e3, snr, 16383);
      final r = analyzeQpsk(iq, 16e6, 500e3, baud);
      // ignore: avoid_print
      print('baud $baud snr $snr: centre ${(r.centreOffsetHz / 1e3).toStringAsFixed(2)} kHz, '
          'MER ${r.merDb.toStringAsFixed(1)} dB, SNR est ${r.snrDb.toStringAsFixed(1)} dB, ${r.symbols.length ~/ 2} symbols');
      expect(r.centreOffsetHz, closeTo(530e3, 0.02 * baud));
      expect(r.merDb, greaterThan(snr - 3));
      expect(r.merDb, lessThan(snr + 4));
    }
  });
}
