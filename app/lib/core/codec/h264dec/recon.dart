import 'dart:typed_data';

import 'int_util.dart';

int _clip(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

/// Intra prediction (8.3) and inverse transforms (8.5).
class Recon {
  final Int32List _t = Int32List(17);
  final Int32List _l = Int32List(9);
  final Int32List _tf = Int32List(17);
  final Int32List _lf = Int32List(9);
  final Int32List _tmp = Int32List(64);

  // ---------------------------------------------------------------- intra

  /// Intra 4x4 prediction of the block at [off] in plane [p] (stride [st]).
  void intra4x4(
    Uint8List p,
    int off,
    int st,
    int mode,
    bool top,
    bool left,
    bool topLeft,
    bool topRight,
  ) {
    final t = _t, l = _l;
    if (top) {
      final o = off - st;
      for (var i = 0; i < 4; i++) {
        t[1 + i] = p[o + i];
      }
      if (topRight) {
        for (var i = 4; i < 8; i++) {
          t[1 + i] = p[o + i];
        }
      } else {
        final v = t[4];
        for (var i = 4; i < 8; i++) {
          t[1 + i] = v;
        }
      }
    } else {
      for (var i = 1; i < 9; i++) {
        t[i] = 128;
      }
    }
    if (left) {
      for (var i = 0; i < 4; i++) {
        l[1 + i] = p[off + i * st - 1];
      }
    } else {
      for (var i = 1; i < 5; i++) {
        l[i] = 128;
      }
    }
    final tl = topLeft ? p[off - st - 1] : 128;
    t[0] = tl;
    l[0] = tl;
    if (mode == 2) {
      int dc;
      if (top && left) {
        dc = (t[1] + t[2] + t[3] + t[4] + l[1] + l[2] + l[3] + l[4] + 4) >> 3;
      } else if (left) {
        dc = (l[1] + l[2] + l[3] + l[4] + 2) >> 2;
      } else if (top) {
        dc = (t[1] + t[2] + t[3] + t[4] + 2) >> 2;
      } else {
        dc = 128;
      }
      for (var y = 0; y < 4; y++) {
        final o = off + y * st;
        p[o] = dc;
        p[o + 1] = dc;
        p[o + 2] = dc;
        p[o + 3] = dc;
      }
      return;
    }
    _directional(4, mode, t, l, p, off, st);
  }

  /// Intra 8x8 prediction with reference sample filtering (8.3.2.2).
  void intra8x8(
    Uint8List p,
    int off,
    int st,
    int mode,
    bool top,
    bool left,
    bool topLeft,
    bool topRight,
  ) {
    final t = _t, l = _l;
    if (top) {
      final o = off - st;
      for (var i = 0; i < 8; i++) {
        t[1 + i] = p[o + i];
      }
      if (topRight) {
        for (var i = 8; i < 16; i++) {
          t[1 + i] = p[o + i];
        }
      } else {
        final v = t[8];
        for (var i = 8; i < 16; i++) {
          t[1 + i] = v;
        }
      }
    }
    if (left) {
      for (var i = 0; i < 8; i++) {
        l[1 + i] = p[off + i * st - 1];
      }
    }
    final tlv = topLeft ? p[off - st - 1] : 0;
    t[0] = tlv;
    l[0] = tlv;
    final tf = _tf, lf = _lf;
    // Filtered top-left.
    if (topLeft) {
      int v;
      if (top && left) {
        v = (t[1] + 2 * tlv + l[1] + 2) >> 2;
      } else if (top) {
        v = (3 * tlv + t[1] + 2) >> 2;
      } else if (left) {
        v = (3 * tlv + l[1] + 2) >> 2;
      } else {
        v = tlv;
      }
      tf[0] = v;
      lf[0] = v;
    } else {
      tf[0] = 128;
      lf[0] = 128;
    }
    if (top) {
      tf[1] = topLeft ? (tlv + 2 * t[1] + t[2] + 2) >> 2 : (3 * t[1] + t[2] + 2) >> 2;
      for (var x = 1; x < 15; x++) {
        tf[1 + x] = (t[x] + 2 * t[1 + x] + t[2 + x] + 2) >> 2;
      }
      tf[16] = (t[15] + 3 * t[16] + 2) >> 2;
    } else {
      for (var i = 1; i < 17; i++) {
        tf[i] = 128;
      }
    }
    if (left) {
      lf[1] = topLeft ? (tlv + 2 * l[1] + l[2] + 2) >> 2 : (3 * l[1] + l[2] + 2) >> 2;
      for (var y = 1; y < 7; y++) {
        lf[1 + y] = (l[y] + 2 * l[1 + y] + l[2 + y] + 2) >> 2;
      }
      lf[8] = (l[7] + 3 * l[8] + 2) >> 2;
    } else {
      for (var i = 1; i < 9; i++) {
        lf[i] = 128;
      }
    }
    if (mode == 2) {
      int dc;
      if (top && left) {
        var s = 0;
        for (var i = 1; i <= 8; i++) {
          s += tf[i] + lf[i];
        }
        dc = (s + 8) >> 4;
      } else if (left) {
        var s = 0;
        for (var i = 1; i <= 8; i++) {
          s += lf[i];
        }
        dc = (s + 4) >> 3;
      } else if (top) {
        var s = 0;
        for (var i = 1; i <= 8; i++) {
          s += tf[i];
        }
        dc = (s + 4) >> 3;
      } else {
        dc = 128;
      }
      for (var y = 0; y < 8; y++) {
        final o = off + y * st;
        for (var x = 0; x < 8; x++) {
          p[o + x] = dc;
        }
      }
      return;
    }
    _directional(8, mode, tf, lf, p, off, st);
  }

  /// Shared directional modes for 4x4 and 8x8 blocks. t[0] = l[0] = corner,
  /// t[1+x] = p[x,-1], l[1+y] = p[-1,y].
  static void _directional(
    int n,
    int mode,
    Int32List t,
    Int32List l,
    Uint8List p,
    int off,
    int st,
  ) {
    switch (mode) {
      case 0:
        for (var y = 0; y < n; y++) {
          final o = off + y * st;
          for (var x = 0; x < n; x++) {
            p[o + x] = t[1 + x];
          }
        }
        return;
      case 1:
        for (var y = 0; y < n; y++) {
          final o = off + y * st;
          final v = l[1 + y];
          for (var x = 0; x < n; x++) {
            p[o + x] = v;
          }
        }
        return;
      case 3:
        for (var y = 0; y < n; y++) {
          final o = off + y * st;
          for (var x = 0; x < n; x++) {
            int v;
            if (x == n - 1 && y == n - 1) {
              v = (t[2 * n - 1] + 3 * t[2 * n] + 2) >> 2;
            } else {
              final k = x + y;
              v = (t[1 + k] + 2 * t[2 + k] + t[3 + k] + 2) >> 2;
            }
            p[o + x] = v;
          }
        }
        return;
      case 4:
        for (var y = 0; y < n; y++) {
          final o = off + y * st;
          for (var x = 0; x < n; x++) {
            int v;
            if (x > y) {
              final k = x - y;
              v = (t[k - 1] + 2 * t[k] + t[k + 1] + 2) >> 2;
            } else if (x < y) {
              final k = y - x;
              v = (l[k - 1] + 2 * l[k] + l[k + 1] + 2) >> 2;
            } else {
              v = (t[1] + 2 * t[0] + l[1] + 2) >> 2;
            }
            p[o + x] = v;
          }
        }
        return;
      case 5:
        for (var y = 0; y < n; y++) {
          final o = off + y * st;
          for (var x = 0; x < n; x++) {
            final z = 2 * x - y;
            int v;
            if (z >= 0) {
              final k = x - (y >> 1);
              if ((z & 1) == 0) {
                v = (t[k] + t[k + 1] + 1) >> 1;
              } else {
                v = (t[k - 1] + 2 * t[k] + t[k + 1] + 2) >> 2;
              }
            } else if (z == -1) {
              v = (l[1] + 2 * t[0] + t[1] + 2) >> 2;
            } else {
              final k = y - 2 * x;
              v = (l[k] + 2 * l[k - 1] + l[k - 2] + 2) >> 2;
            }
            p[o + x] = v;
          }
        }
        return;
      case 6:
        for (var y = 0; y < n; y++) {
          final o = off + y * st;
          for (var x = 0; x < n; x++) {
            final z = 2 * y - x;
            int v;
            if (z >= 0) {
              final k = y - (x >> 1);
              if ((z & 1) == 0) {
                v = (l[k] + l[k + 1] + 1) >> 1;
              } else {
                v = (l[k - 1] + 2 * l[k] + l[k + 1] + 2) >> 2;
              }
            } else if (z == -1) {
              v = (l[1] + 2 * t[0] + t[1] + 2) >> 2;
            } else {
              final k = x - 2 * y;
              v = (t[k] + 2 * t[k - 1] + t[k - 2] + 2) >> 2;
            }
            p[o + x] = v;
          }
        }
        return;
      case 7:
        for (var y = 0; y < n; y++) {
          final o = off + y * st;
          for (var x = 0; x < n; x++) {
            final k = x + (y >> 1);
            int v;
            if ((y & 1) == 0) {
              v = (t[1 + k] + t[2 + k] + 1) >> 1;
            } else {
              v = (t[1 + k] + 2 * t[2 + k] + t[3 + k] + 2) >> 2;
            }
            p[o + x] = v;
          }
        }
        return;
      case 8:
        for (var y = 0; y < n; y++) {
          final o = off + y * st;
          for (var x = 0; x < n; x++) {
            final z = x + 2 * y;
            int v;
            if (z < 2 * n - 3) {
              final k = y + (x >> 1);
              if ((z & 1) == 0) {
                v = (l[1 + k] + l[2 + k] + 1) >> 1;
              } else {
                v = (l[1 + k] + 2 * l[2 + k] + l[3 + k] + 2) >> 2;
              }
            } else if (z == 2 * n - 3) {
              v = (l[n - 1] + 3 * l[n] + 2) >> 2;
            } else {
              v = l[n];
            }
            p[o + x] = v;
          }
        }
        return;
      default:
        // Invalid mode: fall back to flat grey.
        for (var y = 0; y < n; y++) {
          final o = off + y * st;
          for (var x = 0; x < n; x++) {
            p[o + x] = 128;
          }
        }
    }
  }

  /// Intra 16x16 luma prediction (8.3.3).
  void intra16x16(Uint8List p, int off, int st, int mode, bool top, bool left, bool topLeft) {
    switch (mode) {
      case 0:
        if (!top) {
          _fill(p, off, st, 16, 128);
          return;
        }
        for (var y = 0; y < 16; y++) {
          final o = off + y * st;
          for (var x = 0; x < 16; x++) {
            p[o + x] = p[off - st + x];
          }
        }
        return;
      case 1:
        if (!left) {
          _fill(p, off, st, 16, 128);
          return;
        }
        for (var y = 0; y < 16; y++) {
          final o = off + y * st;
          final v = p[o - 1];
          for (var x = 0; x < 16; x++) {
            p[o + x] = v;
          }
        }
        return;
      case 2:
        var s = 0;
        int dc;
        if (top && left) {
          for (var i = 0; i < 16; i++) {
            s += p[off - st + i] + p[off + i * st - 1];
          }
          dc = (s + 16) >> 5;
        } else if (left) {
          for (var i = 0; i < 16; i++) {
            s += p[off + i * st - 1];
          }
          dc = (s + 8) >> 4;
        } else if (top) {
          for (var i = 0; i < 16; i++) {
            s += p[off - st + i];
          }
          dc = (s + 8) >> 4;
        } else {
          dc = 128;
        }
        _fill(p, off, st, 16, dc);
        return;
      default:
        if (!(top && left && topLeft)) {
          _fill(p, off, st, 16, 128);
          return;
        }
        final to = off - st;
        var hh = 0, vv = 0;
        for (var i = 0; i < 8; i++) {
          final a = p[to + 8 + i];
          final b = i == 7 ? p[to - 1] : p[to + 6 - i];
          hh += (i + 1) * (a - b);
          final c = p[off + (8 + i) * st - 1];
          final d = i == 7 ? p[to - 1] : p[off + (6 - i) * st - 1];
          vv += (i + 1) * (c - d);
        }
        final a = 16 * (p[off + 15 * st - 1] + p[to + 15]);
        final b = asr(5 * hh + 32, 6);
        final c = asr(5 * vv + 32, 6);
        for (var y = 0; y < 16; y++) {
          final o = off + y * st;
          var base = a + c * (y - 7) - 7 * b + 16;
          for (var x = 0; x < 16; x++) {
            p[o + x] = _clip(asr(base, 5));
            base += b;
          }
        }
    }
  }

  /// Intra chroma prediction for one 8x8 chroma plane (4:2:0).
  void intraChroma(Uint8List p, int off, int st, int mode, bool top, bool left, bool topLeft) {
    switch (mode) {
      case 0:
        for (var blk = 0; blk < 4; blk++) {
          final xo = (blk & 1) * 4, yo = (blk >> 1) * 4;
          var st0 = 0, sl = 0;
          if (top) {
            for (var i = 0; i < 4; i++) {
              st0 += p[off - st + xo + i];
            }
          }
          if (left) {
            for (var i = 0; i < 4; i++) {
              sl += p[off + (yo + i) * st - 1];
            }
          }
          int dc;
          if (xo == yo) {
            if (top && left) {
              dc = (st0 + sl + 4) >> 3;
            } else if (left) {
              dc = (sl + 2) >> 2;
            } else if (top) {
              dc = (st0 + 2) >> 2;
            } else {
              dc = 128;
            }
          } else if (xo > 0) {
            if (top) {
              dc = (st0 + 2) >> 2;
            } else if (left) {
              dc = (sl + 2) >> 2;
            } else {
              dc = 128;
            }
          } else {
            if (left) {
              dc = (sl + 2) >> 2;
            } else if (top) {
              dc = (st0 + 2) >> 2;
            } else {
              dc = 128;
            }
          }
          final bo = off + yo * st + xo;
          for (var y = 0; y < 4; y++) {
            final o = bo + y * st;
            p[o] = dc;
            p[o + 1] = dc;
            p[o + 2] = dc;
            p[o + 3] = dc;
          }
        }
        return;
      case 1:
        if (!left) {
          _fill(p, off, st, 8, 128);
          return;
        }
        for (var y = 0; y < 8; y++) {
          final o = off + y * st;
          final v = p[o - 1];
          for (var x = 0; x < 8; x++) {
            p[o + x] = v;
          }
        }
        return;
      case 2:
        if (!top) {
          _fill(p, off, st, 8, 128);
          return;
        }
        for (var y = 0; y < 8; y++) {
          final o = off + y * st;
          for (var x = 0; x < 8; x++) {
            p[o + x] = p[off - st + x];
          }
        }
        return;
      default:
        if (!(top && left && topLeft)) {
          _fill(p, off, st, 8, 128);
          return;
        }
        final to = off - st;
        var hh = 0, vv = 0;
        for (var i = 0; i < 4; i++) {
          final a = p[to + 4 + i];
          final b = i == 3 ? p[to - 1] : p[to + 2 - i];
          hh += (i + 1) * (a - b);
          final c = p[off + (4 + i) * st - 1];
          final d = i == 3 ? p[to - 1] : p[off + (2 - i) * st - 1];
          vv += (i + 1) * (c - d);
        }
        final a = 16 * (p[off + 7 * st - 1] + p[to + 7]);
        final b = asr(34 * hh + 32, 6);
        final c = asr(34 * vv + 32, 6);
        for (var y = 0; y < 8; y++) {
          final o = off + y * st;
          var base = a + c * (y - 3) - 3 * b + 16;
          for (var x = 0; x < 8; x++) {
            p[o + x] = _clip(asr(base, 5));
            base += b;
          }
        }
    }
  }

  static void _fill(Uint8List p, int off, int st, int n, int v) {
    for (var y = 0; y < n; y++) {
      final o = off + y * st;
      for (var x = 0; x < n; x++) {
        p[o + x] = v;
      }
    }
  }

  // ------------------------------------------------------------ transforms

  /// Inverse 4x4 transform of c[cOff..cOff+16) (raster), adds to p and
  /// clears the coefficients.
  void idct4Add(Int32List c, int cOff, Uint8List p, int off, int st) {
    final t = _tmp;
    for (var i = 0; i < 4; i++) {
      final o = cOff + i * 4;
      final d0 = c[o], d1 = c[o + 1], d2 = c[o + 2], d3 = c[o + 3];
      final e = d0 + d2, f = d0 - d2;
      final g = asr(d1, 1) - d3, h = d1 + asr(d3, 1);
      t[i * 4] = e + h;
      t[i * 4 + 1] = f + g;
      t[i * 4 + 2] = f - g;
      t[i * 4 + 3] = e - h;
    }
    for (var j = 0; j < 4; j++) {
      final d0 = t[j], d1 = t[4 + j], d2 = t[8 + j], d3 = t[12 + j];
      final e = d0 + d2, f = d0 - d2;
      final g = asr(d1, 1) - d3, h = d1 + asr(d3, 1);
      var o = off + j;
      p[o] = _clip(p[o] + asr(e + h + 32, 6));
      o += st;
      p[o] = _clip(p[o] + asr(f + g + 32, 6));
      o += st;
      p[o] = _clip(p[o] + asr(f - g + 32, 6));
      o += st;
      p[o] = _clip(p[o] + asr(e - h + 32, 6));
    }
    for (var i = 0; i < 16; i++) {
      c[cOff + i] = 0;
    }
  }

  /// Adds a DC-only 4x4 (or [n]x[n]) residual and clears the coefficient.
  static void dcAdd(Int32List c, int cOff, Uint8List p, int off, int st, int n) {
    final dc = asr(c[cOff] + 32, 6);
    c[cOff] = 0;
    if (dc == 0) return;
    for (var y = 0; y < n; y++) {
      final o = off + y * st;
      for (var x = 0; x < n; x++) {
        p[o + x] = _clip(p[o + x] + dc);
      }
    }
  }

  /// Inverse 8x8 transform (8.5.13), adds to p, clears coefficients.
  void idct8Add(Int32List c, int cOff, Uint8List p, int off, int st) {
    final t = _tmp;
    for (var i = 0; i < 8; i++) {
      final o = cOff + i * 8;
      _row8(
        c[o],
        c[o + 1],
        c[o + 2],
        c[o + 3],
        c[o + 4],
        c[o + 5],
        c[o + 6],
        c[o + 7],
        t,
        i * 8,
        1,
      );
    }
    for (var j = 0; j < 8; j++) {
      _row8(
        t[j],
        t[8 + j],
        t[16 + j],
        t[24 + j],
        t[32 + j],
        t[40 + j],
        t[48 + j],
        t[56 + j],
        t,
        j,
        8,
      );
    }
    // After the column pass t holds the result in raster order.
    for (var y = 0; y < 8; y++) {
      final o = off + y * st;
      for (var x = 0; x < 8; x++) {
        p[o + x] = _clip(p[o + x] + asr(t[y * 8 + x] + 32, 6));
      }
    }
    for (var i = 0; i < 64; i++) {
      c[cOff + i] = 0;
    }
  }

  static void _row8(
    int d0,
    int d1,
    int d2,
    int d3,
    int d4,
    int d5,
    int d6,
    int d7,
    Int32List out,
    int o,
    int step,
  ) {
    final a0 = d0 + d4;
    final a4 = d0 - d4;
    final a2 = asr(d2, 1) - d6;
    final a6 = d2 + asr(d6, 1);
    final b0 = a0 + a6;
    final b2 = a4 + a2;
    final b4 = a4 - a2;
    final b6 = a0 - a6;
    final a1 = -d3 + d5 - d7 - asr(d7, 1);
    final a3 = d1 + d7 - d3 - asr(d3, 1);
    final a5 = -d1 + d7 + d5 + asr(d5, 1);
    final a7 = d3 + d5 + d1 + asr(d1, 1);
    final b1 = a1 + asr(a7, 2);
    final b7 = a7 - asr(a1, 2);
    final b3 = a3 + asr(a5, 2);
    final b5 = asr(a3, 2) - a5;
    out[o] = b0 + b7;
    out[o + step] = b2 + b5;
    out[o + 2 * step] = b4 + b3;
    out[o + 3 * step] = b6 + b1;
    out[o + 4 * step] = b6 - b1;
    out[o + 5 * step] = b4 - b3;
    out[o + 6 * step] = b2 - b5;
    out[o + 7 * step] = b0 - b7;
  }
}
