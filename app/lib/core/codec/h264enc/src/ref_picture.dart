// Reference picture with edge padding and precomputed half-sample planes.

import 'dart:typed_data';

/// Largest motion vector component in quarter samples. Keeps every block
/// reference (including filter taps) inside the padded area.
const int maxMvQpel = 128;

class RefPicture {
  RefPicture(this.width, this.height)
      : stride = width + 2 * pad,
        rows = height + 2 * pad,
        cStride = (width >> 1) + 2 * padC,
        cRows = (height >> 1) + 2 * padC {
    final n = stride * rows;
    full = Uint8List(n);
    halfH = Uint8List(n);
    halfV = Uint8List(n);
    halfC = Uint8List(n);
    _tmp = Int16List(n);
    u = Uint8List(cStride * cRows);
    v = Uint8List(cStride * cRows);
  }

  static const int pad = 48;
  static const int padC = 24;

  /// Coded (macroblock aligned) luma size.
  final int width, height;
  final int stride, rows, cStride, cRows;

  late final Uint8List full, halfH, halfV, halfC, u, v;
  late final Int16List _tmp;

  /// Copies a reconstructed picture in and computes the half-sample planes.
  void build(Uint8List y, Uint8List cb, Uint8List cr) {
    _padPlane(y, width, height, full, stride, pad);
    _padPlane(cb, width >> 1, height >> 1, u, cStride, padC);
    _padPlane(cr, width >> 1, height >> 1, v, cStride, padC);
    _interpolate();
  }

