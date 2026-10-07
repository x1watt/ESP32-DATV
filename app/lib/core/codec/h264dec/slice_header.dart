import 'dart:typed_data';

import 'bitreader.dart';
import 'params.dart';

const int sliceP = 0;
const int sliceB = 1;
const int sliceI = 2;
const int sliceSP = 3;
const int sliceSI = 4;

/// One memory_management_control_operation.
class Mmco {
  Mmco(
    this.op,
    this.diffPicNums,
    this.longTermPicNum,
    this.longTermFrameIdx,
    this.maxLongTermFrameIdxPlus1,
  );
  final int op;
  final int diffPicNums; // difference_of_pic_nums_minus1 + 1
  final int longTermPicNum;
  final int longTermFrameIdx;
  final int maxLongTermFrameIdxPlus1;
}

class SliceHeader {
  int nalRefIdc = 0;
  int nalType = 0;
  bool get isIdr => nalType == 5;

  int firstMb = 0;
  int sliceType = 0;
  int ppsId = 0;
  int frameNum = 0;
  bool fieldPic = false;
  bool bottomField = false;
  int idrPicId = 0;
  int pocLsb = 0;
  int deltaPocBottom = 0;
  int deltaPoc0 = 0;
  int deltaPoc1 = 0;
  int redundantPicCnt = 0;
  bool directSpatial = false;
  int numRefIdxL0 = 0;
  int numRefIdxL1 = 0;

  /// Reordering commands per list as (idc, value) pairs.
  final List<List<int>> modifications = [<int>[], <int>[]];

  // Prediction weight table.
  bool hasWeights = false;
  int lumaLog2Denom = 0;
  int chromaLog2Denom = 0;
  final Int32List lumaWeight = Int32List(64);
  final Int32List lumaOffset = Int32List(64);
  final Int32List chromaWeight = Int32List(128);
  final Int32List chromaOffset = Int32List(128);

  // Reference marking.
  bool noOutputOfPriorPics = false;
  bool longTermReference = false;
  bool adaptiveRefPicMarking = false;
  final List<Mmco> mmcos = [];

  int cabacInitIdc = 0;
  int sliceQpDelta = 0;
  int disableDeblockingFilterIdc = 0;
  int sliceAlphaC0Offset = 0;
  int sliceBetaOffset = 0;

  /// Bit position of slice_data() in the RBSP.
  int dataBitPos = 0;

  late Pps pps;
  late Sps sps;

  bool get hasMmco5 => mmcos.any((m) => m.op == 5);

