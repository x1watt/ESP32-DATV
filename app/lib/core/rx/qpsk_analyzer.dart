/// QPSK analysis of one receive burst: where the signal is, how strong, and its constellation
/// and MER. A burst is short (about 1 ms at 16 MS/s), so this measures a transmitter; it does
/// not decode a stream.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'fft.dart';

class QpskResult {
  QpskResult({
    required this.symbols,
    required this.merDb,
    required this.centreOffsetHz,
    required this.levelDbfs,
    required this.snrDb,
  });

  /// Symbols after timing and carrier recovery, interleaved re/im, unit average power.
  final Float32List symbols;

  /// Modulation error ratio from hard QPSK decisions (NaN when there were too few symbols).
  final double merDb;

  /// Measured signal centre relative to the LO.
  final double centreOffsetHz;

  /// Burst RMS in dB relative to full scale.
  final double levelDbfs;

  /// Signal power inside its band over the noise floor beside it.
  final double snrDb;
}

double _rrc(double t, double b) {
  if (t.abs() < 1e-9) return 1 - b + 4 * b / math.pi;
  if ((t.abs() - 1 / (4 * b)).abs() < 1e-6) {
    return b / math.sqrt2 * ((1 + 2 / math.pi) * math.sin(math.pi / (4 * b)) + (1 - 2 / math.pi) * math.cos(math.pi / (4 * b)));
  }
  return (math.sin(math.pi * t * (1 - b)) + 4 * b * t * math.cos(math.pi * t * (1 + b))) /
      (math.pi * t * (1 - (4 * b * t) * (4 * b * t)));
}

double _log10(double x) => math.log(x) / math.ln10;

