// In-loop deblocking filter (8.7) for progressive frames, one slice, with
// filter offsets 0 and chroma_qp_index_offset 0.

import 'dart:typed_data';

import 'tables.dart';

/// Macroblock kinds shared with the encoder core.
const int mbSkip = 0;
const int mbInter = 1;
const int mbI4x4 = 2;
const int mbI16x16 = 3;

class Deblocker {
  final Int32List _bsV = Int32List(16); // [edge * 4 + segment]
  final Int32List _bsH = Int32List(16);

  /// Filters the picture in place. [nz] holds per-4x4 luma total_coeff in
  /// raster order within each macroblock, [mvs] holds per-4x4 vectors
  /// (x, y interleaved) for inter macroblocks.
  void filter(
      Uint8List y,
      Uint8List u,
      Uint8List v,
      int mbW,
      int mbH,
      Int8List mbType,
      Uint8List mbQp,
      Uint8List nz,
      Int16List mvs) {
    final stride = mbW * 16;
    final cStride = mbW * 8;
    for (var mby = 0; mby < mbH; mby++) {
      for (var mbx = 0; mbx < mbW; mbx++) {
        final q = mby * mbW + mbx;
        final qIntra = mbType[q] >= mbI4x4;
        // Boundary strengths for vertical edges.
        var anyV = false;
        for (var e = 0; e < 4; e++) {
          if (e == 0 && mbx == 0) {
            for (var k = 0; k < 4; k++) {
              _bsV[k] = 0;
            }
            continue;
          }
          final p = e == 0 ? q - 1 : q;
          final pIntra = mbType[p] >= mbI4x4;
          for (var k = 0; k < 4; k++) {
            final qb = k * 4 + e;
            final pb = e == 0 ? k * 4 + 3 : qb - 1;
            int bs;
            if (qIntra || pIntra) {
              bs = e == 0 ? 4 : 3;
            } else if (nz[q * 16 + qb] != 0 || nz[p * 16 + pb] != 0) {
              bs = 2;
            } else {
              bs = _mvBs(mvs, (p * 16 + pb) * 2, (q * 16 + qb) * 2);
            }
            _bsV[e * 4 + k] = bs;
            if (bs != 0) anyV = true;
          }
        }
        var anyH = false;
        for (var e = 0; e < 4; e++) {
          if (e == 0 && mby == 0) {
            for (var k = 0; k < 4; k++) {
              _bsH[k] = 0;
            }
            continue;
          }
          final p = e == 0 ? q - mbW : q;
          final pIntra = mbType[p] >= mbI4x4;
          for (var k = 0; k < 4; k++) {
            final qb = e * 4 + k;
            final pb = e == 0 ? 12 + k : qb - 4;
            int bs;
            if (qIntra || pIntra) {
              bs = e == 0 ? 4 : 3;
            } else if (nz[q * 16 + qb] != 0 || nz[p * 16 + pb] != 0) {
              bs = 2;
            } else {
              bs = _mvBs(mvs, (p * 16 + pb) * 2, (q * 16 + qb) * 2);
            }
            _bsH[e * 4 + k] = bs;
            if (bs != 0) anyH = true;
          }
        }
        final qpQ = mbQp[q];
        final x0 = mbx * 16, y0 = mby * 16;
        if (anyV) {
          for (var e = 0; e < 4; e++) {
            if (e == 0 && mbx == 0) continue;
            final qpP = e == 0 ? mbQp[q - 1] : qpQ;
            final idx = (qpP + qpQ + 1) >> 1;
            final alpha = deblockAlpha[idx], beta = deblockBeta[idx];
            if (alpha == 0 || beta == 0) continue;
            for (var k = 0; k < 4; k++) {
              final bs = _bsV[e * 4 + k];
              if (bs == 0) continue;
              final tc0 = bs < 4 ? deblockTc0[idx * 4 + bs] : 0;
              var o = (y0 + k * 4) * stride + x0 + e * 4;
              for (var l = 0; l < 4; l++) {
                _lumaLine(y, o, 1, bs, alpha, beta, tc0);
                o += stride;
              }
            }
            // Chroma vertical edges at chroma x 0 and 4.
            if ((e & 1) == 0) {
              final cqp = (chromaQpTable[qpP] + chromaQpTable[qpQ] + 1) >> 1;
              final ca = deblockAlpha[cqp], cb = deblockBeta[cqp];
              if (ca == 0 || cb == 0) continue;
              for (var k = 0; k < 4; k++) {
                final bs = _bsV[e * 4 + k];
                if (bs == 0) continue;
                final tc0 = bs < 4 ? deblockTc0[cqp * 4 + bs] : 0;
                var o = (mby * 8 + k * 2) * cStride + mbx * 8 + e * 2;
                for (var l = 0; l < 2; l++) {
                  _chromaLine(u, o, 1, bs, ca, cb, tc0);
                  _chromaLine(v, o, 1, bs, ca, cb, tc0);
                  o += cStride;
                }
              }
            }
          }
        }
        if (anyH) {
          for (var e = 0; e < 4; e++) {
            if (e == 0 && mby == 0) continue;
            final qpP = e == 0 ? mbQp[q - mbW] : qpQ;
            final idx = (qpP + qpQ + 1) >> 1;
            final alpha = deblockAlpha[idx], beta = deblockBeta[idx];
            if (alpha == 0 || beta == 0) continue;
            for (var k = 0; k < 4; k++) {
              final bs = _bsH[e * 4 + k];
              if (bs == 0) continue;
              final tc0 = bs < 4 ? deblockTc0[idx * 4 + bs] : 0;
              var o = (y0 + e * 4) * stride + x0 + k * 4;
              for (var l = 0; l < 4; l++) {
                _lumaLine(y, o, stride, bs, alpha, beta, tc0);
                o++;
              }
            }
            if ((e & 1) == 0) {
              final cqp = (chromaQpTable[qpP] + chromaQpTable[qpQ] + 1) >> 1;
              final ca = deblockAlpha[cqp], cb = deblockBeta[cqp];
              if (ca == 0 || cb == 0) continue;
              for (var k = 0; k < 4; k++) {
                final bs = _bsH[e * 4 + k];
                if (bs == 0) continue;
                final tc0 = bs < 4 ? deblockTc0[cqp * 4 + bs] : 0;
                var o = (mby * 8 + e * 2) * cStride + mbx * 8 + k * 2;
                for (var l = 0; l < 2; l++) {
                  _chromaLine(u, o, cStride, bs, ca, cb, tc0);
                  _chromaLine(v, o, cStride, bs, ca, cb, tc0);
                  o++;
                }
              }
            }
          }
        }
      }
    }
  }

