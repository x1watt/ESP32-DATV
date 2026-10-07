import 'dart:typed_data';

import 'bitreader.dart';
import 'int_util.dart';
import 'tables_gen.dart';

/// Builds a direct lookup table for [peekBits] bits. Entry = len << 8 | value,
/// 0 for invalid codes.
Uint16List _buildVlc(int peekBits, List<int> lens, List<int> codes, List<int> values) {
  final t = Uint16List(1 << peekBits);
  for (var i = 0; i < lens.length; i++) {
    final len = lens[i];
    if (len == 0) continue;
    final start = codes[i] << (peekBits - len);
    final n = 1 << (peekBits - len);
    for (var k = 0; k < n; k++) {
      t[start + k] = (len << 8) | values[i];
    }
  }
  return t;
}

final List<Uint16List> _coeffTokenTabs = List.generate(4, (tab) {
  final lens = <int>[], codes = <int>[], vals = <int>[];
  for (var tc = 0; tc <= 16; tc++) {
    for (var t1 = 0; t1 < 4; t1++) {
      final i = tab * 68 + tc * 4 + t1;
      lens.add(coeffTokenLen[i]);
      codes.add(coeffTokenBits[i]);
      vals.add((tc << 2) | t1);
    }
  }
  return _buildVlc(16, lens, codes, vals);
});

final Uint16List _chromaDcCoeffTokenTab = () {
  final lens = <int>[], codes = <int>[], vals = <int>[];
  for (var tc = 0; tc <= 4; tc++) {
    for (var t1 = 0; t1 < 4; t1++) {
      lens.add(chromaDcCoeffTokenLen[tc * 4 + t1]);
      codes.add(chromaDcCoeffTokenBits[tc * 4 + t1]);
      vals.add((tc << 2) | t1);
    }
  }
  return _buildVlc(8, lens, codes, vals);
}();

final List<Uint16List> _totalZerosTabs = List.generate(16, (tc) {
  if (tc == 0) return Uint16List(512);
  final lens = <int>[], codes = <int>[], vals = <int>[];
  for (var tz = 0; tz < 16; tz++) {
    lens.add(totalZerosLen[(tc - 1) * 16 + tz]);
    codes.add(totalZerosBits[(tc - 1) * 16 + tz]);
    vals.add(tz);
  }
  return _buildVlc(9, lens, codes, vals);
});

final List<Uint16List> _chromaDcTotalZerosTabs = List.generate(4, (tc) {
  if (tc == 0) return Uint16List(8);
  final lens = <int>[], codes = <int>[], vals = <int>[];
  for (var tz = 0; tz < 4; tz++) {
    lens.add(chromaDcTotalZerosLen[(tc - 1) * 4 + tz]);
    codes.add(chromaDcTotalZerosBits[(tc - 1) * 4 + tz]);
    vals.add(tz);
  }
  return _buildVlc(3, lens, codes, vals);
});

final List<Uint16List> _runTabs = List.generate(7, (zl) {
  final lens = <int>[], codes = <int>[], vals = <int>[];
  for (var run = 0; run < 16; run++) {
    lens.add(runLen[zl * 16 + run]);
    codes.add(runBits[zl * 16 + run]);
    vals.add(run);
  }
  return _buildVlc(11, lens, codes, vals);
});

/// CAVLC residual_block() decoder (9.2).
class Cavlc {
  final Int32List _level = Int32List(16);
  final Int32List _run = Int32List(16);

  /// Decoded levels and their coefficient indices (0-based within the
  /// block, before adding startIdx). Valid for [decode]'s return count.
  final Int32List outLevel = Int32List(16);
  final Int32List outIdx = Int32List(16);

  int _levelPrefix(BitReader r) {
    final w = r.peek(16);
    if (w != 0) {
      final lz = 16 - w.bitLength;
      r.skip(lz + 1);
      return lz;
    }
    var lz = 16;
    r.skip(16);
    while (r.u1() == 0) {
      lz++;
      if (lz > 32) throw H264Exception('bad level_prefix');
    }
    return lz;
  }

  /// Decodes one block. [nC] is -1 for chroma DC (4:2:0).
  /// Returns TotalCoeff.
  int decode(BitReader r, int nC, int maxNumCoeff) {
    final Uint16List tab;
    int v;
    if (nC < 0) {
      tab = _chromaDcCoeffTokenTab;
      v = tab[r.peek(8)];
    } else {
      tab = _coeffTokenTabs[nC < 2 ? 0 : (nC < 4 ? 1 : (nC < 8 ? 2 : 3))];
      v = tab[r.peek(16)];
    }
    if (v == 0) throw H264Exception('bad coeff_token');
    r.skip(v >> 8);
    final tc = (v >> 2) & 31;
    final t1 = v & 3;
    if (tc == 0) return 0;
    if (tc > maxNumCoeff) throw H264Exception('too many coefficients');
    final level = _level;
    var suffixLength = (tc > 10 && t1 < 3) ? 1 : 0;
    for (var i = 0; i < t1; i++) {
      level[i] = r.u1() != 0 ? -1 : 1;
    }
    for (var i = t1; i < tc; i++) {
      final prefix = _levelPrefix(r);
      var levelCode = (prefix < 15 ? prefix : 15) << suffixLength;
      if (suffixLength > 0 || prefix >= 14) {
        final size = (prefix == 14 && suffixLength == 0)
            ? 4
            : (prefix >= 15 ? prefix - 3 : suffixLength);
        if (size > 0) levelCode += r.uLong(size);
      }
      if (prefix >= 15 && suffixLength == 0) levelCode += 15;
      if (prefix >= 16) levelCode += (1 << (prefix - 3)) - 4096;
      if (i == t1 && t1 < 3) levelCode += 2;
      final lv = (levelCode & 1) == 0 ? (levelCode + 2) >> 1 : asr(-levelCode - 1, 1);
      level[i] = lv;
      if (suffixLength == 0) suffixLength = 1;
      final a = lv < 0 ? -lv : lv;
      if (a > (3 << (suffixLength - 1)) && suffixLength < 6) suffixLength++;
    }
    var zerosLeft = 0;
    if (tc < maxNumCoeff) {
      int z;
      if (nC < 0) {
        z = _chromaDcTotalZerosTabs[tc][r.peek(3)];
      } else {
        z = _totalZerosTabs[tc][r.peek(9)];
      }
      if (z == 0) throw H264Exception('bad total_zeros');
      r.skip(z >> 8);
      zerosLeft = z & 15;
      if (zerosLeft + tc > maxNumCoeff) throw H264Exception('bad total_zeros value');
    }
    final run = _run;
    for (var i = 0; i < tc - 1; i++) {
      if (zerosLeft > 0) {
        final rv = _runTabs[zerosLeft > 6 ? 6 : zerosLeft - 1][r.peek(11)];
        if (rv == 0) throw H264Exception('bad run_before');
        r.skip(rv >> 8);
        final rb = rv & 15;
        if (rb > zerosLeft) throw H264Exception('bad run_before value');
        run[i] = rb;
        zerosLeft -= rb;
      } else {
        run[i] = 0;
      }
    }
    run[tc - 1] = zerosLeft;
    var coeffNum = -1;
    var o = 0;
    for (var i = tc - 1; i >= 0; i--) {
      coeffNum += run[i] + 1;
      outLevel[o] = level[i];
      outIdx[o] = coeffNum;
      o++;
    }
    return tc;
  }
}
