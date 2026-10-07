import 'dart:typed_data';

import 'int_util.dart';

/// Fractional sample interpolation (8.4.2.2). Output blocks are written
/// into a destination buffer with a given stride.
///
/// The filters use sliding windows so each source sample is loaded once per
/// output row or column.
class InterPred {
  static const int _es = 24; // edge buffer stride
  final Uint8List _edge = Uint8List(_es * _es);
  final Uint8List _t1 = Uint8List(256);
  final Int32List _mid = Int32List(16 * 21);

  static int _clip(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

  /// Luma prediction of a [w]x[h] block whose top-left full-sample position
  /// is (x0, y0) with quarter-sample fraction (fx, fy).
  void luma(
    Uint8List src,
    int pw,
    int ph,
    int x0,
    int y0,
    int fx,
    int fy,
    int w,
    int h,
    Uint8List dst,
    int dOff,
    int dSt,
  ) {
    Uint8List s;
    int sSt;
    int sOff;
    if (x0 >= 2 && y0 >= 2 && x0 + w + 3 <= pw && y0 + h + 3 <= ph) {
      s = src;
      sSt = pw;
      sOff = y0 * pw + x0;
    } else {
      // Emulate edges by clamping every reference coordinate.
      final e = _edge;
      for (var yy = 0; yy < h + 5; yy++) {
        var sy = y0 - 2 + yy;
        if (sy < 0) sy = 0;
        if (sy >= ph) sy = ph - 1;
        final row = sy * pw;
        final eo = yy * _es;
        for (var xx = 0; xx < w + 5; xx++) {
          var sx = x0 - 2 + xx;
          if (sx < 0) sx = 0;
          if (sx >= pw) sx = pw - 1;
          e[eo + xx] = src[row + sx];
        }
      }
      s = e;
      sSt = _es;
      sOff = 2 * _es + 2;
    }
    switch ((fy << 2) | fx) {
      case 0:
        _copy(s, sOff, sSt, dst, dOff, dSt, w, h);
        break;
      case 1:
        _hpelAvg(s, sOff, sSt, s, sOff, sSt, dst, dOff, dSt, w, h);
        break;
      case 2:
        _hpel(s, sOff, sSt, dst, dOff, dSt, w, h);
        break;
      case 3:
        _hpelAvg(s, sOff, sSt, s, sOff + 1, sSt, dst, dOff, dSt, w, h);
        break;
      case 4:
        _vpelAvg(s, sOff, sSt, s, sOff, sSt, dst, dOff, dSt, w, h);
        break;
      case 5:
        _hpel(s, sOff, sSt, _t1, 0, 16, w, h);
        _vpelAvg(s, sOff, sSt, _t1, 0, 16, dst, dOff, dSt, w, h);
        break;
      case 6:
        _cpel(s, sOff, sSt, dst, dOff, dSt, w, h, 0);
        break;
      case 7:
        _hpel(s, sOff, sSt, _t1, 0, 16, w, h);
        _vpelAvg(s, sOff + 1, sSt, _t1, 0, 16, dst, dOff, dSt, w, h);
        break;
      case 8:
        _vpel(s, sOff, sSt, dst, dOff, dSt, w, h);
        break;
      case 9:
        _cpel(s, sOff, sSt, _t1, 0, 16, w, h, -1);
        _vpelAvg(s, sOff, sSt, _t1, 0, 16, dst, dOff, dSt, w, h);
        break;
      case 10:
        _cpel(s, sOff, sSt, dst, dOff, dSt, w, h, -1);
        break;
      case 11:
        _cpel(s, sOff, sSt, _t1, 0, 16, w, h, -1);
        _vpelAvg(s, sOff + 1, sSt, _t1, 0, 16, dst, dOff, dSt, w, h);
        break;
      case 12:
        _vpelAvg(s, sOff, sSt, s, sOff + sSt, sSt, dst, dOff, dSt, w, h);
        break;
      case 13:
        _vpel(s, sOff, sSt, _t1, 0, 16, w, h);
        _hpelAvg(s, sOff + sSt, sSt, _t1, 0, 16, dst, dOff, dSt, w, h);
        break;
      case 14:
        _cpel(s, sOff, sSt, dst, dOff, dSt, w, h, 1);
        break;
      case 15:
        _vpel(s, sOff + 1, sSt, _t1, 0, 16, w, h);
        _hpelAvg(s, sOff + sSt, sSt, _t1, 0, 16, dst, dOff, dSt, w, h);
        break;
    }
  }

  static void _copy(Uint8List s, int sOff, int sSt, Uint8List d, int dOff, int dSt, int w, int h) {
    for (var y = 0; y < h; y++) {
      final so = sOff + y * sSt;
      d.setRange(dOff + y * dSt, dOff + y * dSt + w, s, so);
    }
  }

  /// Horizontal half-sample filter.
  static void _hpel(Uint8List s, int sOff, int sSt, Uint8List d, int dOff, int dSt, int w, int h) {
    for (var y = 0; y < h; y++) {
      var p = sOff + y * sSt;
      var o = dOff + y * dSt;
      var a = s[p - 2], b = s[p - 1], c = s[p], e = s[p + 1], f = s[p + 2];
      for (var x = 0; x < w; x++) {
        final g = s[p + 3];
        d[o] = _clip(asr(a - 5 * (b + f) + 20 * (c + e) + g + 16, 5));
        a = b;
        b = c;
        c = e;
        e = f;
        f = g;
        p++;
        o++;
      }
    }
  }

  /// d = (hpel(s) + q + 1) >> 1 where q is sampled from [q] at [qOff].
  static void _hpelAvg(
    Uint8List s,
    int sOff,
    int sSt,
    Uint8List q,
    int qOff,
    int qSt,
    Uint8List d,
    int dOff,
    int dSt,
    int w,
    int h,
  ) {
    for (var y = 0; y < h; y++) {
      var p = sOff + y * sSt;
      var o = dOff + y * dSt;
      var qo = qOff + y * qSt;
      var a = s[p - 2], b = s[p - 1], c = s[p], e = s[p + 1], f = s[p + 2];
      for (var x = 0; x < w; x++) {
        final g = s[p + 3];
        final v = _clip(asr(a - 5 * (b + f) + 20 * (c + e) + g + 16, 5));
        d[o] = (v + q[qo] + 1) >> 1;
        a = b;
        b = c;
        c = e;
        e = f;
        f = g;
        p++;
        o++;
        qo++;
      }
    }
  }

  /// Vertical half-sample filter.
  static void _vpel(Uint8List s, int sOff, int sSt, Uint8List d, int dOff, int dSt, int w, int h) {
    for (var x = 0; x < w; x++) {
      var p = sOff + x;
      var o = dOff + x;
      var a = s[p - 2 * sSt], b = s[p - sSt], c = s[p], e = s[p + sSt], f = s[p + 2 * sSt];
      p += 3 * sSt;
      for (var y = 0; y < h; y++) {
        final g = s[p];
        d[o] = _clip(asr(a - 5 * (b + f) + 20 * (c + e) + g + 16, 5));
        a = b;
        b = c;
        c = e;
        e = f;
        f = g;
        p += sSt;
        o += dSt;
      }
    }
  }

  /// d = (vpel(s) + q + 1) >> 1.
  static void _vpelAvg(
    Uint8List s,
    int sOff,
    int sSt,
    Uint8List q,
    int qOff,
    int qSt,
    Uint8List d,
    int dOff,
    int dSt,
    int w,
    int h,
  ) {
    for (var x = 0; x < w; x++) {
      var p = sOff + x;
      var o = dOff + x;
      var qo = qOff + x;
      var a = s[p - 2 * sSt], b = s[p - sSt], c = s[p], e = s[p + sSt], f = s[p + 2 * sSt];
      p += 3 * sSt;
      for (var y = 0; y < h; y++) {
        final g = s[p];
        final v = _clip(asr(a - 5 * (b + f) + 20 * (c + e) + g + 16, 5));
        d[o] = (v + q[qo] + 1) >> 1;
        a = b;
        b = c;
        c = e;
        e = f;
        f = g;
        p += sSt;
        o += dSt;
        qo += qSt;
      }
    }
  }

  /// Centre (j) half-sample: horizontal intermediates, then vertical filter.
  /// With [avgRow] 0 or 1 the result is averaged with the horizontal
  /// half-sample of row y (b) or y + 1 (s), taken from the intermediates.
  void _cpel(Uint8List s, int sOff, int sSt, Uint8List d, int dOff, int dSt, int w, int h,
      int avgRow) {
    final m = _mid;
    for (var y = 0; y < h + 5; y++) {
      var p = sOff + (y - 2) * sSt;
      var mo = y * 16;
      var a = s[p - 2], b = s[p - 1], c = s[p], e = s[p + 1], f = s[p + 2];
      for (var x = 0; x < w; x++) {
        final g = s[p + 3];
        m[mo] = a - 5 * (b + f) + 20 * (c + e) + g;
        a = b;
        b = c;
        c = e;
        e = f;
        f = g;
        p++;
        mo++;
      }
    }
    final hb = (2 + avgRow) * 16;
    for (var x = 0; x < w; x++) {
      var p = x;
      var o = dOff + x;
      var a = m[p], b = m[p + 16], c = m[p + 32], e = m[p + 48], f = m[p + 64];
      p += 80;
      var q = hb + x;
      for (var y = 0; y < h; y++) {
        final g = m[p];
        final j = _clip(asr(a - 5 * (b + f) + 20 * (c + e) + g + 512, 10));
        if (avgRow < 0) {
          d[o] = j;
        } else {
          d[o] = (j + _clip(asr(m[q] + 16, 5)) + 1) >> 1;
          q += 16;
        }
        a = b;
        b = c;
        c = e;
        e = f;
        f = g;
        p += 16;
        o += dSt;
      }
    }
  }

  /// Chroma prediction (8.4.2.2.2) of a [w]x[h] block at full position
  /// (x0, y0) with eighth-sample fraction (fx, fy).
  void chroma(
    Uint8List src,
    int pw,
    int ph,
    int x0,
    int y0,
    int fx,
    int fy,
    int w,
    int h,
    Uint8List dst,
    int dOff,
    int dSt,
  ) {
    Uint8List s;
    int sSt;
    int sOff;
    if (x0 >= 0 && y0 >= 0 && x0 + w + 1 <= pw && y0 + h + 1 <= ph) {
      s = src;
      sSt = pw;
      sOff = y0 * pw + x0;
    } else {
      final e = _edge;
      for (var yy = 0; yy < h + 1; yy++) {
        var sy = y0 + yy;
        if (sy < 0) sy = 0;
        if (sy >= ph) sy = ph - 1;
        final row = sy * pw;
        final eo = yy * _es;
        for (var xx = 0; xx < w + 1; xx++) {
          var sx = x0 + xx;
          if (sx < 0) sx = 0;
          if (sx >= pw) sx = pw - 1;
          e[eo + xx] = src[row + sx];
        }
      }
      s = e;
      sSt = _es;
      sOff = 0;
    }
    if (fx == 0 && fy == 0) {
      _copy(s, sOff, sSt, dst, dOff, dSt, w, h);
      return;
    }
    final a = (8 - fx) * (8 - fy);
    final b = fx * (8 - fy);
    final c = (8 - fx) * fy;
    final dd = fx * fy;
    for (var y = 0; y < h; y++) {
      var p = sOff + y * sSt;
      var o = dOff + y * dSt;
      var tl = s[p], bl = s[p + sSt];
      for (var x = 0; x < w; x++) {
        final tr = s[p + 1], br = s[p + sSt + 1];
        dst[o] = (a * tl + b * tr + c * bl + dd * br + 32) >> 6;
        tl = tr;
        bl = br;
        p++;
        o++;
      }
    }
  }
}
