// Integer transform, quantisation and distortion kernels.

import 'dart:typed_data';

import 'cavlc.dart';
import 'tables.dart';

/// Forward 4x4 core transform of (src - pred) into out[ooff .. ooff + 15]
/// (raster order, row = vertical frequency).
@pragma('vm:unsafe:no-bounds-checks')
void fdct4x4(Uint8List src, int so, int ss, Uint8List pred, int po, int ps,
    Int32List out, int ooff) {
  // Horizontal pass.
  for (var y = 0; y < 4; y++) {
    final s = so + y * ss, p = po + y * ps;
    final x0 = src[s] - pred[p];
    final x1 = src[s + 1] - pred[p + 1];
    final x2 = src[s + 2] - pred[p + 2];
    final x3 = src[s + 3] - pred[p + 3];
    final s03 = x0 + x3, d03 = x0 - x3, s12 = x1 + x2, d12 = x1 - x2;
    final o = ooff + y * 4;
    out[o] = s03 + s12;
    out[o + 1] = 2 * d03 + d12;
    out[o + 2] = s03 - s12;
    out[o + 3] = d03 - 2 * d12;
  }
  // Vertical pass.
  for (var x = 0; x < 4; x++) {
    final o = ooff + x;
    final x0 = out[o], x1 = out[o + 4], x2 = out[o + 8], x3 = out[o + 12];
    final s03 = x0 + x3, d03 = x0 - x3, s12 = x1 + x2, d12 = x1 - x2;
    out[o] = s03 + s12;
    out[o + 4] = 2 * d03 + d12;
    out[o + 8] = s03 - s12;
    out[o + 12] = d03 - 2 * d12;
  }
}

/// Quantises a 4x4 block of transform coefficients. Writes levels in zig-zag
/// scan order to lev[loff ..]. When [ac] is true scan position 0 is forced
/// to zero (DC handled separately). Returns the number of nonzero levels.
@pragma('vm:unsafe:no-bounds-checks')
int quant4x4(Int32List dct, int doff, Int16List lev, int loff, int qp,
    bool intra, bool ac) {
  final mf = quantMF[qp % 6];
  final qbits = 15 + qp ~/ 6;
  final f = intra ? (1 << qbits) ~/ 3 : (1 << qbits) ~/ 6;
  var nz = 0;
  final zz = zigzag4x4;
  var i = 0;
  if (ac) {
    lev[loff] = 0;
    i = 1;
  }
  for (; i < 16; i++) {
    final r = zz[i];
    final w = dct[doff + r];
    int l;
    if (w >= 0) {
      l = (w * mf[r] + f) >> qbits;
    } else {
      l = -((-w * mf[r] + f) >> qbits);
    }
    if (l != 0) {
      if (l > maxCoeffLevel) l = maxCoeffLevel;
      if (l < -maxCoeffLevel) l = -maxCoeffLevel;
      nz++;
    }
    lev[loff + i] = l;
  }
  return nz;
}

/// Dequantises levels (scan order) into raster coefficients d (Int32List of
/// 16). If [dc] is not null it replaces coefficient 0 (already scaled).
@pragma('vm:unsafe:no-bounds-checks')
void dequant4x4(Int16List lev, int loff, int qp, Int32List d, bool ac, int dc) {
  final v = dequantV[qp % 6];
  // Multiply rather than shift: negative left shifts are not portable to JS.
  final mul = 1 << (qp ~/ 6);
  final zz = zigzag4x4;
  for (var i = 0; i < 16; i++) {
    final r = zz[i];
    d[r] = lev[loff + i] * v[r] * mul;
  }
  if (ac) d[0] = dc;
}

/// Inverse 4x4 transform of d, adds prediction and stores clipped samples.
@pragma('vm:unsafe:no-bounds-checks')
void idctAdd4x4(Int32List d, Uint8List pred, int po, int ps, Uint8List dst,
    int dOff, int ds) {
  // Horizontal (rows) first, as in 8.5.12.2.
  for (var y = 0; y < 4; y++) {
    final o = y * 4;
    final d0 = d[o], d1 = d[o + 1], d2 = d[o + 2], d3 = d[o + 3];
    final e0 = d0 + d2, e1 = d0 - d2;
    final e2 = (d1 >> 1) - d3, e3 = d1 + (d3 >> 1);
    d[o] = e0 + e3;
    d[o + 1] = e1 + e2;
    d[o + 2] = e1 - e2;
    d[o + 3] = e0 - e3;
  }
  for (var x = 0; x < 4; x++) {
    final d0 = d[x], d1 = d[x + 4], d2 = d[x + 8], d3 = d[x + 12];
    final e0 = d0 + d2, e1 = d0 - d2;
    final e2 = (d1 >> 1) - d3, e3 = d1 + (d3 >> 1);
    var p = po + x, q = dOff + x;
    var v = pred[p] + ((e0 + e3 + 32) >> 6);
    dst[q] = v < 0 ? 0 : (v > 255 ? 255 : v);
    p += ps;
    q += ds;
    v = pred[p] + ((e1 + e2 + 32) >> 6);
    dst[q] = v < 0 ? 0 : (v > 255 ? 255 : v);
    p += ps;
    q += ds;
    v = pred[p] + ((e1 - e2 + 32) >> 6);
    dst[q] = v < 0 ? 0 : (v > 255 ? 255 : v);
    p += ps;
    q += ds;
    v = pred[p] + ((e0 - e3 + 32) >> 6);
    dst[q] = v < 0 ? 0 : (v > 255 ? 255 : v);
  }
}