  static void _padPlane(
      Uint8List src, int w, int h, Uint8List dst, int ds, int p) {
    final totalRows = h + 2 * p;
    for (var r = 0; r < totalRows; r++) {
      var sy = r - p;
      if (sy < 0) sy = 0;
      if (sy >= h) sy = h - 1;
      final so = sy * w;
      final o = r * ds;
      final left = src[so], right = src[so + w - 1];
      for (var x = 0; x < p; x++) {
        dst[o + x] = left;
      }
      dst.setRange(o + p, o + p + w, src, so);
      final e = o + p + w;
      for (var x = 0; x < p; x++) {
        dst[e + x] = right;
      }
    }
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void _interpolate() {
    final f = full, hh = halfH, hv = halfV, hc = halfC, t = _tmp;
    final s = stride;
    final xEnd = s - 3;
    // Horizontal half samples b and their unclipped intermediates b1.
    for (var r = 0; r < rows; r++) {
      final o = r * s;
      for (var x = 2; x < xEnd; x++) {
        final i = o + x;
        final b1 = f[i - 2] -
            5 * (f[i - 1] + f[i + 2]) +
            20 * (f[i] + f[i + 1]) +
            f[i + 3];
        t[i] = b1;
        final b = (b1 + 16) >> 5;
        hh[i] = b < 0 ? 0 : (b > 255 ? 255 : b);
      }
    }
    final s2 = 2 * s, s3 = 3 * s;
    for (var r = 2; r < rows - 3; r++) {
      final o = r * s;
      // Vertical half samples h.
      for (var x = 0; x < s; x++) {
        final i = o + x;
        final h1 = f[i - s2] -
            5 * (f[i - s] + f[i + s2]) +
            20 * (f[i] + f[i + s]) +
            f[i + s3];
        final h = (h1 + 16) >> 5;
        hv[i] = h < 0 ? 0 : (h > 255 ? 255 : h);
      }
      // Centre half samples j from b1 intermediates.
      for (var x = 2; x < xEnd; x++) {
        final i = o + x;
        final j1 = t[i - s2] -
            5 * (t[i - s] + t[i + s2]) +
            20 * (t[i] + t[i + s]) +
            t[i + s3];
        final j = (j1 + 512) >> 10;
        hc[i] = j < 0 ? 0 : (j > 255 ? 255 : j);
      }
    }
  }

  /// Luma motion compensation of a bw x bh block at picture position (x, y)
  /// with quarter-sample vector (mvx, mvy) into dst.
  @pragma('vm:unsafe:no-bounds-checks')
  void mcLuma(Uint8List dst, int dOff, int ds, int x, int y, int mvx, int mvy,
      int bw, int bh) {
    final s = stride;
    final o = (y + (mvy >> 2) + pad) * s + x + (mvx >> 2) + pad;
    Uint8List a;
    int ao;
    Uint8List? b;
    var bo = 0;
    switch (((mvy & 3) << 2) | (mvx & 3)) {
      case 0:
        a = full;
        ao = o;
        break;
      case 1:
        a = full;
        ao = o;
        b = halfH;
        bo = o;
        break;
      case 2:
        a = halfH;
        ao = o;
        break;
      case 3:
        a = full;
        ao = o + 1;
        b = halfH;
        bo = o;
        break;
      case 4:
        a = full;
        ao = o;
        b = halfV;
        bo = o;
        break;
      case 5:
        a = halfH;
        ao = o;
        b = halfV;
        bo = o;
        break;
      case 6:
        a = halfH;
        ao = o;
        b = halfC;
        bo = o;
        break;
      case 7:
        a = halfH;
        ao = o;
        b = halfV;
        bo = o + 1;
        break;
      case 8:
        a = halfV;
        ao = o;
        break;
      case 9:
        a = halfV;
        ao = o;
        b = halfC;
        bo = o;
        break;
      case 10:
        a = halfC;
        ao = o;
        break;
      case 11:
        a = halfC;
        ao = o;
        b = halfV;
        bo = o + 1;
        break;
      case 12:
        a = full;
        ao = o + s;
        b = halfV;
        bo = o;
        break;
      case 13:
        a = halfV;
        ao = o;
        b = halfH;
        bo = o + s;
        break;
      case 14:
        a = halfC;
        ao = o;
        b = halfH;
        bo = o + s;
        break;
      default: // 15
        a = halfV;
        ao = o + 1;
        b = halfH;
        bo = o + s;
        break;
    }
    if (b == null) {
      for (var r = 0; r < bh; r++) {
        final so = ao + r * s;
        dst.setRange(dOff + r * ds, dOff + r * ds + bw, a, so);
      }
    } else {
      for (var r = 0; r < bh; r++) {
        final p = ao + r * s, q = bo + r * s, d = dOff + r * ds;
        for (var c = 0; c < bw; c++) {
          dst[d + c] = (a[p + c] + b[q + c] + 1) >> 1;
        }
      }
    }
  }

  /// Chroma motion compensation for both components (8.4.2.2.2). Position
  /// and block size are in chroma samples; mv is the luma vector.
  @pragma('vm:unsafe:no-bounds-checks')
  void mcChroma(Uint8List dU, Uint8List dV, int dOff, int ds, int cx, int cy,
      int mvx, int mvy, int bw, int bh) {
    final s = cStride;
    final o = (cy + (mvy >> 3) + padC) * s + cx + (mvx >> 3) + padC;
    final fx = mvx & 7, fy = mvy & 7;
    final w00 = (8 - fx) * (8 - fy), w01 = fx * (8 - fy);
    final w10 = (8 - fx) * fy, w11 = fx * fy;
    final pu = u, pv = v;
    if (w00 == 64) {
      for (var r = 0; r < bh; r++) {
        final so = o + r * s, d = dOff + r * ds;
        dU.setRange(d, d + bw, pu, so);
        dV.setRange(d, d + bw, pv, so);
      }
      return;
    }
    for (var r = 0; r < bh; r++) {
      final p = o + r * s, d = dOff + r * ds;
      for (var c = 0; c < bw; c++) {
        final i = p + c;
        dU[d + c] = (w00 * pu[i] +
                w01 * pu[i + 1] +
                w10 * pu[i + s] +
                w11 * pu[i + s + 1] +
                32) >>
            6;
        dV[d + c] = (w00 * pv[i] +
                w01 * pv[i + 1] +
                w10 * pv[i + s] +
                w11 * pv[i + s + 1] +
                32) >>
            6;
      }
    }
  }
}