  static int _mvBs(Int16List mvs, int a, int b) {
    var d = mvs[a] - mvs[b];
    if (d >= 4 || d <= -4) return 1;
    d = mvs[a + 1] - mvs[b + 1];
    if (d >= 4 || d <= -4) return 1;
    return 0;
  }

  @pragma('vm:unsafe:no-bounds-checks')
  static void _lumaLine(Uint8List s, int i, int st, int bs, int alpha,
      int beta, int tc0) {
    final p0 = s[i - st], q0 = s[i];
    var d = p0 - q0;
    if (d < 0) d = -d;
    if (d >= alpha) return;
    final p1 = s[i - 2 * st], q1 = s[i + st];
    var t = p1 - p0;
    if (t < 0) t = -t;
    if (t >= beta) return;
    t = q1 - q0;
    if (t < 0) t = -t;
    if (t >= beta) return;
    final p2 = s[i - 3 * st], q2 = s[i + 2 * st];
    var ap = p2 - p0;
    if (ap < 0) ap = -ap;
    var aq = q2 - q0;
    if (aq < 0) aq = -aq;
    if (bs < 4) {
      var tc = tc0;
      if (ap < beta) tc++;
      if (aq < beta) tc++;
      var delta = ((q0 - p0) * 4 + (p1 - q1) + 4) >> 3;
      if (delta < -tc) delta = -tc;
      if (delta > tc) delta = tc;
      var v = p0 + delta;
      s[i - st] = v < 0 ? 0 : (v > 255 ? 255 : v);
      v = q0 - delta;
      s[i] = v < 0 ? 0 : (v > 255 ? 255 : v);
      final avg = (p0 + q0 + 1) >> 1;
      if (ap < beta) {
        var x = (p2 + avg - 2 * p1) >> 1;
        if (x < -tc0) x = -tc0;
        if (x > tc0) x = tc0;
        s[i - 2 * st] = p1 + x;
      }
      if (aq < beta) {
        var x = (q2 + avg - 2 * q1) >> 1;
        if (x < -tc0) x = -tc0;
        if (x > tc0) x = tc0;
        s[i + st] = q1 + x;
      }
    } else {
      final strong = d < ((alpha >> 2) + 2);
      if (ap < beta && strong) {
        final p3 = s[i - 4 * st];
        s[i - st] = (p2 + 2 * p1 + 2 * p0 + 2 * q0 + q1 + 4) >> 3;
        s[i - 2 * st] = (p2 + p1 + p0 + q0 + 2) >> 2;
        s[i - 3 * st] = (2 * p3 + 3 * p2 + p1 + p0 + q0 + 4) >> 3;
      } else {
        s[i - st] = (2 * p1 + p0 + q1 + 2) >> 2;
      }
      if (aq < beta && strong) {
        final q3 = s[i + 3 * st];
        s[i] = (p1 + 2 * p0 + 2 * q0 + 2 * q1 + q2 + 4) >> 3;
        s[i + st] = (p0 + q0 + q1 + q2 + 2) >> 2;
        s[i + 2 * st] = (2 * q3 + 3 * q2 + q1 + q0 + p0 + 4) >> 3;
      } else {
        s[i] = (2 * q1 + q0 + p1 + 2) >> 2;
      }
    }
  }

  @pragma('vm:unsafe:no-bounds-checks')
  static void _chromaLine(Uint8List s, int i, int st, int bs, int alpha,
      int beta, int tc0) {
    final p0 = s[i - st], q0 = s[i];
    var d = p0 - q0;
    if (d < 0) d = -d;
    if (d >= alpha) return;
    final p1 = s[i - 2 * st], q1 = s[i + st];
    var t = p1 - p0;
    if (t < 0) t = -t;
    if (t >= beta) return;
    t = q1 - q0;
    if (t < 0) t = -t;
    if (t >= beta) return;
    if (bs < 4) {
      final tc = tc0 + 1;
      var delta = ((q0 - p0) * 4 + (p1 - q1) + 4) >> 3;
      if (delta < -tc) delta = -tc;
      if (delta > tc) delta = tc;
      var v = p0 + delta;
      s[i - st] = v < 0 ? 0 : (v > 255 ? 255 : v);
      v = q0 - delta;
      s[i] = v < 0 ? 0 : (v > 255 ? 255 : v);
    } else {
      s[i - st] = (2 * p1 + p0 + q1 + 2) >> 2;
      s[i] = (2 * q1 + q0 + p1 + 2) >> 2;
    }
  }
}
