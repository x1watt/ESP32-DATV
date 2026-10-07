import 'dart:typed_data';

import 'bit_writer.dart';
import 'tables.dart';

/// Largest coefficient magnitude the encoder emits. Keeps level_prefix <= 15
/// as required outside the High profiles (see 9.2.2.1).
const int maxCoeffLevel = 2000;

/// CAVLC residual_block writer (9.2). Scratch buffers are reused.
class CavlcWriter {
  final Int32List _lev = Int32List(16);
  final Int32List _pos = Int32List(16);

  /// Returns the coeff_token table index for nC (-1 means chroma DC).
  static int tableForNc(int nC) {
    if (nC < 0) return 4;
    if (nC < 2) return 0;
    if (nC < 4) return 1;
    if (nC < 8) return 2;
    return 3;
  }

  /// Writes residual_block_cavlc for [maxNum] coefficients stored in scan
  /// order at coef[off .. off + maxNum - 1]. Returns TotalCoeff.
  int write(BitWriter bw, Int16List coef, int off, int maxNum, int nC) {
    final lev = _lev;
    final pos = _pos;
    var total = 0;
    for (var i = maxNum - 1; i >= 0; i--) {
      final c = coef[off + i];
      if (c != 0) {
        lev[total] = c;
        pos[total] = i;
        total++;
      }
    }
    var t1 = 0;
    while (t1 < total && t1 < 3) {
      final c = lev[t1];
      if (c == 1 || c == -1) {
        t1++;
      } else {
        break;
      }
    }
    final tab = tableForNc(nC);
    final ti = total * 4 + t1;
    bw.bits(coeffTokenLen[tab][ti], coeffTokenCode[tab][ti]);
    if (total == 0) return 0;

    // Trailing ones signs.
    for (var k = 0; k < t1; k++) {
      bw.bits(1, lev[k] < 0 ? 1 : 0);
    }
    // Remaining levels.
    var suffixLength = (total > 10 && t1 < 3) ? 1 : 0;
    for (var k = t1; k < total; k++) {
      final level = lev[k];
      var levelCode = level > 0 ? 2 * level - 2 : -2 * level - 1;
      if (k == t1 && t1 < 3) levelCode -= 2;
      if (suffixLength == 0) {
        if (levelCode < 14) {
          bw.bits(levelCode + 1, 1);
        } else if (levelCode < 30) {
          bw.bits(15, 1); // level_prefix 14
          bw.bits(4, levelCode - 14);
        } else {
          bw.bits(16, 1); // level_prefix 15
          bw.bits(12, levelCode - 30);
        }
      } else {
        if (levelCode < (15 << suffixLength)) {
          final prefix = levelCode >> suffixLength;
          bw.bits(prefix + 1, 1);
          bw.bits(suffixLength, levelCode & ((1 << suffixLength) - 1));
        } else {
          bw.bits(16, 1);
          bw.bits(12, levelCode - (15 << suffixLength));
        }
      }
      if (suffixLength == 0) suffixLength = 1;
      final a = level < 0 ? -level : level;
      if (a > (3 << (suffixLength - 1)) && suffixLength < 6) suffixLength++;
    }
    // total_zeros
    final totalZeros = pos[0] + 1 - total;
    if (total < maxNum) {
      if (nC < 0) {
        bw.bits(totalZerosDcLen[total - 1][totalZeros],
            totalZerosDcCode[total - 1][totalZeros]);
      } else {
        bw.bits(totalZerosLen[total - 1][totalZeros],
            totalZerosCode[total - 1][totalZeros]);
      }
    }
    // run_before
    var zerosLeft = totalZeros;
    for (var k = 0; k < total - 1 && zerosLeft > 0; k++) {
      final run = pos[k] - pos[k + 1] - 1;
      final t = zerosLeft > 7 ? 6 : zerosLeft - 1;
      bw.bits(runBeforeLen[t][run], runBeforeCode[t][run]);
      zerosLeft -= run;
    }
    return total;
  }
}
