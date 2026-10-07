import 'dart:typed_data';

import 'int_util.dart';
import 'picture.dart';
import 'tables.dart';

/// Per-slice deblocking parameters.
class DeblockSliceParams {
  DeblockSliceParams(this.disableIdc, this.offsetA, this.offsetB, this.cbQpOffset, this.crQpOffset);
  final int disableIdc;
  final int offsetA;
  final int offsetB;
  final int cbQpOffset;
  final int crQpOffset;
}

/// Picture-level macroblock data needed by the loop filter.
class MbInfo {
  MbInfo(int mbCount)
    : sliceTable = Int32List(mbCount),
      qp = Uint8List(mbCount),
      intra = Uint8List(mbCount),
      t8 = Uint8List(mbCount),
      uniform = Uint8List(mbCount),
      nzMask = Int32List(mbCount);

  /// Index into the slice parameter list, -1 if the macroblock is missing.
  final Int32List sliceTable;

  /// QPY used for deblocking (0 for I_PCM).
  final Uint8List qp;
  final Uint8List intra;
  final Uint8List t8;

  /// 1 when all 16 4x4 blocks of an inter macroblock share the same
  /// references and motion vectors.
  final Uint8List uniform;

  /// Bit (raster 4x4 index) set when the transform block containing that
  /// 4x4 block has non-zero coefficients.
  final Int32List nzMask;
}

