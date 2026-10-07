// Constant tables for the H.264 encoder (ITU-T H.264 clause numbers noted).

import 'dart:math' as math;
import 'dart:typed_data';

/// Frame zig-zag scan: scan index to raster index (y * 4 + x) of a 4x4 block.
final Uint8List zigzag4x4 = Uint8List.fromList(
    [0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15]);

/// Luma 4x4 block index (decoding order, 8.2.4) to raster position (y4 * 4 + x4).
final Uint8List blkToRaster = Uint8List.fromList(
    [0, 1, 4, 5, 2, 3, 6, 7, 8, 9, 12, 13, 10, 11, 14, 15]);

/// Forward quantisation multipliers MF[qp % 6][raster position].
final List<Int32List> quantMF = _buildQuantTables(
    const [13107, 11916, 10082, 9362, 8192, 7282],
    const [5243, 4660, 4194, 3647, 3355, 2893],
    const [8066, 7490, 6554, 5825, 5243, 4559]);

/// Dequantisation scales V[qp % 6][raster position] (normAdjust4x4).
final List<Int32List> dequantV = _buildQuantTables(
    const [10, 11, 13, 14, 16, 18],
    const [16, 18, 20, 23, 25, 29],
    const [13, 14, 16, 18, 20, 23]);

List<Int32List> _buildQuantTables(List<int> a, List<int> b, List<int> c) {
  final out = <Int32List>[];
  for (var m = 0; m < 6; m++) {
    final t = Int32List(16);
    for (var r = 0; r < 16; r++) {
      final x = r & 3, y = r >> 2;
      if ((x & 1) == 0 && (y & 1) == 0) {
        t[r] = a[m];
      } else if ((x & 1) == 1 && (y & 1) == 1) {
        t[r] = b[m];
      } else {
        t[r] = c[m];
      }
    }
    out.add(t);
  }
  return out;
}

/// QPc as a function of qPI (Table 8-15).
final Uint8List chromaQpTable = Uint8List.fromList([
  for (var i = 0; i < 30; i++) i,
  29, 30, 31, 32, 32, 33, 34, 34, 35, 35, 36, 36, 37, 37, 37, 38, 38, 38, //
  39, 39, 39, 39,
]);

/// Deblocking alpha' (Table 8-16) indexed by indexA.
final Uint8List deblockAlpha = Uint8List.fromList([
  for (var i = 0; i < 16; i++) 0,
  4, 4, 5, 6, 7, 8, 9, 10, 12, 13, 15, 17, 20, 22, 25, 28, 32, 36, 40, 45, //
  50, 56, 63, 71, 80, 90, 101, 113, 127, 144, 162, 182, 203, 226, 255, 255,
]);

/// Deblocking beta' (Table 8-16) indexed by indexB.
final Uint8List deblockBeta = Uint8List.fromList([
  for (var i = 0; i < 16; i++) 0,
  2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, //
  11, 11, 12, 12, 13, 13, 14, 14, 15, 15, 16, 16, 17, 17, 18, 18,
]);

/// tC0 (Table 8-17) as [indexA * 4 + bS], bS in 1..3.
final Uint8List deblockTc0 = () {
  const rows = <List<int>>[
    [0, 0, 1], [0, 0, 1], [0, 0, 1], [0, 0, 1], [0, 1, 1], [0, 1, 1], //
    [1, 1, 1], [1, 1, 1], [1, 1, 1], [1, 1, 1], [1, 1, 2], [1, 1, 2], //
    [1, 1, 2], [1, 1, 2], [1, 2, 3], [1, 2, 3], [2, 2, 3], [2, 2, 4], //
    [2, 3, 4], [2, 3, 4], [3, 3, 5], [3, 4, 6], [3, 4, 6], [4, 5, 7], //
    [4, 5, 8], [4, 6, 9], [5, 7, 10], [6, 8, 11], [6, 8, 13], [7, 10, 14], //
    [8, 11, 16], [9, 12, 18], [10, 13, 20], [11, 15, 23], [13, 17, 25],
  ];
  final t = Uint8List(52 * 4);
  for (var i = 0; i < rows.length; i++) {
    for (var b = 0; b < 3; b++) {
      t[(17 + i) * 4 + 1 + b] = rows[i][b];
    }
  }
  return t;
}();

/// coded_block_pattern to codeNum for Intra_4x4 (inverse of Table 9-4).
final Uint8List cbpToCodeIntra = _invert(const [
  47, 31, 15, 0, 23, 27, 29, 30, 7, 11, 13, 14, 39, 43, 45, 46, 16, 3, 5, 10, //
  12, 19, 21, 26, 28, 35, 37, 42, 44, 1, 2, 4, 8, 17, 18, 20, 24, 6, 9, 22, //
  25, 32, 33, 34, 36, 40, 38, 41,
]);