/// Copies a 4x4 prediction into the destination (block without residual).
@pragma('vm:unsafe:no-bounds-checks')
void copy4x4(Uint8List pred, int po, int ps, Uint8List dst, int dOff, int ds) {
  for (var y = 0; y < 4; y++) {
    final p = po + y * ps, q = dOff + y * ds;
    dst[q] = pred[p];
    dst[q + 1] = pred[p + 1];
    dst[q + 2] = pred[p + 2];
    dst[q + 3] = pred[p + 3];
  }
}

@pragma('vm:prefer-inline')
@pragma('vm:unsafe:no-bounds-checks')
/// SATD of a 4x4 block (sum of absolute Hadamard coefficients / 2).
int satd4x4(Uint8List a, int ao, int as, Uint8List b, int bo, int bs) {
  var sum = 0;
  // Rows into locals then columns; unrolled for speed.
  var r = ao, q = bo;
  var a0 = a[r] - b[q], a1 = a[r + 1] - b[q + 1];
  var a2 = a[r + 2] - b[q + 2], a3 = a[r + 3] - b[q + 3];
  final h00 = a0 + a1 + a2 + a3, h01 = a0 + a1 - a2 - a3;
  final h02 = a0 - a1 - a2 + a3, h03 = a0 - a1 + a2 - a3;
  r += as;
  q += bs;
  a0 = a[r] - b[q];
  a1 = a[r + 1] - b[q + 1];
  a2 = a[r + 2] - b[q + 2];
  a3 = a[r + 3] - b[q + 3];
  final h10 = a0 + a1 + a2 + a3, h11 = a0 + a1 - a2 - a3;
  final h12 = a0 - a1 - a2 + a3, h13 = a0 - a1 + a2 - a3;
  r += as;
  q += bs;
  a0 = a[r] - b[q];
  a1 = a[r + 1] - b[q + 1];
  a2 = a[r + 2] - b[q + 2];
  a3 = a[r + 3] - b[q + 3];
  final h20 = a0 + a1 + a2 + a3, h21 = a0 + a1 - a2 - a3;
  final h22 = a0 - a1 - a2 + a3, h23 = a0 - a1 + a2 - a3;
  r += as;
  q += bs;
  a0 = a[r] - b[q];
  a1 = a[r + 1] - b[q + 1];
  a2 = a[r + 2] - b[q + 2];
  a3 = a[r + 3] - b[q + 3];
  final h30 = a0 + a1 + a2 + a3, h31 = a0 + a1 - a2 - a3;
  final h32 = a0 - a1 - a2 + a3, h33 = a0 - a1 + a2 - a3;
  int t;
  t = h00 + h10 + h20 + h30;
  sum += t < 0 ? -t : t;
  t = h00 + h10 - h20 - h30;
  sum += t < 0 ? -t : t;
  t = h00 - h10 - h20 + h30;
  sum += t < 0 ? -t : t;
  t = h00 - h10 + h20 - h30;
  sum += t < 0 ? -t : t;
  t = h01 + h11 + h21 + h31;
  sum += t < 0 ? -t : t;
  t = h01 + h11 - h21 - h31;
  sum += t < 0 ? -t : t;
  t = h01 - h11 - h21 + h31;
  sum += t < 0 ? -t : t;
  t = h01 - h11 + h21 - h31;
  sum += t < 0 ? -t : t;
  t = h02 + h12 + h22 + h32;
  sum += t < 0 ? -t : t;
  t = h02 + h12 - h22 - h32;
  sum += t < 0 ? -t : t;
  t = h02 - h12 - h22 + h32;
  sum += t < 0 ? -t : t;
  t = h02 - h12 + h22 - h32;
  sum += t < 0 ? -t : t;
  t = h03 + h13 + h23 + h33;
  sum += t < 0 ? -t : t;
  t = h03 + h13 - h23 - h33;
  sum += t < 0 ? -t : t;
  t = h03 - h13 - h23 + h33;
  sum += t < 0 ? -t : t;
  t = h03 - h13 + h23 - h33;
  sum += t < 0 ? -t : t;
  return (sum + 1) >> 1;
}

/// SATD over a w x h area (multiples of 4).
@pragma('vm:unsafe:no-bounds-checks')
int satdWxH(Uint8List a, int ao, int as, Uint8List b, int bo, int bs, int w,
    int h) {
  var s = 0;
  for (var y = 0; y < h; y += 4) {
    for (var x = 0; x < w; x += 4) {
      s += satd4x4(a, ao + y * as + x, as, b, bo + y * bs + x, bs);
    }
  }
  return s;
}

/// SAD of a 16x16 block. Stops early once [limit] is exceeded.
@pragma('vm:unsafe:no-bounds-checks')
int sad16x16(Uint8List a, int ao, int as, Uint8List b, int bo, int bs,
    int limit) {
  var s = 0;
  for (var y = 0; y < 16; y++) {
    var p = ao + y * as, q = bo + y * bs;
    for (var x = 0; x < 16; x += 4) {
      var d = a[p] - b[q];
      s += d < 0 ? -d : d;
      d = a[p + 1] - b[q + 1];
      s += d < 0 ? -d : d;
      d = a[p + 2] - b[q + 2];
      s += d < 0 ? -d : d;
      d = a[p + 3] - b[q + 3];
      s += d < 0 ? -d : d;
      p += 4;
      q += 4;
    }
    if (s > limit) return s;
  }
  return s;
}

/// SAD of a w x h block.
@pragma('vm:unsafe:no-bounds-checks')
int sadWxH(Uint8List a, int ao, int as, Uint8List b, int bo, int bs, int w,
    int h) {
  var s = 0;
  for (var y = 0; y < h; y++) {
    final p = ao + y * as, q = bo + y * bs;
    for (var x = 0; x < w; x++) {
      final d = a[p + x] - b[q + x];
      s += d < 0 ? -d : d;
    }
  }
  return s;
}
