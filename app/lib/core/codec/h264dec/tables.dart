import 'dart:typed_data';

/// 4x4 frame zigzag scan: scan index to raster index.
final zigzag4x4 = Uint8List.fromList(const [0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15]);

/// 8x8 frame zigzag scan: scan index to raster index.
final zigzag8x8 = Uint8List.fromList(const [
  0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, //
  12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
  35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
  58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
]);

/// Luma 4x4 block index (z order) to x and y in 4x4 units.
final blkX = Uint8List.fromList(const [0, 1, 0, 1, 2, 3, 2, 3, 0, 1, 0, 1, 2, 3, 2, 3]);
final blkY = Uint8List.fromList(const [0, 0, 1, 1, 0, 0, 1, 1, 2, 2, 3, 3, 2, 2, 3, 3]);

/// Luma 4x4 block index (z order) to raster index (y*4+x).
final blkRaster = Uint8List.fromList(const [0, 1, 4, 5, 2, 3, 6, 7, 8, 9, 12, 13, 10, 11, 14, 15]);

/// Raster index to z order index.
final rasterBlk = Uint8List.fromList(const [0, 1, 4, 5, 2, 3, 6, 7, 8, 9, 12, 13, 10, 11, 14, 15]);

/// Table 9-4: codeNum to coded_block_pattern for Intra_4x4/Intra_8x8.
final golombToIntraCbp = Uint8List.fromList(const [
  47, 31, 15, 0, 23, 27, 29, 30, 7, 11, 13, 14, 39, 43, 45, 46, //
  16, 3, 5, 10, 12, 19, 21, 26, 28, 35, 37, 42, 44, 1, 2, 4,
  8, 17, 18, 20, 24, 6, 9, 22, 25, 32, 33, 34, 36, 40, 38, 41,
]);

/// Table 9-4: codeNum to coded_block_pattern for Inter.
final golombToInterCbp = Uint8List.fromList(const [
  0, 16, 1, 2, 4, 8, 32, 3, 5, 10, 12, 15, 47, 7, 11, 13, //
  14, 6, 9, 31, 35, 37, 42, 44, 33, 34, 36, 40, 39, 43, 45, 46,
  17, 18, 20, 24, 19, 21, 26, 28, 23, 27, 29, 30, 22, 25, 38, 41,
]);

/// Table 8-15: QPc as a function of qPI.
final chromaQpTable = () {
  final t = Uint8List(52);
  for (var i = 0; i < 30; i++) {
    t[i] = i;
  }
  const hi = [
    29,
    30,
    31,
    32,
    32,
    33,
    34,
    34,
    35,
    35,
    36,
    36,
    37,
    37,
    37,
    38,
    38,
    38,
    39,
    39,
    39,
    39,
  ];
  for (var i = 30; i < 52; i++) {
    t[i] = hi[i - 30];
  }
  return t;
}();

/// Default scaling lists in raster order (Table 7-3, 7-4).
final defaultScaling4Intra = Uint8List.fromList(const [
  6,
  13,
  20,
  28,
  13,
  20,
  28,
  32,
  20,
  28,
  32,
  37,
  28,
  32,
  37,
  42,
]);
final defaultScaling4Inter = Uint8List.fromList(const [
  10,
  14,
  20,
  24,
  14,
  20,
  24,
  27,
  20,
  24,
  27,
  30,
  24,
  27,
  30,
  34,
]);
final defaultScaling8Intra = Uint8List.fromList(const [
  6, 10, 13, 16, 18, 23, 25, 27, 10, 11, 16, 18, 23, 25, 27, 29, //
  13, 16, 18, 23, 25, 27, 29, 31, 16, 18, 23, 25, 27, 29, 31, 33,
  18, 23, 25, 27, 29, 31, 33, 36, 23, 25, 27, 29, 31, 33, 36, 38,
  25, 27, 29, 31, 33, 36, 38, 40, 27, 29, 31, 33, 36, 38, 40, 42,
]);
final defaultScaling8Inter = Uint8List.fromList(const [
  9, 13, 15, 17, 19, 21, 22, 24, 13, 13, 17, 19, 21, 22, 24, 25, //
  15, 17, 19, 21, 22, 24, 25, 27, 17, 19, 21, 22, 24, 25, 27, 28,
  19, 21, 22, 24, 25, 27, 28, 30, 21, 22, 24, 25, 27, 28, 30, 32,
  22, 24, 25, 27, 28, 30, 32, 33, 24, 25, 27, 28, 30, 32, 33, 35,
]);