/// coded_block_pattern to codeNum for Inter (inverse of Table 9-4).
final Uint8List cbpToCodeInter = _invert(const [
  0, 16, 1, 2, 4, 8, 32, 3, 5, 10, 12, 15, 47, 7, 11, 13, 14, 6, 9, 31, //
  35, 37, 42, 44, 33, 34, 36, 40, 39, 43, 45, 46, 17, 18, 20, 24, 19, 21, //
  26, 28, 23, 27, 29, 30, 22, 25, 38, 41,
]);

Uint8List _invert(List<int> codeToCbp) {
  final t = Uint8List(48);
  for (var i = 0; i < 48; i++) {
    t[codeToCbp[i]] = i;
  }
  return t;
}

// ---------------------------------------------------------------------------
// CAVLC tables (Tables 9-5, 9-7, 9-8, 9-9, 9-10). Indexed as in libavcodec:
// coeff_token by [table][totalCoeff * 4 + trailingOnes].

final List<Uint8List> coeffTokenLen = [
  Uint8List.fromList([
    1, 0, 0, 0, 6, 2, 0, 0, 8, 6, 3, 0, 9, 8, 7, 5, 10, 9, 8, 6, //
    11, 10, 9, 7, 13, 11, 10, 8, 13, 13, 11, 9, 13, 13, 13, 10, //
    14, 14, 13, 11, 14, 14, 14, 13, 15, 15, 14, 14, 15, 15, 15, 14, //
    16, 15, 15, 15, 16, 16, 16, 15, 16, 16, 16, 16, 16, 16, 16, 16,
  ]),
  Uint8List.fromList([
    2, 0, 0, 0, 6, 2, 0, 0, 6, 5, 3, 0, 7, 6, 6, 4, 8, 6, 6, 4, //
    8, 7, 7, 5, 9, 8, 8, 6, 11, 9, 9, 6, 11, 11, 11, 7, //
    12, 11, 11, 9, 12, 12, 12, 11, 12, 12, 12, 11, 13, 13, 13, 12, //
    13, 13, 13, 13, 13, 14, 13, 13, 14, 14, 14, 13, 14, 14, 14, 14,
  ]),
  Uint8List.fromList([
    4, 0, 0, 0, 6, 4, 0, 0, 6, 5, 4, 0, 6, 5, 5, 4, 7, 5, 5, 4, //
    7, 5, 5, 4, 7, 6, 6, 4, 7, 6, 6, 4, 8, 7, 7, 5, //
    8, 8, 7, 6, 9, 8, 8, 7, 9, 9, 8, 8, 9, 9, 9, 8, //
    10, 9, 9, 9, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
  ]),
  Uint8List.fromList([
    6, 0, 0, 0, 6, 6, 0, 0, 6, 6, 6, 0, 6, 6, 6, 6, 6, 6, 6, 6, //
    6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, //
    6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, //
    6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
  ]),
  // nC == -1 (chroma DC 4:2:0), totalCoeff 0..4.
  Uint8List.fromList([
    2, 0, 0, 0, 6, 1, 0, 0, 6, 6, 3, 0, 6, 7, 7, 6, 6, 8, 8, 7,
  ]),
];

final List<Uint8List> coeffTokenCode = [
  Uint8List.fromList([
    1, 0, 0, 0, 5, 1, 0, 0, 7, 4, 1, 0, 7, 6, 5, 3, 7, 6, 5, 3, //
    7, 6, 5, 4, 15, 6, 5, 4, 11, 14, 5, 4, 8, 10, 13, 4, //
    15, 14, 9, 4, 11, 10, 13, 12, 15, 14, 9, 12, 11, 10, 13, 8, //
    15, 1, 9, 12, 11, 14, 13, 8, 7, 10, 9, 12, 4, 6, 5, 8,
  ]),
  Uint8List.fromList([
    3, 0, 0, 0, 11, 2, 0, 0, 7, 7, 3, 0, 7, 10, 9, 5, 7, 6, 5, 4, //
    4, 6, 5, 6, 7, 6, 5, 8, 15, 6, 5, 4, 11, 14, 13, 4, //
    15, 10, 9, 4, 11, 14, 13, 12, 8, 10, 9, 8, 15, 14, 13, 12, //
    11, 10, 9, 12, 7, 11, 6, 8, 9, 8, 10, 1, 7, 6, 5, 4,
  ]),
  Uint8List.fromList([
    15, 0, 0, 0, 15, 14, 0, 0, 11, 15, 13, 0, 8, 12, 14, 12, 15, 10, 11, 11, //
    11, 8, 9, 10, 9, 14, 13, 9, 8, 10, 9, 8, 15, 14, 13, 13, //
    11, 14, 10, 12, 15, 10, 13, 12, 11, 14, 9, 12, 8, 10, 13, 8, //
    13, 7, 9, 12, 9, 12, 11, 10, 5, 8, 7, 6, 1, 4, 3, 2,
  ]),
  Uint8List.fromList([
    3, 0, 0, 0, 0, 1, 0, 0, 4, 5, 6, 0, 8, 9, 10, 11, 12, 13, 14, 15, //
    16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, //
    32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, //
    48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
  ]),
  Uint8List.fromList([
    1, 0, 0, 0, 7, 1, 0, 0, 4, 6, 1, 0, 3, 3, 2, 5, 2, 3, 2, 0,
  ]),
];

