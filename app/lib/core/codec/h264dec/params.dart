import 'dart:typed_data';

import 'bitreader.dart';
import 'tables.dart';

final Uint8List _flat16 = Uint8List(16)..fillRange(0, 16, 16);
final Uint8List _flat64 = Uint8List(64)..fillRange(0, 64, 16);

/// Parses one scaling_list() into [out] (raster order). Returns true if
/// useDefaultScalingMatrixFlag was signalled.
bool _parseScalingList(BitReader r, Uint8List out, int size) {
  final scan = size == 16 ? zigzag4x4 : zigzag8x8;
  var last = 8;
  var next = 8;
  for (var j = 0; j < size; j++) {
    if (next != 0) {
      final delta = r.se();
      next = (last + delta + 256) & 255;
      if (j == 0 && next == 0) return true;
    }
    final v = next == 0 ? last : next;
    out[scan[j]] = v;
    last = v;
  }
  return false;
}

/// Raw scaling list syntax: per list, 0 = not present, 1 = explicit,
/// 2 = use default.
class ScalingSyntax {
  ScalingSyntax(int count)
    : state = Uint8List(count),
      lists = List.generate(count, (i) => Uint8List(i < 6 ? 16 : 64));
  final Uint8List state;
  final List<Uint8List> lists;

  static ScalingSyntax parse(BitReader r, int count) {
    final s = ScalingSyntax(count);
    for (var i = 0; i < count; i++) {
      if (r.flag()) {
        final useDefault = _parseScalingList(r, s.lists[i], i < 6 ? 16 : 64);
        s.state[i] = useDefault ? 2 : 1;
      }
    }
    return s;
  }
}

/// Resolved scaling matrices (raster order): 6 4x4 lists and 6 8x8 slots
/// (only slots 0 and 1 matter for 4:2:0: intra Y and inter Y).
class ScalingMatrices {
  ScalingMatrices(this.m4, this.m8);
  final List<Uint8List> m4;
  final List<Uint8List> m8;

  static ScalingMatrices flat() =>
      ScalingMatrices(List.generate(6, (_) => _flat16), List.generate(2, (_) => _flat64));

  /// Applies fall-back rules. [fallback] gives the fall-back for lists 0, 3
  /// (4x4) and 6, 7 (8x8): either defaults (rule A) or the SPS lists (rule B).
  static ScalingMatrices resolve(ScalingSyntax syn, ScalingMatrices? ruleB) {
    final m4 = List<Uint8List>.filled(6, _flat16);
    final m8 = List<Uint8List>.filled(2, _flat64);
    for (var i = 0; i < 6; i++) {
      final st = syn.state[i];
      if (st == 1) {
        m4[i] = syn.lists[i];
      } else if (st == 2) {
        m4[i] = i < 3 ? defaultScaling4Intra : defaultScaling4Inter;
      } else {
        if (i == 0 || i == 3) {
          m4[i] = ruleB != null
              ? ruleB.m4[i]
              : (i == 0 ? defaultScaling4Intra : defaultScaling4Inter);
        } else {
          m4[i] = m4[i - 1];
        }
      }
    }
    for (var i = 0; i < 2; i++) {
      final idx = 6 + i;
      final st = idx < syn.state.length ? syn.state[idx] : 0;
      if (st == 1) {
        m8[i] = syn.lists[idx];
      } else if (st == 2) {
        m8[i] = i == 0 ? defaultScaling8Intra : defaultScaling8Inter;
      } else {
        m8[i] = ruleB != null
            ? ruleB.m8[i]
            : (i == 0 ? defaultScaling8Intra : defaultScaling8Inter);
      }
    }
    return ScalingMatrices(m4, m8);
  }
}

class Sps {
  int profileIdc = 0;
  int constraintFlags = 0;
  int levelIdc = 0;
  int id = 0;
  int chromaFormatIdc = 1;
  bool separateColourPlane = false;
  int bitDepthLuma = 8;
  int bitDepthChroma = 8;
  bool transformBypass = false;
  ScalingMatrices scaling = ScalingMatrices.flat();
  bool scalingPresent = false;
  int log2MaxFrameNum = 4;
  int pocType = 0;
  int log2MaxPocLsb = 4;
  bool deltaPicOrderAlwaysZero = false;
  int offsetForNonRefPic = 0;
  int offsetForTopToBottomField = 0;
  List<int> offsetForRefFrame = const [];
  int maxNumRefFrames = 0;
  bool gapsInFrameNumAllowed = false;
  int picWidthInMbs = 0;
  int picHeightInMapUnits = 0;
  bool frameMbsOnly = true;
  bool mbAdaptiveFrameField = false;
  bool direct8x8Inference = false;
  int cropLeft = 0, cropRight = 0, cropTop = 0, cropBottom = 0;
  // VUI
  bool bitstreamRestriction = false;
  int maxNumReorderFrames = -1;
  int maxDecFrameBuffering = -1;
  int numUnitsInTick = 0;
  int timeScale = 0;