  /// Parses the slice header. [ppsMap] and [spsMap] give active parameter
  /// sets.
  static SliceHeader parse(
    BitReader r,
    int nalType,
    int nalRefIdc,
    Map<int, Pps> ppsMap,
    Map<int, Sps> spsMap,
  ) {
    final h = SliceHeader();
    h.nalType = nalType;
    h.nalRefIdc = nalRefIdc;
    h.firstMb = r.ue();
    var st = r.ue();
    if (st > 9) throw H264Exception('bad slice type');
    if (st >= 5) st -= 5;
    h.sliceType = st;
    h.ppsId = r.ue();
    final pps = ppsMap[h.ppsId];
    if (pps == null) throw H264Exception('missing PPS ${h.ppsId}');
    final sps = spsMap[pps.spsId];
    if (sps == null) throw H264Exception('missing SPS ${pps.spsId}');
    h.pps = pps;
    h.sps = sps;
    if (st == sliceSP || st == sliceSI) {
      throw UnsupportedError('H.264 SP/SI slices (Extended profile) are not supported');
    }
    if (sps.separateColourPlane) r.u(2);
    h.frameNum = r.u(sps.log2MaxFrameNum);
    if (!sps.frameMbsOnly) {
      h.fieldPic = r.flag();
      if (h.fieldPic) h.bottomField = r.flag();
    }
    if (nalType == 5) h.idrPicId = r.ue();
    if (sps.pocType == 0) {
      h.pocLsb = r.u(sps.log2MaxPocLsb);
      if (pps.bottomFieldPicOrderInFramePresent && !h.fieldPic) {
        h.deltaPocBottom = r.se();
      }
    }
    if (sps.pocType == 1 && !sps.deltaPicOrderAlwaysZero) {
      h.deltaPoc0 = r.se();
      if (pps.bottomFieldPicOrderInFramePresent && !h.fieldPic) {
        h.deltaPoc1 = r.se();
      }
    }
    if (pps.redundantPicCntPresent) h.redundantPicCnt = r.ue();
    if (st == sliceB) h.directSpatial = r.flag();
    h.numRefIdxL0 = pps.numRefIdxL0Default;
    h.numRefIdxL1 = pps.numRefIdxL1Default;
    if (st == sliceP || st == sliceB) {
      if (r.flag()) {
        h.numRefIdxL0 = r.ue() + 1;
        if (st == sliceB) h.numRefIdxL1 = r.ue() + 1;
      }
      if (h.numRefIdxL0 > 32 || h.numRefIdxL1 > 32) {
        throw H264Exception('bad num_ref_idx_active');
      }
    }
    if (st != sliceB) h.numRefIdxL1 = 0;
    if (st == sliceI) h.numRefIdxL0 = 0;
    // ref_pic_list_modification()
    if (st != sliceI) {
      for (var list = 0; list < (st == sliceB ? 2 : 1); list++) {
        if (r.flag()) {
          final m = h.modifications[list];
          for (var n = 0; ; n++) {
            final idc = r.ue();
            if (idc == 3) break;
            if (idc > 5 || n > 100) throw H264Exception('bad ref list modification');
            m.add(idc);
            m.add(r.ue());
          }
        }
      }
    }
    if ((pps.weightedPred && st == sliceP) || (pps.weightedBipredIdc == 1 && st == sliceB)) {
      h.hasWeights = true;
      h.lumaLog2Denom = r.ue();
      h.chromaLog2Denom = r.ue();
      if (h.lumaLog2Denom > 7 || h.chromaLog2Denom > 7) {
        throw H264Exception('bad weight denominator');
      }
      for (var list = 0; list < (st == sliceB ? 2 : 1); list++) {
        final n = list == 0 ? h.numRefIdxL0 : h.numRefIdxL1;
        for (var i = 0; i < n; i++) {
          final k = list * 32 + i;
          if (r.flag()) {
            h.lumaWeight[k] = r.se();
            h.lumaOffset[k] = r.se();
          } else {
            h.lumaWeight[k] = 1 << h.lumaLog2Denom;
            h.lumaOffset[k] = 0;
          }
          if (r.flag()) {
            for (var c = 0; c < 2; c++) {
              h.chromaWeight[k * 2 + c] = r.se();
              h.chromaOffset[k * 2 + c] = r.se();
            }
          } else {
            for (var c = 0; c < 2; c++) {
              h.chromaWeight[k * 2 + c] = 1 << h.chromaLog2Denom;
              h.chromaOffset[k * 2 + c] = 0;
            }
          }
        }
      }
    }
    if (nalRefIdc != 0) {
      if (nalType == 5) {
        h.noOutputOfPriorPics = r.flag();
        h.longTermReference = r.flag();
      } else {
        h.adaptiveRefPicMarking = r.flag();
        if (h.adaptiveRefPicMarking) {
          for (var n = 0; ; n++) {
            final op = r.ue();
            if (op == 0) break;
            if (op > 6 || n > 100) throw H264Exception('bad mmco');
            var diff = 0, ltpn = 0, ltfi = 0, maxp1 = 0;
            if (op == 1 || op == 3) diff = r.ue() + 1;
            if (op == 2) ltpn = r.ue();
            if (op == 3 || op == 6) ltfi = r.ue();
            if (op == 4) maxp1 = r.ue();
            h.mmcos.add(Mmco(op, diff, ltpn, ltfi, maxp1));
          }
        }
      }
    }
    if (pps.cabac && st != sliceI) {
      h.cabacInitIdc = r.ue();
      if (h.cabacInitIdc > 2) throw H264Exception('bad cabac_init_idc');
    }
    h.sliceQpDelta = r.se();
    if (pps.deblockingFilterControlPresent) {
      h.disableDeblockingFilterIdc = r.ue();
      if (h.disableDeblockingFilterIdc > 2) throw H264Exception('bad deblocking idc');
      if (h.disableDeblockingFilterIdc != 1) {
        h.sliceAlphaC0Offset = r.se() * 2;
        h.sliceBetaOffset = r.se() * 2;
      }
    }
    if (pps.numSliceGroups > 1) {
      throw UnsupportedError('H.264 slice groups (FMO) are not supported');
    }
    h.dataBitPos = r.pos;
    return h;
  }
}
