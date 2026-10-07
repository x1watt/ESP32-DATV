import 'dart:typed_data';

/// A decoded frame plus the per-block motion data needed by later pictures
/// (co-located data for direct prediction).
class Picture {
  Picture(this.mbWidth, this.mbHeight)
    : width = mbWidth * 16,
      height = mbHeight * 16,
      y = Uint8List(mbWidth * mbHeight * 256),
      u = Uint8List(mbWidth * mbHeight * 64),
      v = Uint8List(mbWidth * mbHeight * 64),
      mv0 = Int16List(mbWidth * mbHeight * 32),
      mv1 = Int16List(mbWidth * mbHeight * 32),
      ref0 = Int8List(mbWidth * mbHeight * 16),
      ref1 = Int8List(mbWidth * mbHeight * 16),
      refId0 = Int32List(mbWidth * mbHeight * 16),
      refId1 = Int32List(mbWidth * mbHeight * 16),
      mbIntra = Uint8List(mbWidth * mbHeight);

  final int mbWidth;
  final int mbHeight;
  final int width;
  final int height;
  final Uint8List y;
  final Uint8List u;
  final Uint8List v;

  /// Motion vectors per 4x4 block (index (mbAddr*16 + raster)*2).
  final Int16List mv0;
  final Int16List mv1;

  /// Reference indices per 4x4 block (-1 when the list is unused).
  final Int8List ref0;
  final Int8List ref1;

  /// Unique id of the referenced picture per 4x4 block (-1 when unused).
  final Int32List refId0;
  final Int32List refId1;

  /// 1 for intra macroblocks.
  final Uint8List mbIntra;

  /// Unique id of this decoded picture.
  int uid = 0;
  int poc = 0;
  int frameNum = 0;
  int frameNumWrap = 0;
  int longTermFrameIdx = 0;
  bool shortRef = false;
  bool longRef = false;
  bool neededForOutput = false;
  bool nonExisting = false;
  int ptsUs = 0;

  bool get isRef => shortRef || longRef;
}