  int get frameHeightInMbs => (frameMbsOnly ? 1 : 2) * picHeightInMapUnits;
  int get width => picWidthInMbs * 16;
  int get height => frameHeightInMbs * 16;
  int get maxFrameNum => 1 << log2MaxFrameNum;

  /// Cropped output rectangle (4:2:0 crop units are 2 samples).
  int get cropX => cropLeft * 2;
  int get cropY => cropTop * 2 * (frameMbsOnly ? 1 : 2);
  int get croppedWidth => width - (cropLeft + cropRight) * 2;
  int get croppedHeight => height - (cropTop + cropBottom) * 2 * (frameMbsOnly ? 1 : 2);

  /// DPB size in frames.
  int get dpbFrames {
    final mbs = picWidthInMbs * frameHeightInMbs;
    var n = mbs > 0 ? maxDpbMbsForLevel(levelIdc, (constraintFlags & 0x10) != 0) ~/ mbs : 16;
    if (n > 16) n = 16;
    if (maxDecFrameBuffering >= 0) n = maxDecFrameBuffering;
    if (n < maxNumRefFrames) n = maxNumRefFrames;
    if (n < 1) n = 1;
    if (n > 16) n = 16;
    return n;
  }

  static Sps parse(BitReader r) {
    final s = Sps();
    s.profileIdc = r.u(8);
    s.constraintFlags = r.u(8);
    s.levelIdc = r.u(8);
    s.id = r.ue();
    if (s.id > 31) throw H264Exception('bad sps id');
    const highProfiles = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135];
    if (highProfiles.contains(s.profileIdc)) {
      s.chromaFormatIdc = r.ue();
      if (s.chromaFormatIdc == 3) s.separateColourPlane = r.flag();
      s.bitDepthLuma = r.ue() + 8;
      s.bitDepthChroma = r.ue() + 8;
      s.transformBypass = r.flag();
      if (r.flag()) {
        s.scalingPresent = true;
        final syn = ScalingSyntax.parse(r, s.chromaFormatIdc != 3 ? 8 : 12);
        s.scaling = ScalingMatrices.resolve(syn, null);
      }
    }
    s.log2MaxFrameNum = r.ue() + 4;
    if (s.log2MaxFrameNum > 16) throw H264Exception('bad log2_max_frame_num');
    s.pocType = r.ue();
    if (s.pocType == 0) {
      s.log2MaxPocLsb = r.ue() + 4;
      if (s.log2MaxPocLsb > 16) throw H264Exception('bad log2_max_poc_lsb');
    } else if (s.pocType == 1) {
      s.deltaPicOrderAlwaysZero = r.flag();
      s.offsetForNonRefPic = r.se();
      s.offsetForTopToBottomField = r.se();
      final n = r.ue();
      if (n > 255) throw H264Exception('bad num_ref_frames_in_poc_cycle');
      s.offsetForRefFrame = List.generate(n, (_) => r.se());
    } else if (s.pocType != 2) {
      throw H264Exception('bad poc type');
    }
    s.maxNumRefFrames = r.ue();
    s.gapsInFrameNumAllowed = r.flag();
    s.picWidthInMbs = r.ue() + 1;
    s.picHeightInMapUnits = r.ue() + 1;
    s.frameMbsOnly = r.flag();
    if (!s.frameMbsOnly) s.mbAdaptiveFrameField = r.flag();
    s.direct8x8Inference = r.flag();
    if (r.flag()) {
      s.cropLeft = r.ue();
      s.cropRight = r.ue();
      s.cropTop = r.ue();
      s.cropBottom = r.ue();
    }
    // Level 6.2 MaxFS is 139264 macroblocks (8K); reject anything larger.
    if (s.picWidthInMbs > 1024 ||
        s.frameHeightInMbs > 1024 ||
        s.picWidthInMbs * s.frameHeightInMbs > 139264) {
      throw H264Exception('picture too large');
    }
    if (s.croppedWidth <= 0 || s.croppedHeight <= 0) {
      s.cropLeft = s.cropRight = s.cropTop = s.cropBottom = 0;
    }
    if (r.flag()) {
      try {
        _parseVui(r, s);
      } catch (_) {
        // Truncated or odd VUI: ignore, the core parameters are valid.
      }
    }
    return s;
  }

  static void _hrd(BitReader r) {
    final cnt = r.ue() + 1;
    r.u(4);
    r.u(4);
    for (var i = 0; i < cnt; i++) {
      r.ue();
      r.ue();
      r.u1();
    }
    r.u(5);
    r.u(5);
    r.u(5);
    r.u(5);
  }

  static void _parseVui(BitReader r, Sps s) {
    if (r.flag()) {
      if (r.u(8) == 255) {
        r.u(16);
        r.u(16);
      }
    }
    if (r.flag()) r.u1();
    if (r.flag()) {
      r.u(4);
      if (r.flag()) r.u(24);
    }
    if (r.flag()) {
      r.ue();
      r.ue();
    }
    if (r.flag()) {
      s.numUnitsInTick = r.uLong(32);
      s.timeScale = r.uLong(32);
      r.u1();
    }
    final nal = r.flag();
    if (nal) _hrd(r);
    final vcl = r.flag();
    if (vcl) _hrd(r);
    if (nal || vcl) r.u1();
    r.u1();
    if (r.flag()) {
      r.u1();
      r.ue();
      r.ue();
      r.ue();
      r.ue();
      final reorder = r.ue();
      final dec = r.ue();
      if (reorder <= 16 && dec <= 16) {
        s.bitstreamRestriction = true;
        s.maxNumReorderFrames = reorder;
        s.maxDecFrameBuffering = dec;
      }
    }
  }
}