/// normAdjust4x4 values v[m][0..2].
const normAdjust4 = [
  [10, 16, 13], [11, 18, 14], [13, 20, 16], [14, 23, 18], [16, 25, 20], [18, 29, 23], //
];

/// normAdjust8x8 values v[m][0..5].
const normAdjust8 = [
  [20, 18, 32, 19, 25, 24], [22, 19, 35, 21, 28, 26], [26, 23, 42, 24, 33, 31], //
  [28, 25, 45, 26, 35, 33], [32, 28, 51, 30, 40, 38], [36, 32, 58, 34, 46, 43],
];

/// Deblocking alpha (Table 8-16) indexed by indexA.
final deblockAlpha = Uint8List.fromList(const [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  4, 4, 5, 6, 7, 8, 9, 10, 12, 13, 15, 17, 20, 22, 25, 28,
  32, 36, 40, 45, 50, 56, 63, 71, 80, 90, 101, 113, 127, 144, 162, 182,
  203, 226, 255, 255,
]);

/// Deblocking beta (Table 8-16) indexed by indexB.
final deblockBeta = Uint8List.fromList(const [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 6, 6, 7, 7, 8, 8,
  9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15, 16, 16,
  17, 17, 18, 18,
]);

/// tC0 (Table 8-17) indexed by indexA*4 + bS (bS 1..3).
final deblockTc0 = () {
  const rows = [
    [0, 0, 0], [0, 0, 0], [0, 0, 0], [0, 0, 0], [0, 0, 0], [0, 0, 0], [0, 0, 0], [0, 0, 0], //
    [0, 0, 0], [0, 0, 0], [0, 0, 0], [0, 0, 0], [0, 0, 0], [0, 0, 0], [0, 0, 0], [0, 0, 0],
    [0, 0, 0], [0, 0, 1], [0, 0, 1], [0, 0, 1], [0, 0, 1], [0, 1, 1], [0, 1, 1], [1, 1, 1],
    [1, 1, 1], [1, 1, 1], [1, 1, 1], [1, 1, 2], [1, 1, 2], [1, 1, 2], [1, 1, 2], [1, 2, 3],
    [1, 2, 3], [2, 2, 3], [2, 2, 4], [2, 3, 4], [2, 3, 4], [3, 3, 5], [3, 4, 6], [3, 4, 6],
    [4, 5, 7], [4, 5, 8], [4, 6, 9], [5, 7, 10], [6, 8, 11], [6, 8, 13], [7, 10, 14], [8, 11, 16],
    [9, 12, 18], [10, 13, 20], [11, 15, 23], [13, 17, 25],
  ];
  final t = Uint8List(52 * 4);
  for (var i = 0; i < 52; i++) {
    for (var b = 1; b <= 3; b++) {
      t[i * 4 + b] = rows[i][b - 1];
    }
  }
  return t;
}();

/// MaxDpbMbs per level_idc (Table A-1).
int maxDpbMbsForLevel(int levelIdc, bool constraintSet3) {
  if (levelIdc == 11 && constraintSet3) return 396; // level 1b
  switch (levelIdc) {
    case 9:
    case 10:
      return 396;
    case 11:
      return 900;
    case 12:
    case 13:
    case 20:
      return 2376;
    case 21:
      return 4752;
    case 22:
    case 30:
      return 8100;
    case 31:
      return 18000;
    case 32:
      return 20480;
    case 40:
    case 41:
      return 32768;
    case 42:
      return 34816;
    case 50:
      return 110400;
    case 51:
    case 52:
      return 184320;
    default:
      return levelIdc > 52 ? 696320 : 184320;
  }
}