/// Analyses a QPSK signal of [baud] symbols per second expected near [offsetHz] from the LO.
/// [iq] is interleaved re/im at [fs]. [rolloff] is the RRC roll-off (DVB-S/S2: 0.35).
QpskResult analyzeQpsk(Float32List iq, double fs, double offsetHz, double baud, {double rolloff = 0.35}) {
  final n = iq.length ~/ 2;
  var pw = 0.0;
  for (var i = 0; i < iq.length; i++) {
    pw += iq[i] * iq[i];
  }
  final level = 10 * _log10(pw / n + 1e-20);

  // 1. coarse centre: power centroid near the expected offset (crystals can differ by tens of kHz)
  const nfft = 1024;
  final spec = welchSpectrumDb(iq, nfft);
  final binHz = fs / nfft;
  final lin = Float64List(nfft);
  for (var i = 0; i < nfft; i++) {
    lin[i] = math.pow(10, spec[i] / 10).toDouble();
  }
  final sortedSpec = List<double>.from(lin)..sort();
  final noise = sortedSpec[nfft ~/ 2];
  final search = 0.7 * baud + 80e3;
  var sw = 0.0, swf = 0.0;
  for (var i = 0; i < nfft; i++) {
    final f = (i - nfft ~/ 2) * binHz;
    if ((f - offsetHz).abs() > search) continue;
    if (f.abs() < binHz * 1.5) continue; // LO leakage
    final p = lin[i] - noise;
    if (p <= 0) continue;
    sw += p;
    swf += p * f;
  }
  final centre = sw > 0 ? swf / sw : offsetHz;
  // SNR: band of width baud around the centre against the noise floor
  var sig = 0.0;
  var bins = 0;
  for (var i = 0; i < nfft; i++) {
    final f = (i - nfft ~/ 2) * binHz;
    if ((f - centre).abs() <= baud / 2) {
      sig += lin[i];
      bins++;
    }
  }
  final snr = bins == 0 ? double.nan : 10 * _log10(math.max(sig / bins - noise, 1e-20) / noise);

  // 2. mix to 0 Hz and evaluate the matched filter on a grid of about 16 points per symbol
  final step = math.max(1, (fs / (16 * baud)).floor());
  final sps = fs / baud;
  const span = 6;
  final half = (span * sps).ceil();
  final taps = Float64List(2 * half + 1);
  for (var i = 0; i < taps.length; i++) {
    taps[i] = _rrc((i - half) / sps, rolloff);
  }
  final mixed = Float64List(2 * n);
  final w = -2 * math.pi * centre / fs;
  for (var i = 0; i < n; i++) {
    final c = math.cos(w * i), s = math.sin(w * i);
    final re = iq[2 * i], im = iq[2 * i + 1];
    mixed[2 * i] = re * c - im * s;
    mixed[2 * i + 1] = re * s + im * c;
  }
  final m = (n - 2 * half) ~/ step;
  if (m < 32) {
    return QpskResult(symbols: Float32List(0), merDb: double.nan, centreOffsetHz: centre, levelDbfs: level, snrDb: snr);
  }
  final gr = Float64List(m), gi = Float64List(m);
  for (var k = 0; k < m; k++) {
    final c0 = half + k * step;
    var ar = 0.0, ai = 0.0;
    for (var t = 0; t < taps.length; t++) {
      final idx = 2 * (c0 + t - half);
      ar += mixed[idx] * taps[t];
      ai += mixed[idx + 1] * taps[t];
    }
    gr[k] = ar;
    gi[k] = ai;
  }

  // 3. timing: the symbol phase with the most energy
  final q = sps / step; // grid points per symbol
  final nsym = ((m - 1) / q).floor();
  var bestPhase = 0, bestE = -1.0;
  final phases = q.ceil();
  for (var p = 0; p < phases; p++) {
    var e = 0.0;
    for (var k = 0; k < nsym; k++) {
      final j = (p + k * q).round();
      if (j >= m) break;
      e += gr[j] * gr[j] + gi[j] * gi[j];
    }
    if (e > bestE) {
      bestE = e;
      bestPhase = p;
    }
  }
  final yr = <double>[], yi = <double>[];
  for (var k = 0; k < nsym; k++) {
    final j = (bestPhase + k * q).round();
    if (j >= m) break;
    yr.add(gr[j]);
    yi.add(gi[j]);
  }
  final ns = yr.length;
  if (ns < 16) {
    return QpskResult(symbols: Float32List(0), merDb: double.nan, centreOffsetHz: centre, levelDbfs: level, snrDb: snr);
  }

  // 4. residual frequency from the 4th power (+-baud/8), then the phase
  var nf = 1;
  while (nf < 4 * ns) {
    nf <<= 1;
  }
  final fft = Fft(nf);
  final v = Float64List(2 * nf);
  for (var k = 0; k < ns; k++) {
    // y^4
    final a = yr[k], b = yi[k];
    final r2 = a * a - b * b, i2 = 2 * a * b;
    v[2 * k] = r2 * r2 - i2 * i2;
    v[2 * k + 1] = 2 * r2 * i2;
  }
  fft.transform(v);
  var bi = 0;
  var bp = -1.0;
  for (var i = 0; i < nf; i++) {
    final p = v[2 * i] * v[2 * i] + v[2 * i + 1] * v[2 * i + 1];
    final fi = i < nf ~/ 2 ? i : i - nf; // cycles per symbol x nf
    if ((fi / nf).abs() > 0.5) continue;
    if (p > bp) {
      bp = p;
      bi = fi;
    }
  }
  final dfCyclesPerSym = bi / nf / 4; // residual frequency, cycles per symbol
  final cr = Float64List(ns), ci = Float64List(ns);
  var sr = 0.0, si = 0.0;
  for (var k = 0; k < ns; k++) {
    final ph = -2 * math.pi * dfCyclesPerSym * k;
    final c = math.cos(ph), s = math.sin(ph);
    cr[k] = yr[k] * c - yi[k] * s;
    ci[k] = yr[k] * s + yi[k] * c;
    final a = cr[k], b = ci[k];
    final r2 = a * a - b * b, i2 = 2 * a * b;
    sr += r2 * r2 - i2 * i2;
    si += 2 * r2 * i2;
  }
  // QPSK points at (+-1 +-j): y^4 = -|y|^4, so the common phase is (arg - pi) / 4
  final phi = (math.atan2(si, sr) - math.pi) / 4;
  final c = math.cos(-phi), s = math.sin(-phi);
  var p2 = 0.0;
  for (var k = 0; k < ns; k++) {
    final a = cr[k] * c - ci[k] * s, b = cr[k] * s + ci[k] * c;
    cr[k] = a;
    ci[k] = b;
    p2 += a * a + b * b;
  }
  final g = 1 / math.sqrt(p2 / ns);
  final out = Float32List(2 * ns);
  var err = 0.0;
  const r = 1 / math.sqrt2;
  for (var k = 0; k < ns; k++) {
    final a = cr[k] * g, b = ci[k] * g;
    out[2 * k] = a;
    out[2 * k + 1] = b;
    final da = a >= 0 ? r : -r, db = b >= 0 ? r : -r;
    err += (a - da) * (a - da) + (b - db) * (b - db);
  }
  final mer = 10 * _log10(ns / math.max(err, 1e-12));
  return QpskResult(
    symbols: out,
    merDb: mer,
    centreOffsetHz: centre + dfCyclesPerSym * baud,
    levelDbfs: level,
    snrDb: snr,
  );
}