/// total_zeros for 4x4 blocks: [totalCoeff - 1][totalZeros].
final List<Uint8List> totalZerosLen = [
  [1, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 9],
  [3, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 6, 6, 6, 6],
  [4, 3, 3, 3, 4, 4, 3, 3, 4, 5, 5, 6, 5, 6],
  [5, 3, 4, 4, 3, 3, 3, 4, 3, 4, 5, 5, 5],
  [4, 4, 4, 3, 3, 3, 3, 3, 4, 5, 4, 5],
  [6, 5, 3, 3, 3, 3, 3, 3, 4, 3, 6],
  [6, 5, 3, 3, 3, 2, 3, 4, 3, 6],
  [6, 4, 5, 3, 2, 2, 3, 3, 6],
  [6, 6, 4, 2, 2, 3, 2, 5],
  [5, 5, 3, 2, 2, 2, 4],
  [4, 4, 3, 3, 1, 3],
  [4, 4, 2, 1, 3],
  [3, 3, 1, 2],
  [2, 2, 1],
  [1, 1],
].map(Uint8List.fromList).toList();

final List<Uint8List> totalZerosCode = [
  [1, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 1],
  [7, 6, 5, 4, 3, 5, 4, 3, 2, 3, 2, 3, 2, 1, 0],
  [5, 7, 6, 5, 4, 3, 4, 3, 2, 3, 2, 1, 1, 0],
  [3, 7, 5, 4, 6, 5, 4, 3, 3, 2, 2, 1, 0],
  [5, 4, 3, 7, 6, 5, 4, 3, 2, 1, 1, 0],
  [1, 1, 7, 6, 5, 4, 3, 2, 1, 1, 0],
  [1, 1, 5, 4, 3, 3, 2, 1, 1, 0],
  [1, 1, 1, 3, 3, 2, 2, 1, 0],
  [1, 0, 1, 3, 2, 1, 1, 1],
  [1, 0, 1, 3, 2, 1, 1],
  [0, 1, 1, 2, 1, 3],
  [0, 1, 1, 1, 1],
  [0, 1, 1, 1],
  [0, 1, 1],
  [0, 1],
].map(Uint8List.fromList).toList();

/// total_zeros for chroma DC 2x2: [totalCoeff - 1][totalZeros].
final List<Uint8List> totalZerosDcLen = [
  [1, 2, 3, 3],
  [1, 2, 2],
  [1, 1],
].map(Uint8List.fromList).toList();

final List<Uint8List> totalZerosDcCode = [
  [1, 1, 1, 0],
  [1, 1, 0],
  [1, 0],
].map(Uint8List.fromList).toList();

/// run_before: [min(zerosLeft, 7) - 1][runBefore].
final List<Uint8List> runBeforeLen = [
  [1, 1],
  [1, 2, 2],
  [2, 2, 2, 2],
  [2, 2, 2, 3, 3],
  [2, 2, 3, 3, 3, 3],
  [2, 3, 3, 3, 3, 3, 3],
  [3, 3, 3, 3, 3, 3, 3, 4, 5, 6, 7, 8, 9, 10, 11],
].map(Uint8List.fromList).toList();

final List<Uint8List> runBeforeCode = [
  [1, 0],
  [1, 1, 0],
  [3, 2, 1, 0],
  [3, 2, 1, 1, 0],
  [3, 2, 3, 2, 1, 0],
  [3, 0, 1, 3, 2, 5, 4],
  [7, 6, 5, 4, 3, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1],
].map(Uint8List.fromList).toList();

/// Number of bits of the Exp-Golomb code for codeNum (valid for 0..4095).
final Uint8List ueBits = () {
  final t = Uint8List(4096);
  for (var i = 0; i < 4096; i++) {
    t[i] = 2 * (i + 1).bitLength - 1;
  }
  return t;
}();

/// Bits of se(v) for |v| up to 2047, indexed by v + 2048.
final Uint8List seBits = () {
  final t = Uint8List(4096);
  for (var v = -2048; v < 2048; v++) {
    final k = v > 0 ? 2 * v - 1 : -2 * v;
    t[v + 2048] = 2 * (k + 1).bitLength - 1;
  }
  return t;
}();

/// SAD/SATD Lagrange multiplier per QP, roughly 0.85 * 2^((qp - 12) / 6).
final Int32List lambdaTab = () {
  final t = Int32List(52);
  for (var q = 0; q < 52; q++) {
    final v = 0.85 * math.pow(2.0, (q - 12) / 6.0);
    t[q] = v < 1 ? 1 : v.round();
  }
  return t;
}();
