// Intra prediction (8.3.1, 8.3.3, 8.3.4) operating on reconstructed samples.

import 'dart:typed_data';

int _clip(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

/// Neighbour samples of a 4x4 block. top[0..7] are p[0..7, -1] (with the
/// top-right substitution already applied), left[0..3] are p[-1, 0..3].
class Intra4x4Edges {
  final Int32List top = Int32List(8);
  final Int32List left = Int32List(4);
  int topLeft = 0;
  bool hasTop = false;
  bool hasLeft = false;
  bool hasTopLeft = false;

  /// Loads edges for the block at (x, y) of plane [p] (stride [s]).
  void load(Uint8List p, int s, int x, int y, bool top, bool left, bool tl,
      bool topRight) {
    hasTop = top;
    hasLeft = left;
    hasTopLeft = tl;
    if (top) {
      final o = (y - 1) * s + x;
      for (var i = 0; i < 4; i++) {
        this.top[i] = p[o + i];
      }
      if (topRight) {
        for (var i = 4; i < 8; i++) {
          this.top[i] = p[o + i];
        }
      } else {
        final v = p[o + 3];
        for (var i = 4; i < 8; i++) {
          this.top[i] = v;
        }
      }
    }
    if (left) {
      for (var i = 0; i < 4; i++) {
        this.left[i] = p[(y + i) * s + x - 1];
      }
    }
    if (tl) topLeft = p[(y - 1) * s + x - 1];
  }

  /// Whether the given Intra4x4PredMode can be used with these edges.
  bool modeAvailable(int mode) {
    switch (mode) {
      case 0:
      case 3:
      case 7:
        return hasTop;
      case 1:
      case 8:
        return hasLeft;
      case 2:
        return true;
      default:
        return hasTop && hasLeft && hasTopLeft;
    }
  }

  /// Writes the 4x4 prediction for [mode] into out[o..] with stride 4.
  void predict(int mode, Uint8List out, int o) {
    final t = top, l = left;
    switch (mode) {
      case 0: // vertical
        for (var y = 0; y < 4; y++) {
          for (var x = 0; x < 4; x++) {
            out[o + y * 4 + x] = t[x];
          }
        }
        break;
      case 1: // horizontal
        for (var y = 0; y < 4; y++) {
          final v = l[y];
          for (var x = 0; x < 4; x++) {
            out[o + y * 4 + x] = v;
          }
        }
        break;
      case 2: // DC
        int v;
        if (hasTop && hasLeft) {
          v = (t[0] + t[1] + t[2] + t[3] + l[0] + l[1] + l[2] + l[3] + 4) >> 3;
        } else if (hasLeft) {
          v = (l[0] + l[1] + l[2] + l[3] + 2) >> 2;
        } else if (hasTop) {
          v = (t[0] + t[1] + t[2] + t[3] + 2) >> 2;
        } else {
          v = 128;
        }
        for (var i = 0; i < 16; i++) {
          out[o + i] = v;
        }
        break;
      case 3: // diagonal down left
        for (var y = 0; y < 4; y++) {
          for (var x = 0; x < 4; x++) {
            int v;
            if (x == 3 && y == 3) {
              v = (t[6] + 3 * t[7] + 2) >> 2;
            } else {
              v = (t[x + y] + 2 * t[x + y + 1] + t[x + y + 2] + 2) >> 2;
            }
            out[o + y * 4 + x] = v;
          }
        }
        break;
      case 4: // diagonal down right
        for (var y = 0; y < 4; y++) {
          for (var x = 0; x < 4; x++) {
            int v;
            if (x > y) {
              v = (_p(x - y - 2, -1) + 2 * _p(x - y - 1, -1) + _p(x - y, -1) + 2) >>
                  2;
            } else if (x < y) {
              v = (_p(-1, y - x - 2) + 2 * _p(-1, y - x - 1) + _p(-1, y - x) + 2) >>
                  2;
            } else {
              v = (t[0] + 2 * topLeft + l[0] + 2) >> 2;
            }
            out[o + y * 4 + x] = v;
          }
        }
        break;
      case 5: // vertical right
        for (var y = 0; y < 4; y++) {
          for (var x = 0; x < 4; x++) {
            final z = 2 * x - y;
            int v;
            if (z >= 0 && (z & 1) == 0) {
              v = (_p(x - (y >> 1) - 1, -1) + _p(x - (y >> 1), -1) + 1) >> 1;
            } else if (z >= 0) {
              v = (_p(x - (y >> 1) - 2, -1) +
                      2 * _p(x - (y >> 1) - 1, -1) +
                      _p(x - (y >> 1), -1) +
                      2) >>
                  2;
            } else if (z == -1) {
              v = (l[0] + 2 * topLeft + t[0] + 2) >> 2;
            } else {
              v = (_p(-1, y - 1) + 2 * _p(-1, y - 2) + _p(-1, y - 3) + 2) >> 2;
            }
            out[o + y * 4 + x] = v;
          }
        }
        break;
      case 6: // horizontal down
        for (var y = 0; y < 4; y++) {
          for (var x = 0; x < 4; x++) {
            final z = 2 * y - x;
            int v;
            if (z >= 0 && (z & 1) == 0) {
              v = (_p(-1, y - (x >> 1) - 1) + _p(-1, y - (x >> 1)) + 1) >> 1;
            } else if (z >= 0) {
              v = (_p(-1, y - (x >> 1) - 2) +
                      2 * _p(-1, y - (x >> 1) - 1) +
                      _p(-1, y - (x >> 1)) +
                      2) >>
                  2;
            } else if (z == -1) {
              v = (l[0] + 2 * topLeft + t[0] + 2) >> 2;
            } else {
              v = (_p(x - 1, -1) + 2 * _p(x - 2, -1) + _p(x - 3, -1) + 2) >> 2;
            }
            out[o + y * 4 + x] = v;
          }
        }
        break;
      case 7: // vertical left
        for (var y = 0; y < 4; y++) {
          for (var x = 0; x < 4; x++) {
            final i = x + (y >> 1);
            int v;
            if ((y & 1) == 0) {
              v = (t[i] + t[i + 1] + 1) >> 1;
            } else {
              v = (t[i] + 2 * t[i + 1] + t[i + 2] + 2) >> 2;
            }
            out[o + y * 4 + x] = v;
          }
        }
        break;
      case 8: // horizontal up
        for (var y = 0; y < 4; y++) {
          for (var x = 0; x < 4; x++) {
            final z = x + 2 * y;
            final i = y + (x >> 1);
            int v;
            if (z > 5) {
              v = l[3];
            } else if (z == 5) {
              v = (l[2] + 3 * l[3] + 2) >> 2;
            } else if ((z & 1) == 0) {
              v = (l[i] + l[i + 1] + 1) >> 1;
            } else {
              v = (l[i] + 2 * l[i + 1] + l[i + 2] + 2) >> 2;
            }
            out[o + y * 4 + x] = v;
          }
        }
        break;
    }
  }

  /// p[x, y] with x == -1 or y == -1 (x, y >= -1).
  int _p(int x, int y) {
    if (y == -1) return x < 0 ? topLeft : top[x];
    return y < 0 ? topLeft : left[y];
  }
}

/// Intra 16x16 prediction for luma. Writes mode [mode] into out (stride 16).
/// Plane / vertical / horizontal callers must check availability.
void predict16x16(int mode, Uint8List rec, int s, int x0, int y0, bool hasTop,
    bool hasLeft, Uint8List out, int o) {
  switch (mode) {
    case 0:
      final t = (y0 - 1) * s + x0;
      for (var y = 0; y < 16; y++) {
        for (var x = 0; x < 16; x++) {
          out[o + y * 16 + x] = rec[t + x];
        }
      }
      break;
    case 1:
      for (var y = 0; y < 16; y++) {
        final v = rec[(y0 + y) * s + x0 - 1];
        for (var x = 0; x < 16; x++) {
          out[o + y * 16 + x] = v;
        }
      }
      break;
    case 2:
      var sum = 0;
      int v;
      if (hasTop && hasLeft) {
        for (var i = 0; i < 16; i++) {
          sum += rec[(y0 - 1) * s + x0 + i] + rec[(y0 + i) * s + x0 - 1];
        }
        v = (sum + 16) >> 5;
      } else if (hasLeft) {
        for (var i = 0; i < 16; i++) {
          sum += rec[(y0 + i) * s + x0 - 1];
        }
        v = (sum + 8) >> 4;
      } else if (hasTop) {
        for (var i = 0; i < 16; i++) {
          sum += rec[(y0 - 1) * s + x0 + i];
        }
        v = (sum + 8) >> 4;
      } else {
        v = 128;
      }
      for (var i = 0; i < 256; i++) {
        out[o + i] = v;
      }
      break;
    case 3:
      final t = (y0 - 1) * s + x0;
      var hh = 0, vv = 0;
      for (var i = 0; i < 8; i++) {
        hh += (i + 1) * (rec[t + 8 + i] - rec[t + 6 - i]);
        vv += (i + 1) *
            (rec[(y0 + 8 + i) * s + x0 - 1] - rec[(y0 + 6 - i) * s + x0 - 1]);
      }
      final a = 16 * (rec[(y0 + 15) * s + x0 - 1] + rec[t + 15]);
      final b = (5 * hh + 32) >> 6;
      final c = (5 * vv + 32) >> 6;
      for (var y = 0; y < 16; y++) {
        for (var x = 0; x < 16; x++) {
          out[o + y * 16 + x] = _clip((a + b * (x - 7) + c * (y - 7) + 16) >> 5);
        }
      }
      break;
  }
}

/// Intra chroma prediction (8.3.4) for one 8x8 component. Modes: 0 DC,
/// 1 horizontal, 2 vertical, 3 plane. Output stride 8.
void predictChroma(int mode, Uint8List rec, int s, int x0, int y0, bool hasTop,
    bool hasLeft, Uint8List out, int o) {
  switch (mode) {
    case 0:
      for (var by = 0; by < 2; by++) {
        for (var bx = 0; bx < 2; bx++) {
          var st = 0, sl = 0;
          if (hasTop) {
            for (var i = 0; i < 4; i++) {
              st += rec[(y0 - 1) * s + x0 + bx * 4 + i];
            }
          }
          if (hasLeft) {
            for (var i = 0; i < 4; i++) {
              sl += rec[(y0 + by * 4 + i) * s + x0 - 1];
            }
          }
          int v;
          if (bx == by) {
            if (hasTop && hasLeft) {
              v = (st + sl + 4) >> 3;
            } else if (hasTop) {
              v = (st + 2) >> 2;
            } else if (hasLeft) {
              v = (sl + 2) >> 2;
            } else {
              v = 128;
            }
          } else if (bx == 1) {
            // top right block prefers top
            if (hasTop) {
              v = (st + 2) >> 2;
            } else if (hasLeft) {
              v = (sl + 2) >> 2;
            } else {
              v = 128;
            }
          } else {
            // bottom left block prefers left
            if (hasLeft) {
              v = (sl + 2) >> 2;
            } else if (hasTop) {
              v = (st + 2) >> 2;
            } else {
              v = 128;
            }
          }
          for (var y = 0; y < 4; y++) {
            for (var x = 0; x < 4; x++) {
              out[o + (by * 4 + y) * 8 + bx * 4 + x] = v;
            }
          }
        }
      }
      break;
    case 1:
      for (var y = 0; y < 8; y++) {
        final v = rec[(y0 + y) * s + x0 - 1];
        for (var x = 0; x < 8; x++) {
          out[o + y * 8 + x] = v;
        }
      }
      break;
    case 2:
      final t = (y0 - 1) * s + x0;
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          out[o + y * 8 + x] = rec[t + x];
        }
      }
      break;
    case 3:
      final t = (y0 - 1) * s + x0;
      var hh = 0, vv = 0;
      for (var i = 0; i < 4; i++) {
        hh += (i + 1) * (rec[t + 4 + i] - rec[t + 2 - i]);
        vv += (i + 1) *
            (rec[(y0 + 4 + i) * s + x0 - 1] - rec[(y0 + 2 - i) * s + x0 - 1]);
      }
      final a = 16 * (rec[(y0 + 7) * s + x0 - 1] + rec[t + 7]);
      final b = (34 * hh + 32) >> 6;
      final c = (34 * vv + 32) >> 6;
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          out[o + y * 8 + x] = _clip((a + b * (x - 3) + c * (y - 3) + 16) >> 5);
        }
      }
      break;
  }
}