int _clip(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

/// Deblocking filter process (8.7) for progressive frames.
class Deblocker {
  final Int32List _bs = Int32List(4);

  void filterPicture(Picture pic, MbInfo info, List<DeblockSliceParams> slices) {
    final mbW = pic.mbWidth, mbH = pic.mbHeight;
    for (var my = 0; my < mbH; my++) {
      for (var mx = 0; mx < mbW; mx++) {
        final mb = my * mbW + mx;
        final si = info.sliceTable[mb];
        if (si < 0) continue;
        final sp = slices[si];
        if (sp.disableIdc == 1) continue;
        final leftOk =
            mx > 0 &&
            info.sliceTable[mb - 1] >= 0 &&
            (sp.disableIdc != 2 || info.sliceTable[mb - 1] == si);
        final topOk =
            my > 0 &&
            info.sliceTable[mb - mbW] >= 0 &&
            (sp.disableIdc != 2 || info.sliceTable[mb - mbW] == si);
        _filterMb(pic, info, sp, mb, mx, my, leftOk, topOk);
      }
    }
  }

  void _filterMb(
    Picture pic,
    MbInfo info,
    DeblockSliceParams sp,
    int mb,
    int mx,
    int my,
    bool leftOk,
    bool topOk,
  ) {
    final w = pic.width;
    final cw = w >> 1;
    final t8 = info.t8[mb] != 0;
    final qpQ = info.qp[mb];
    final bs = _bs;
    for (var dir = 0; dir < 2; dir++) {
      // dir 0: vertical edges (filter across x), dir 1: horizontal edges.
      for (var e = 0; e < 4; e++) {
        if (e == 0 && !(dir == 0 ? leftOk : topOk)) continue;
        if (t8 && (e & 1) != 0) continue;
        final mbP = e == 0 ? (dir == 0 ? mb - 1 : mb - pic.mbWidth) : mb;
        if (!_computeBs(pic, info, mb, mbP, dir, e)) continue;
        final qpP = info.qp[mbP];
        final qpAv = (qpP + qpQ + 1) >> 1;
        // Luma.
        final int lOff, across, along;
        if (dir == 0) {
          lOff = my * 16 * w + mx * 16 + e * 4;
          across = 1;
          along = w;
        } else {
          lOff = (my * 16 + e * 4) * w + mx * 16;
          across = w;
          along = 1;
        }
        _lumaEdge(pic.y, lOff, across, along, bs, qpAv + sp.offsetA, qpAv + sp.offsetB);
        if ((e & 1) == 0) {
          final int cOff, cAcross, cAlong;
          if (dir == 0) {
            cOff = my * 8 * cw + mx * 8 + e * 2;
            cAcross = 1;
            cAlong = cw;
          } else {
            cOff = (my * 8 + e * 2) * cw + mx * 8;
            cAcross = cw;
            cAlong = 1;
          }
          for (var c = 0; c < 2; c++) {
            final off = c == 0 ? sp.cbQpOffset : sp.crQpOffset;
            final qcP = chromaQpTable[_clip51(qpP + off)];
            final qcQ = chromaQpTable[_clip51(qpQ + off)];
            final qcAv = (qcP + qcQ + 1) >> 1;
            _chromaEdge(
              c == 0 ? pic.u : pic.v,
              cOff,
              cAcross,
              cAlong,
              bs,
              qcAv + sp.offsetA,
              qcAv + sp.offsetB,
            );
          }
        }
      }
    }
  }

  static int _clip51(int v) => v < 0 ? 0 : (v > 51 ? 51 : v);

  /// Fills [_bs] for the 4 segments of edge [e]; returns false if all zero.
  bool _computeBs(Picture pic, MbInfo info, int mbQ, int mbP, int dir, int e) {
    final bs = _bs;
    if (info.intra[mbQ] != 0 || info.intra[mbP] != 0) {
      final v = e == 0 ? 4 : 3;
      bs[0] = v;
      bs[1] = v;
      bs[2] = v;
      bs[3] = v;
      return true;
    }
    final nzQ = info.nzMask[mbQ];
    final nzP = info.nzMask[mbP];
    final uq = info.uniform[mbQ] != 0;
    // Motion is identical across internal edges of uniform macroblocks, and
    // only needs one comparison across an edge between two uniform ones.
    var sameMotion = -1;
    if (e != 0) {
      if (uq) sameMotion = 0;
    } else if (uq && info.uniform[mbP] != 0) {
      sameMotion = _motionBs(pic, mbP * 16, mbQ * 16);
    }
    var any = false;
    for (var k = 0; k < 4; k++) {
      // Raster indices of q and p 4x4 blocks.
      int bq, bp;
      if (dir == 0) {
        bq = k * 4 + e;
        bp = e == 0 ? k * 4 + 3 : bq - 1;
      } else {
        bq = e * 4 + k;
        bp = e == 0 ? 12 + k : bq - 4;
      }
      int v;
      if (((nzQ >> bq) & 1) != 0 || ((nzP >> bp) & 1) != 0) {
        v = 2;
      } else if (sameMotion >= 0) {
        v = sameMotion;
      } else {
        v = _motionBs(pic, mbP * 16 + bp, mbQ * 16 + bq);
      }
      bs[k] = v;
      if (v != 0) any = true;
    }
    return any;
  }

  static bool _mvDiff(Int16List a, int ia, Int16List b, int ib) {
    final dx = a[ia * 2] - b[ib * 2];
    final dy = a[ia * 2 + 1] - b[ib * 2 + 1];
    return dx >= 4 || dx <= -4 || dy >= 4 || dy <= -4;
  }

  static int _motionBs(Picture pic, int p, int q) {
    final rp0 = pic.ref0[p] >= 0 ? pic.refId0[p] : -1;
    final rp1 = pic.ref1[p] >= 0 ? pic.refId1[p] : -1;
    final rq0 = pic.ref0[q] >= 0 ? pic.refId0[q] : -1;
    final rq1 = pic.ref1[q] >= 0 ? pic.refId1[q] : -1;
    final np = (rp0 >= 0 ? 1 : 0) + (rp1 >= 0 ? 1 : 0);
    final nq = (rq0 >= 0 ? 1 : 0) + (rq1 >= 0 ? 1 : 0);
    if (np != nq) return 1;
    final m0 = pic.mv0, m1 = pic.mv1;
    if (np == 1) {
      final refP = rp0 >= 0 ? rp0 : rp1;
      final refQ = rq0 >= 0 ? rq0 : rq1;
      if (refP != refQ) return 1;
      final mp = rp0 >= 0 ? m0 : m1;
      final mq = rq0 >= 0 ? m0 : m1;
      return _mvDiff(mp, p, mq, q) ? 1 : 0;
    }
    if (np == 0) return 1; // should not happen for inter blocks
    if (!((rp0 == rq0 && rp1 == rq1) || (rp0 == rq1 && rp1 == rq0))) return 1;
    if (rp0 != rp1) {
      if (rp0 == rq0) {
        return (_mvDiff(m0, p, m0, q) || _mvDiff(m1, p, m1, q)) ? 1 : 0;
      }
      return (_mvDiff(m0, p, m1, q) || _mvDiff(m1, p, m0, q)) ? 1 : 0;
    }
    final a = _mvDiff(m0, p, m0, q) || _mvDiff(m1, p, m1, q);
    final b = _mvDiff(m0, p, m1, q) || _mvDiff(m1, p, m0, q);
    return (a && b) ? 1 : 0;
  }

  static void _lumaEdge(
    Uint8List pix,
    int off,
    int across,
    int along,
    Int32List bs,
    int iA,
    int iB,
  ) {
    final indexA = _clip51(iA);
    final alpha = deblockAlpha[indexA];
    final beta = deblockBeta[_clip51(iB)];
    if (alpha == 0 || beta == 0) return;
    for (var k = 0; k < 4; k++) {
      final b = bs[k];
      if (b == 0) continue;
      final tc0 = b < 4 ? deblockTc0[indexA * 4 + b] : 0;
      for (var i = 0; i < 4; i++) {
        final o = off + (k * 4 + i) * along;
        final p0 = pix[o - across], q0 = pix[o];
        var d = p0 - q0;
        if (d < 0) d = -d;
        if (d >= alpha) continue;
        final p1 = pix[o - 2 * across], q1 = pix[o + across];
        d = p1 - p0;
        if (d < 0) d = -d;
        if (d >= beta) continue;
        d = q1 - q0;
        if (d < 0) d = -d;
        if (d >= beta) continue;
        final p2 = pix[o - 3 * across], q2 = pix[o + 2 * across];
        var ap = p2 - p0;
        if (ap < 0) ap = -ap;
        var aq = q2 - q0;
        if (aq < 0) aq = -aq;
        if (b < 4) {
          var tc = tc0;
          if (ap < beta) tc++;
          if (aq < beta) tc++;
          var delta = asr((q0 - p0) * 4 + (p1 - q1) + 4, 3);
          if (delta < -tc) delta = -tc;
          if (delta > tc) delta = tc;
          pix[o - across] = _clip(p0 + delta);
          pix[o] = _clip(q0 - delta);
          if (ap < beta) {
            var dp = asr(p2 + ((p0 + q0 + 1) >> 1) - (p1 << 1), 1);
            if (dp < -tc0) dp = -tc0;
            if (dp > tc0) dp = tc0;
            pix[o - 2 * across] = p1 + dp;
          }
          if (aq < beta) {
            var dq = asr(q2 + ((p0 + q0 + 1) >> 1) - (q1 << 1), 1);
            if (dq < -tc0) dq = -tc0;
            if (dq > tc0) dq = tc0;
            pix[o + across] = q1 + dq;
          }
        } else {
          var ad = p0 - q0;
          if (ad < 0) ad = -ad;
          final strong = ad < ((alpha >> 2) + 2);
          if (ap < beta && strong) {
            final p3 = pix[o - 4 * across];
            pix[o - across] = (p2 + 2 * p1 + 2 * p0 + 2 * q0 + q1 + 4) >> 3;
            pix[o - 2 * across] = (p2 + p1 + p0 + q0 + 2) >> 2;
            pix[o - 3 * across] = (2 * p3 + 3 * p2 + p1 + p0 + q0 + 4) >> 3;
          } else {
            pix[o - across] = (2 * p1 + p0 + q1 + 2) >> 2;
          }
          if (aq < beta && strong) {
            final q3 = pix[o + 3 * across];
            pix[o] = (p1 + 2 * p0 + 2 * q0 + 2 * q1 + q2 + 4) >> 3;
            pix[o + across] = (p0 + q0 + q1 + q2 + 2) >> 2;
            pix[o + 2 * across] = (2 * q3 + 3 * q2 + q1 + q0 + p0 + 4) >> 3;
          } else {
            pix[o] = (2 * q1 + q0 + p1 + 2) >> 2;
          }
        }
      }
    }
  }

  static void _chromaEdge(
    Uint8List pix,
    int off,
    int across,
    int along,
    Int32List bs,
    int iA,
    int iB,
  ) {
    final indexA = _clip51(iA);
    final alpha = deblockAlpha[indexA];
    final beta = deblockBeta[_clip51(iB)];
    if (alpha == 0 || beta == 0) return;
    for (var k = 0; k < 4; k++) {
      final b = bs[k];
      if (b == 0) continue;
      final tc = b < 4 ? deblockTc0[indexA * 4 + b] + 1 : 0;
      for (var i = 0; i < 2; i++) {
        final o = off + (k * 2 + i) * along;
        final p0 = pix[o - across], q0 = pix[o];
        var d = p0 - q0;
        if (d < 0) d = -d;
        if (d >= alpha) continue;
        final p1 = pix[o - 2 * across], q1 = pix[o + across];
        d = p1 - p0;
        if (d < 0) d = -d;
        if (d >= beta) continue;
        d = q1 - q0;
        if (d < 0) d = -d;
        if (d >= beta) continue;
        if (b < 4) {
          var delta = asr((q0 - p0) * 4 + (p1 - q1) + 4, 3);
          if (delta < -tc) delta = -tc;
          if (delta > tc) delta = tc;
          pix[o - across] = _clip(p0 + delta);
          pix[o] = _clip(q0 - delta);
        } else {
          pix[o - across] = (2 * p1 + p0 + q1 + 2) >> 2;
          pix[o] = (2 * q1 + q0 + p1 + 2) >> 2;
        }
      }
    }
  }
}