class Pps {
  int id = 0;
  int spsId = 0;
  bool cabac = false;
  bool bottomFieldPicOrderInFramePresent = false;
  int numSliceGroups = 1;
  int numRefIdxL0Default = 1;
  int numRefIdxL1Default = 1;
  bool weightedPred = false;
  int weightedBipredIdc = 0;
  int picInitQp = 26;
  int picInitQs = 26;
  int chromaQpIndexOffset = 0;
  int secondChromaQpIndexOffset = 0;
  bool deblockingFilterControlPresent = false;
  bool constrainedIntraPred = false;
  bool redundantPicCntPresent = false;
  bool transform8x8Mode = false;
  ScalingSyntax? scalingSyntax;

  /// Scaling matrices resolved against [Sps]; cached per SPS instance.
  ScalingMatrices? _resolved;
  Sps? _resolvedFor;

  ScalingMatrices scalingFor(Sps sps) {
    if (_resolved != null && identical(_resolvedFor, sps)) return _resolved!;
    final syn = scalingSyntax;
    ScalingMatrices m;
    if (syn == null) {
      m = sps.scaling;
    } else {
      m = ScalingMatrices.resolve(syn, sps.scalingPresent ? sps.scaling : null);
    }
    _resolved = m;
    _resolvedFor = sps;
    return m;
  }

  static Pps parse(BitReader r, Map<int, Sps> spsMap) {
    final p = Pps();
    p.id = r.ue();
    if (p.id > 255) throw H264Exception('bad pps id');
    p.spsId = r.ue();
    if (p.spsId > 31) throw H264Exception('bad sps id in pps');
    p.cabac = r.flag();
    p.bottomFieldPicOrderInFramePresent = r.flag();
    p.numSliceGroups = r.ue() + 1;
    if (p.numSliceGroups > 1) {
      // Slice groups (FMO) are not supported; parse enough to keep going.
      final mapType = r.ue();
      if (mapType == 0) {
        for (var i = 0; i < p.numSliceGroups; i++) {
          r.ue();
        }
      } else if (mapType == 2) {
        for (var i = 0; i < p.numSliceGroups - 1; i++) {
          r.ue();
          r.ue();
        }
      } else if (mapType >= 3 && mapType <= 5) {
        r.u1();
        r.ue();
      } else if (mapType == 6) {
        final n = r.ue() + 1;
        var bits = 0;
        while ((1 << bits) < p.numSliceGroups) {
          bits++;
        }
        for (var i = 0; i < n; i++) {
          r.u(bits);
        }
      }
    }
    p.numRefIdxL0Default = r.ue() + 1;
    p.numRefIdxL1Default = r.ue() + 1;
    if (p.numRefIdxL0Default > 32 || p.numRefIdxL1Default > 32) {
      throw H264Exception('bad num_ref_idx_default');
    }
    p.weightedPred = r.flag();
    p.weightedBipredIdc = r.u(2);
    p.picInitQp = 26 + r.se();
    p.picInitQs = 26 + r.se();
    p.chromaQpIndexOffset = r.se();
    p.deblockingFilterControlPresent = r.flag();
    p.constrainedIntraPred = r.flag();
    p.redundantPicCntPresent = r.flag();
    p.secondChromaQpIndexOffset = p.chromaQpIndexOffset;
    if (r.moreRbspData()) {
      p.transform8x8Mode = r.flag();
      if (r.flag()) {
        final sps = spsMap[p.spsId];
        final cf = sps?.chromaFormatIdc ?? 1;
        final count = 6 + ((cf != 3) ? 2 : 6) * (p.transform8x8Mode ? 1 : 0);
        p.scalingSyntax = ScalingSyntax.parse(r, count);
      }
      p.secondChromaQpIndexOffset = r.se();
    }
    if (p.chromaQpIndexOffset < -12 ||
        p.chromaQpIndexOffset > 12 ||
        p.secondChromaQpIndexOffset < -12 ||
        p.secondChromaQpIndexOffset > 12) {
      throw H264Exception('bad chroma qp offset');
    }
    return p;
  }
}
