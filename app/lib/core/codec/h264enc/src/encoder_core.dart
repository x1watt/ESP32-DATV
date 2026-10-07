// Macroblock level encoder: mode decision, transform coding, reconstruction,
// CAVLC syntax and access unit assembly.

import 'dart:math' as math;
import 'dart:typed_data';

import '../../frame.dart';
import '../h264_encoder.dart';
import 'bit_writer.dart';
import 'cavlc.dart';
import 'deblock.dart';
import 'dsp.dart';
import 'intra_pred.dart';
import 'rate_control.dart';
import 'ref_picture.dart';
import 'tables.dart';

/// Raster 4x4 position (y4 * 4 + x4) to luma4x4BlkIdx.
final Uint8List _rasterToBlk = () {
  final t = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    t[blkToRaster[i]] = i;
  }
  return t;
}();

/// Decimation weights by run length (as in x264).
final Uint8List _decimateTab =
    Uint8List.fromList([3, 2, 2, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);

/// Raster 4x4 block positions belonging to each 8x8 quadrant.
final Uint8List _blocksOf8x8 = Uint8List.fromList(
    [0, 1, 4, 5, 2, 3, 6, 7, 8, 9, 12, 13, 10, 11, 14, 15]);

/// 8-neighbourhood offsets.
final Int8List _sqDx = Int8List.fromList([-1, 0, 1, -1, 1, -1, 0, 1]);
final Int8List _sqDy = Int8List.fromList([-1, -1, -1, 0, 0, 1, 1, 1]);

const int _log2MaxFrameNum = 8;
const int _bigCost = 1 << 30;

class EncoderCore {
  EncoderCore(this.cfg)
      : width = cfg.width,
        height = cfg.height,
        mbW = (cfg.width + 15) >> 4,
        mbH = (cfg.height + 15) >> 4 {
    w16 = mbW * 16;
    h16 = mbH * 16;
    cw = w16 >> 1;
    ch = h16 >> 1;
    mbCount = mbW * mbH;
    srcY = Uint8List(w16 * h16);
    srcU = Uint8List(cw * ch);
    srcV = Uint8List(cw * ch);
    recY = Uint8List(w16 * h16);
    recU = Uint8List(cw * ch);
    recV = Uint8List(cw * ch);
    prevSrcY = Uint8List(w16 * h16);
    ref = RefPicture(w16, h16);
    mbType = Int8List(mbCount);
    mbQp = Uint8List(mbCount);
    nzY = Uint8List(mbCount * 16);
    nzC = Uint8List(mbCount * 8);
    i4Modes = Int8List(mbCount * 16);
    mvs = Int16List(mbCount * 32);
    prevMbMv = Int16List(mbCount * 2);
    rowCplx = Float64List(mbH);
    rc = RateController(
      bitrate: cfg.bitrate,
      fps: cfg.fps,
      vbvBits: cfg.vbvBits,
      qpMin: cfg.qpMin,
      qpMax: cfg.qpMax,
      gopFrames: cfg.gopFrames,
      mbRows: mbH,
    );
    levelIdc = _chooseLevel();
    for (var q = 0; q < 52; q++) {
      _skipSadLimit[q] = (256 * qpToQstep(q.toDouble()) * 0.5).round();
    }
  }

  final H264EncoderConfig cfg;
  final int width, height, mbW, mbH;
  late final int w16, h16, cw, ch, mbCount;
  late final int levelIdc;

  late final Uint8List srcY, srcU, srcV, recY, recU, recV, prevSrcY;
  late final RefPicture ref;
  late final RateController rc;
  late final Float64List rowCplx;

  // Per macroblock state of the picture being coded.
  late final Int8List mbType;
  late final Uint8List mbQp;
  late final Uint8List nzY;
  late final Uint8List nzC;
  late final Int8List i4Modes;
  late final Int16List mvs;
  late final Int16List prevMbMv;

  final BitWriter _bw = BitWriter();
  final BitWriter _hdr = BitWriter();
  final ByteSink _au = ByteSink();
  final CavlcWriter _cavlc = CavlcWriter();
  final Deblocker _deblocker = Deblocker();
  final Intra4x4Edges _edges = Intra4x4Edges();

  bool _hasRef = false;
  bool _idrPending = false;
  int _framesSinceIdr = 0;
  int _frameNum = 0;
  int _idrPicId = 0;
  int vbvViolations = 0;
  int cappedFrames = 0;

  // Scratch buffers.
  final Uint8List _pred16 = Uint8List(4 * 256);
  final Uint8List _pred4 = Uint8List(9 * 16);
  final Uint8List _predC = Uint8List(4 * 128);
  Uint8List _predY = Uint8List(256);
  Uint8List _predTmp = Uint8List(256);
  final Uint8List _predU = Uint8List(64);
  final Uint8List _predV = Uint8List(64);
  final Int32List _dct = Int32List(256);
  final Int32List _dctC = Int32List(128);
  final Int32List _blk = Int32List(16);
  final Int32List _dcTmp = Int32List(16);
  final Int32List _dcC = Int32List(4);
  final Int16List _levY = Int16List(256);
  final Int16List _levDc = Int16List(16);
  final Int16List _levCdc = Int16List(8);
  final Int16List _levCac = Int16List(128);
  final Uint8List _curNz = Uint8List(16);
  final Uint8List _curNzC = Uint8List(8);
  final Int8List _curI4 = Int8List(16);
  final Int8List _curI4Pred = Int8List(16);
  final Int32List _skipSadLimit = Int32List(52);

  // Current macroblock decision.
  int _curType = 0;
  int _curI16Mode = 2;
  int _curCMode = 0;
  int _cbpL = 0;
  int _cbpC = 0;
  int _mvx = 0, _mvy = 0;
  int _mvpx = 0, _mvpy = 0;
  int _qpDelta = 0;
  int _bestI16 = 2;

  // Slice state.
  int _qpPrev = 26;
  int _skipRun = 0;
  int _qpSum = 0;

  // -------------------------------------------------------------------------
  // Frame level

  H264Frame encode(I420Frame f, bool forceIdr) {
    _loadSource(f);
    var idr = forceIdr ||
        !_hasRef ||
        _idrPending ||
        _framesSinceIdr >= math.max(1, cfg.gopFrames);
    _computeComplexity(idr);
    var cplx = 0.0;
    for (var r = 0; r < mbH; r++) {
      cplx += rowCplx[r];
    }
    var qp = rc.startFrame(idr, rowCplx, f.ptsUs);
    final maxBits = rc.maxFrameBits;
    var attempt = 0;
    // While content keeps exceeding the budget go straight to a capped
    // picture instead of trying (and discarding) full encodes first.
    var mode = !idr && _lastCapped ? 2 : 0; // 0 normal, 1 empty, 2 capped
    var cap = maxBits;
    while (true) {
      _buildAccessUnit(idr, qp, mode, cap);
      final bits = _au.length * 8;
      if (bits <= maxBits) {
        // A heavily truncated P picture would starve the bottom rows; an
        // empty picture lets the buffer drain so the next one is complete.
        if (mode == 2 && _forcedCount * 8 > mbCount) {
          // Waiting only helps while the buffer still holds bits.
          if (idr && _hasRef && !forceIdr && rc.fill > 0) {
            // Postpone the IDR until the buffer has room for all of it.
            idr = false;
            _idrPending = true;
            mode = 1;
            continue;
          }
        }
        break;
      }
      attempt++;
      if (mode == 1) {
        vbvViolations++;
        break;
      }
      if (mode == 2) {
        // Only emulation prevention bytes or an infeasible minimum can get
        // here. Tighten the cap; as a last resort postpone the IDR.
        if (attempt < 8) {
          // Shrinking the cap cannot help once every macroblock is forced.
          if (_forcedCount < mbCount) {
            cap -= (bits - maxBits) + 64;
            continue;
          }
          attempt = 8;
        }
        // Even a forced IDR waits rather than overflow the buffer; it is
        // sent as soon as it fits (_idrPending).
        if (idr && _hasRef) {
          idr = false;
          _idrPending = true;
          mode = 1;
          continue;
        }
        vbvViolations++;
        break;
      }
      if (attempt >= 3 || qp >= cfg.qpMax) {
        mode = 2;
        continue;
      }
      qp = rc.retry(bits, maxBits);
    }
    final bits = _au.length * 8;
    final avgQp = mode == 1 ? qp.toDouble() : _qpSum / mbCount;
    if (mode == 2) cappedFrames++;
    _lastCapped = mode == 2 && qp >= cfg.qpMax && _forcedCount > 0;
    if (mode == 1) {
      // Every macroblock is P_Skip with a zero vector: the decoded picture
      // equals the reference, which stays untouched.
    } else {
      _deblocker.filter(recY, recU, recV, mbW, mbH, mbType, mbQp, nzY, mvs);
      ref.build(recY, recU, recV);
      _hasRef = true;
    }
    rc.endFrame(bits, avgQp, idr, cplx, modelValid: mode == 0);
    if (idr) {
      _idrPending = false;
      _framesSinceIdr = 1;
      _frameNum = 1;
      _idrPicId = (_idrPicId + 1) & 0xFFFF;
    } else {
      _framesSinceIdr++;
      _frameNum = (_frameNum + 1) & ((1 << _log2MaxFrameNum) - 1);
    }
    prevSrcY.setRange(0, prevSrcY.length, srcY);
    if (mode == 0 && !idr) {
      for (var a = 0; a < mbCount; a++) {
        prevMbMv[a * 2] = mvs[a * 32];
        prevMbMv[a * 2 + 1] = mvs[a * 32 + 1];
      }
    } else if (idr) {
      prevMbMv.fillRange(0, prevMbMv.length, 0);
    }
    return H264Frame(_au.toBytes(), idr, f.ptsUs, avgQp.round());
  }

  /// Decoded picture of the last frame, cropped to the configured size.
  I420Frame reconstruction() {
    final out = I420Frame.alloc(width, height);
    final rs = ref.stride, p = RefPicture.pad;
    for (var y = 0; y < height; y++) {
      final o = (y + p) * rs + p;
      out.y.setRange(y * width, (y + 1) * width, ref.full, o);
    }
    final cwOut = width >> 1, chOut = height >> 1;
    final crs = ref.cStride, pc = RefPicture.padC;
    for (var y = 0; y < chOut; y++) {
      final o = (y + pc) * crs + pc;
      out.u.setRange(y * cwOut, (y + 1) * cwOut, ref.u, o);
      out.v.setRange(y * cwOut, (y + 1) * cwOut, ref.v, o);
    }
    return out;
  }

  void _loadSource(I420Frame f) {
    final w = width, h = height;
    for (var y = 0; y < h16; y++) {
      final sy = y < h ? y : h - 1;
      final o = y * w16;
      srcY.setRange(o, o + w, f.y, sy * w);
      final last = srcY[o + w - 1];
      for (var x = w; x < w16; x++) {
        srcY[o + x] = last;
      }
    }
    final wc = w >> 1, hc = h >> 1;
    for (var y = 0; y < ch; y++) {
      final sy = y < hc ? y : hc - 1;
      final o = y * cw;
      srcU.setRange(o, o + wc, f.u, sy * wc);
      srcV.setRange(o, o + wc, f.v, sy * wc);
      final lu = srcU[o + wc - 1], lv = srcV[o + wc - 1];
      for (var x = wc; x < cw; x++) {
        srcU[o + x] = lu;
        srcV[o + x] = lv;
      }
    }
  }

  /// Per macroblock row complexity used by rate control.
  void _computeComplexity(bool idr) {
    final s = w16;
    for (var mby = 0; mby < mbH; mby++) {
      var sum = 0;
      final yEnd = mby * 16 + 16;
      for (var y = mby * 16; y < yEnd; y += 2) {
        final o = y * s;
        if (idr) {
          final below = y + 1 < h16 ? s : 0;
          for (var x = 0; x < s - 1; x += 2) {
            final p = srcY[o + x];
            var d = p - srcY[o + x + 1];
            sum += d < 0 ? -d : d;
            d = p - srcY[o + x + below];
            sum += d < 0 ? -d : d;
          }
        } else {
          for (var x = 0; x < s; x += 2) {
            final d = srcY[o + x] - prevSrcY[o + x];
            sum += d < 0 ? -d : d;
          }
        }
      }
      rowCplx[mby] = sum + mbW * 32.0;
    }
  }

  int _chooseLevel() {
    final fs = mbCount;
    final mbps = fs * cfg.fps;
    final br = cfg.bitrate;
    final maxDim = math.max(mbW, mbH);
    // level_idc, MaxMBPS, MaxFS, MaxBR (kbit/s, VCL)
    const levels = <List<int>>[
      [10, 1485, 99, 64],
      [11, 3000, 396, 192],
      [12, 6000, 396, 384],
      [13, 11880, 396, 768],
      [20, 11880, 396, 2000],
      [21, 19800, 792, 4000],
      [22, 20250, 1620, 4000],
      [30, 40500, 1620, 10000],
      [31, 108000, 3600, 14000],
      [32, 216000, 5120, 20000],
      [40, 245760, 8192, 20000],
      [42, 522240, 8704, 50000],
      [50, 589824, 22080, 135000],
      [51, 983040, 36864, 240000],
    ];
    for (final l in levels) {
      if (mbps <= l[1] &&
          fs <= l[2] &&
          br <= l[3] * 1000 &&
          maxDim * maxDim <= 8 * l[2]) {
        return l[0];
      }
    }
    return 51;
  }

  // -------------------------------------------------------------------------
  // Access unit and headers

  void _buildAccessUnit(bool idr, int qp, int mode, int cap) {
    _au.reset();
    _hdr.reset();
    _hdr.bits(3, idr ? 0 : 1); // primary_pic_type
    _hdr.trailing();
    _au.nal(0, 9, _hdr);
    if (idr) {
      _writeSps();
      _au.nal(3, 7, _hdr);
      _writePps();
      _au.nal(3, 8, _hdr);
    }
    final overhead = _au.length * 8 + 40;
    _encodeSlice(idr, qp, mode, overhead, cap);
    _au.nal(idr ? 3 : 2, idr ? 5 : 1, _bw, longStart: false);
  }

  void _writeSps() {
    final b = _hdr;
    b.reset();
    b.bits(8, 66); // profile_idc: Baseline
    b.bits(8, 0xC0); // constraint_set0 and constraint_set1 (Constrained)
    b.bits(8, levelIdc);
    b.ue(0); // seq_parameter_set_id
    b.ue(_log2MaxFrameNum - 4);
    b.ue(2); // pic_order_cnt_type
    b.ue(1); // max_num_ref_frames
    b.bits(1, 0); // gaps_in_frame_num_value_allowed_flag
    b.ue(mbW - 1);
    b.ue(mbH - 1);
    b.bits(1, 1); // frame_mbs_only_flag
    b.bits(1, 1); // direct_8x8_inference_flag
    final cropR = (w16 - width) >> 1, cropB = (h16 - height) >> 1;
    if (cropR != 0 || cropB != 0) {
      b.bits(1, 1);
      b.ue(0);
      b.ue(cropR);
      b.ue(0);
      b.ue(cropB);
    } else {
      b.bits(1, 0);
    }
    if (cfg.vui) {
      b.bits(1, 1);
      b.bits(1, 1); // aspect_ratio_info_present_flag
      b.bits(8, 1); // square samples
      b.bits(1, 0); // overscan_info_present_flag
      b.bits(1, 1); // video_signal_type_present_flag
      b.bits(3, 5); // video_format unspecified
      b.bits(1, 0); // limited range
      b.bits(1, 1); // colour_description_present_flag
      b.bits(8, 6); // SMPTE 170M primaries
      b.bits(8, 6); // transfer
      b.bits(8, 6); // matrix BT.601
      b.bits(1, 0); // chroma_loc_info_present_flag
      b.bits(1, 1); // timing_info_present_flag
      b.u32(1); // num_units_in_tick
      b.u32(2 * cfg.fps); // time_scale
      b.bits(1, 1); // fixed_frame_rate_flag
      b.bits(1, 0); // nal_hrd_parameters_present_flag
      b.bits(1, 0); // vcl_hrd_parameters_present_flag
      b.bits(1, 0); // pic_struct_present_flag
      b.bits(1, 1); // bitstream_restriction_flag
      b.bits(1, 1); // motion_vectors_over_pic_boundaries_flag
      b.ue(0); // max_bytes_per_pic_denom
      b.ue(0); // max_bits_per_mb_denom
      b.ue(8); // log2_max_mv_length_horizontal
      b.ue(8); // log2_max_mv_length_vertical
      b.ue(0); // max_num_reorder_frames
      b.ue(1); // max_dec_frame_buffering
    } else {
      b.bits(1, 0);
    }
    b.trailing();
  }

  void _writePps() {
    final b = _hdr;
    b.reset();
    b.ue(0); // pic_parameter_set_id
    b.ue(0); // seq_parameter_set_id
    b.bits(1, 0); // entropy_coding_mode_flag (CAVLC)
    b.bits(1, 0); // bottom_field_pic_order_in_frame_present_flag
    b.ue(0); // num_slice_groups_minus1
    b.ue(0); // num_ref_idx_l0_default_active_minus1
    b.ue(0); // num_ref_idx_l1_default_active_minus1
    b.bits(1, 0); // weighted_pred_flag
    b.bits(2, 0); // weighted_bipred_idc
    b.se(0); // pic_init_qp_minus26
    b.se(0); // pic_init_qs_minus26
    b.se(0); // chroma_qp_index_offset
    b.bits(1, 1); // deblocking_filter_control_present_flag
    b.bits(1, 0); // constrained_intra_pred_flag
    b.bits(1, 0); // redundant_pic_cnt_present_flag
    b.trailing();
  }

  void _writeSliceHeader(bool idr, int qp) {
    final b = _bw;
    b.ue(0); // first_mb_in_slice
    b.ue(idr ? 7 : 5); // slice_type (all slices of the picture alike)
    b.ue(0); // pic_parameter_set_id
    b.bits(_log2MaxFrameNum, idr ? 0 : _frameNum);
    if (idr) b.ue(_idrPicId);
    if (!idr) {
      b.bits(1, 0); // num_ref_idx_active_override_flag
      b.bits(1, 0); // ref_pic_list_modification_flag_l0
    }
    if (idr) {
      b.bits(1, 0); // no_output_of_prior_pics_flag
      b.bits(1, 0); // long_term_reference_flag
    } else {
      b.bits(1, 0); // adaptive_ref_pic_marking_mode_flag
    }
    b.se(qp - 26); // slice_qp_delta
    b.ue(0); // disable_deblocking_filter_idc
    b.se(0); // slice_alpha_c0_offset_div2
    b.se(0); // slice_beta_offset_div2
  }

  // -------------------------------------------------------------------------
  // Slice data

  void _encodeSlice(bool idr, int qp, int mode, int overheadBits, int cap) {
    _bw.reset();
    _writeSliceHeader(idr, qp);
    _qpPrev = qp;
    _skipRun = 0;
    _qpSum = 0;
    if (mode == 1) {
      // All P_Skip with zero vectors.
      _bw.ue(mbCount);
      _bw.trailing();
      return;
    }
    final capped = mode == 2;
    _forcedCount = 0;
    // Capped P pictures refresh progressively: rows before the row where the
    // previous capped picture ran out of budget are skipped, so content that
    // does not fit in one picture is updated over several.
    final startRow = capped && !idr ? _capStartRow : 0;
    var stopRow = -1;
    for (var mby = 0; mby < mbH; mby++) {
      final rowQp = rc.rowQp(mby, _bw.bitCount + overheadBits);
      for (var mbx = 0; mbx < mbW; mbx++) {
        final addr = mby * mbW + mbx;
        var reserve = 0;
        if (capped && mby < startRow) {
          _forcedMb(idr, mbx, mby);
          continue;
        }
        if (capped) {
          // Bits that must stay available for the rest of the picture.
          reserve = overheadBits +
              (idr ? 14 * (mbCount - addr - 1) + 24 : 48);
          if (_bw.bitCount + reserve > cap) {
            if (stopRow < 0) stopRow = mby;
            _forcedMb(idr, mbx, mby);
            continue;
          }
          _bw.mark();
          _markSkipRun = _skipRun;
          _markQpPrev = _qpPrev;
          _markQpSum = _qpSum;
        }
        if (idr) {
          _mbIntra(mbx, mby, rowQp, true, _bigCost);
          _finishMb(addr, rowQp);
          _writeMb(false);
        } else {
          _mbP(mbx, mby, rowQp);
        }
        if (capped && _bw.bitCount + reserve > cap) {
          _bw.rollback();
          _skipRun = _markSkipRun;
          _qpPrev = _markQpPrev;
          _qpSum = _markQpSum;
          if (stopRow < 0) stopRow = mby;
          _forcedMb(idr, mbx, mby);
        }
      }
    }
    if (capped && !idr) {
      _capStartRow = stopRow < 0 || stopRow == startRow ? 0 : stopRow;
    }
    if (!idr && _skipRun > 0) _bw.ue(_skipRun);
    _bw.trailing();
  }

  int _capStartRow = 0;
  bool _lastCapped = false;
  int _markSkipRun = 0, _markQpPrev = 0, _markQpSum = 0;
  int _forcedCount = 0;

  /// Cheapest possible macroblock: P_Skip, or Intra 16x16 DC without
  /// residual in IDR pictures.
  void _forcedMb(bool idr, int mbx, int mby) {
    _forcedCount++;
    if (idr) {
      _mbMinimalIntra(mbx, mby, _qpPrev);
      return;
    }
    _mvPred16(mbx, mby);
    _skipMv(mbx, mby);
    final x0 = mbx * 16, y0 = mby * 16;
    ref.mcLuma(recY, y0 * w16 + x0, w16, x0, y0, _smx, _smy, 16, 16);
    final co = mby * 8 * cw + mbx * 8;
    ref.mcChroma(recU, recV, co, cw, mbx * 8, mby * 8, _smx, _smy, 8, 8);
    _curType = mbSkip;
    _mvx = _smx;
    _mvy = _smy;
    _finishMb(mby * mbW + mbx, _qpPrev);
    _skipRun++;
  }

  int _smx = 0, _smy = 0;

  /// P_Skip motion vector (8.4.1.1). Requires _mvPred16 to have run.
  void _skipMv(int mbx, int mby) {
    _smx = 0;
    _smy = 0;
    if (mbx > 0 && mby > 0) {
      final addr = mby * mbW + mbx;
      final a = addr - 1, b = addr - mbW;
      final aZero = mbType[a] < mbI4x4 &&
          mvs[(a * 16 + 3) * 2] == 0 &&
          mvs[(a * 16 + 3) * 2 + 1] == 0;
      final bZero = mbType[b] < mbI4x4 &&
          mvs[(b * 16 + 12) * 2] == 0 &&
          mvs[(b * 16 + 12) * 2 + 1] == 0;
      if (!aZero && !bZero) {
        _smx = _mvpx;
        _smy = _mvpy;
      }
    }
  }

  // -------------------------------------------------------------------------
  // Intra macroblocks

  /// Full intra decision and coding. Returns false when [limit] is beaten by
  /// nothing (only used for P pictures, where the caller already compared).
  void _mbIntra(int mbx, int mby, int qp, bool allowI4, int i16CostKnown) {
    final lambda = lambdaTab[qp];
    final cost16 =
        i16CostKnown == _bigCost ? _analyseI16(mbx, mby, lambda) : i16CostKnown;
    var useI4 = false;
    if (allowI4) {
      final cost4 = _analyseI4(mbx, mby, qp, lambda, cost16);
      useI4 = cost4 >= 0 && cost4 < cost16;
    }
    if (useI4) {
      _curType = mbI4x4;
    } else {
      _curType = mbI16x16;
      _curI16Mode = _bestI16;
      _codeI16(mbx, mby, qp, _bestI16);
    }
    _curCMode = _analyseChroma(mbx, mby);
    _codeChroma(mbx, mby, chromaQpTable[qp], true, _predC, _curCMode * 128,
        _predC, _curCMode * 128 + 64, 8);
    _mvx = 0;
    _mvy = 0;
  }

  /// Fallback picture: Intra 16x16 DC prediction everywhere, no residual.
  void _mbMinimalIntra(int mbx, int mby, int qp) {
    final x0 = mbx * 16, y0 = mby * 16;
    predict16x16(2, recY, w16, x0, y0, mby > 0, mbx > 0, _pred16, 0);
    for (var y = 0; y < 16; y++) {
      recY.setRange((y0 + y) * w16 + x0, (y0 + y) * w16 + x0 + 16, _pred16,
          y * 16);
    }
    final cx = mbx * 8, cy = mby * 8;
    predictChroma(0, recU, cw, cx, cy, mby > 0, mbx > 0, _predC, 0);
    predictChroma(0, recV, cw, cx, cy, mby > 0, mbx > 0, _predC, 64);
    for (var y = 0; y < 8; y++) {
      recU.setRange((cy + y) * cw + cx, (cy + y) * cw + cx + 8, _predC, y * 8);
      recV.setRange(
          (cy + y) * cw + cx, (cy + y) * cw + cx + 8, _predC, 64 + y * 8);
    }
    _curType = mbI16x16;
    _curI16Mode = 2;
    _curCMode = 0;
    _cbpL = 0;
    _cbpC = 0;
    _levDc.fillRange(0, 16, 0);
    _curNz.fillRange(0, 16, 0);
    _curNzC.fillRange(0, 8, 0);
    _mvx = 0;
    _mvy = 0;
    _finishMb(mby * mbW + mbx, qp);
    _writeMb(false);
  }

  int _analyseI16(int mbx, int mby, int lambda) {
    final x0 = mbx * 16, y0 = mby * 16;
    final top = mby > 0, left = mbx > 0;
    final so = y0 * w16 + x0;
    var best = 2, bestCost = _bigCost;
    for (var m = 0; m < 4; m++) {
      if (m == 0 && !top) continue;
      if (m == 1 && !left) continue;
      if (m == 3 && !(top && left)) continue;
      predict16x16(m, recY, w16, x0, y0, top, left, _pred16, m * 256);
      final c = satdWxH(srcY, so, w16, _pred16, m * 256, 16, 16, 16) +
          lambda * (m == 2 ? 3 : 4);
      if (c < bestCost) {
        bestCost = c;
        best = m;
      }
    }
    _bestI16 = best;
    return bestCost;
  }

  int _predI4Mode(int mbx, int mby, int bx, int by) {
    int a, b;
    if (bx > 0) {
      a = _curI4[by * 4 + bx - 1];
    } else if (mbx > 0) {
      final n = mby * mbW + mbx - 1;
      a = mbType[n] == mbI4x4 ? i4Modes[n * 16 + by * 4 + 3] : 2;
    } else {
      return 2;
    }
    if (by > 0) {
      b = _curI4[(by - 1) * 4 + bx];
    } else if (mby > 0) {
      final n = (mby - 1) * mbW + mbx;
      b = mbType[n] == mbI4x4 ? i4Modes[n * 16 + 12 + bx] : 2;
    } else {
      return 2;
    }
    return a < b ? a : b;
  }

  /// Intra 4x4 analysis with coding and reconstruction of every block.
  /// Returns the cost or -1 when it exceeded [limit].
  int _analyseI4(int mbx, int mby, int qp, int lambda, int limit) {
    final x0 = mbx * 16, y0 = mby * 16;
    final mbTop = mby > 0, mbLeft = mbx > 0;
    final mbTR = mbTop && mbx < mbW - 1, mbTL = mbTop && mbLeft;
    final e = _edges;
    final pred = _pred4;
    var cost = lambda * 6;
    for (var bi = 0; bi < 16; bi++) {
      final r = blkToRaster[bi];
      final bx = r & 3, by = r >> 2;
      final px = x0 + bx * 4, py = y0 + by * 4;
      final top = by > 0 || mbTop;
      final left = bx > 0 || mbLeft;
      final tl = bx > 0 ? (by > 0 ? true : mbTop) : (by > 0 ? mbLeft : mbTL);
      bool tr;
      if (by == 0) {
        tr = bx < 3 ? mbTop : mbTR;
      } else {
        tr = bx < 3 && _rasterToBlk[(by - 1) * 4 + bx + 1] < bi;
      }
      e.load(recY, w16, px, py, top, left, tl, tr);
      final pm = _predI4Mode(mbx, mby, bx, by);
      final so = py * w16 + px;
      var best = 2, bestCost = _bigCost;
      for (var m = 0; m < 9; m++) {
        if (!e.modeAvailable(m)) continue;
        e.predict(m, pred, m * 16);
        final c = satd4x4(srcY, so, w16, pred, m * 16, 4) +
            lambda * (m == pm ? 1 : 4);
        if (c < bestCost) {
          bestCost = c;
          best = m;
        }
      }
      cost += bestCost;
      if (cost > limit) return -1;
      _curI4[r] = best;
      _curI4Pred[r] = pm;
      final po = best * 16;
      fdct4x4(srcY, so, w16, pred, po, 4, _dct, r * 16);
      final n = quant4x4(_dct, r * 16, _levY, r * 16, qp, true, false);
      _curNz[r] = n;
      if (n > 0) {
        dequant4x4(_levY, r * 16, qp, _blk, false, 0);
        idctAdd4x4(_blk, pred, po, 4, recY, so, w16);
      } else {
        copy4x4(pred, po, 4, recY, so, w16);
      }
    }
    var cbp = 0;
    for (var i8 = 0; i8 < 4; i8++) {
      for (var k = 0; k < 4; k++) {
        if (_curNz[_blocksOf8x8[i8 * 4 + k]] != 0) {
          cbp |= 1 << i8;
          break;
        }
      }
    }
    _cbpL = cbp;
    return cost;
  }

  void _codeI16(int mbx, int mby, int qp, int mode) {
    final x0 = mbx * 16, y0 = mby * 16;
    final so = y0 * w16 + x0;
    final po = mode * 256;
    final pred = _pred16;
    final dct = _dct;
    for (var r = 0; r < 16; r++) {
      final bx = r & 3, by = r >> 2;
      fdct4x4(srcY, so + by * 4 * w16 + bx * 4, w16, pred,
          po + by * 64 + bx * 4, 16, dct, r * 16);
    }
    // Luma DC: Hadamard, quantisation (8.5.10 inverse).
    final t = _dcTmp;
    for (var r = 0; r < 16; r++) {
      t[r] = dct[r * 16];
    }
    _hadamard4x4(t);
    final mf0 = quantMF[qp % 6][0];
    final qbits = 16 + qp ~/ 6;
    final f2 = (1 << qbits) ~/ 3;
    var anyDc = false;
    for (var i = 0; i < 16; i++) {
      final w = t[zigzag4x4[i]] >> 1;
      int l;
      if (w >= 0) {
        l = (w * mf0 + f2) >> qbits;
      } else {
        l = -((-w * mf0 + f2) >> qbits);
      }
      if (l > maxCoeffLevel) l = maxCoeffLevel;
      if (l < -maxCoeffLevel) l = -maxCoeffLevel;
      if (l != 0) anyDc = true;
      _levDc[i] = l;
    }
    var anyAc = false;
    for (var r = 0; r < 16; r++) {
      final n = quant4x4(dct, r * 16, _levY, r * 16, qp, true, true);
      _curNz[r] = n;
      if (n != 0) anyAc = true;
    }
    _cbpL = anyAc ? 15 : 0;
    // Reconstruction: DC inverse transform and scaling.
    if (anyDc) {
      for (var i = 0; i < 16; i++) {
        t[zigzag4x4[i]] = _levDc[i];
      }
      _hadamard4x4(t);
      final ls = 16 * dequantV[qp % 6][0];
      final q6 = qp ~/ 6;
      for (var i = 0; i < 16; i++) {
        if (qp >= 36) {
          t[i] = (t[i] * ls) * (1 << (q6 - 6));
        } else {
          t[i] = (t[i] * ls + (1 << (5 - q6))) >> (6 - q6);
        }
      }
    } else {
      t.fillRange(0, 16, 0);
    }
    for (var r = 0; r < 16; r++) {
      final bx = r & 3, by = r >> 2;
      final ro = so + by * 4 * w16 + bx * 4;
      final pOff = po + by * 64 + bx * 4;
      if (_curNz[r] == 0 && t[r] == 0) {
        copy4x4(pred, pOff, 16, recY, ro, w16);
      } else {
        dequant4x4(_levY, r * 16, qp, _blk, true, t[r]);
        idctAdd4x4(_blk, pred, pOff, 16, recY, ro, w16);
      }
    }
  }

  static void _hadamard4x4(Int32List t) {
    for (var y = 0; y < 16; y += 4) {
      final x0 = t[y], x1 = t[y + 1], x2 = t[y + 2], x3 = t[y + 3];
      final s01 = x0 + x1, s23 = x2 + x3, d01 = x0 - x1, d23 = x2 - x3;
      t[y] = s01 + s23;
      t[y + 1] = s01 - s23;
      t[y + 2] = d01 - d23;
      t[y + 3] = d01 + d23;
    }
    for (var x = 0; x < 4; x++) {
      final x0 = t[x], x1 = t[x + 4], x2 = t[x + 8], x3 = t[x + 12];
      final s01 = x0 + x1, s23 = x2 + x3, d01 = x0 - x1, d23 = x2 - x3;
      t[x] = s01 + s23;
      t[x + 4] = s01 - s23;
      t[x + 8] = d01 - d23;
      t[x + 12] = d01 + d23;
    }
  }

  int _analyseChroma(int mbx, int mby) {
    final cx = mbx * 8, cy = mby * 8;
    final top = mby > 0, left = mbx > 0;
    final so = cy * cw + cx;
    var best = 0, bestCost = _bigCost;
    for (var m = 0; m < 4; m++) {
      if (m == 1 && !left) continue;
      if (m == 2 && !top) continue;
      if (m == 3 && !(top && left)) continue;
      predictChroma(m, recU, cw, cx, cy, top, left, _predC, m * 128);
      predictChroma(m, recV, cw, cx, cy, top, left, _predC, m * 128 + 64);
      final c = satdWxH(srcU, so, cw, _predC, m * 128, 8, 8, 8) +
          satdWxH(srcV, so, cw, _predC, m * 128 + 64, 8, 8, 8);
      if (c < bestCost) {
        bestCost = c;
        best = m;
      }
    }
    return best;
  }

  /// Codes both chroma components against the given predictions.
  void _codeChroma(int mbx, int mby, int qpc, bool intra, Uint8List pU,
      int pUo, Uint8List pV, int pVo, int ps) {
    final cx = mbx * 8, cy = mby * 8;
    final so = cy * cw + cx;
    final dct = _dctC;
    final mf0 = quantMF[qpc % 6][0];
    final qbits = 16 + qpc ~/ 6;
    final f2 = intra ? (1 << qbits) ~/ 3 : (1 << qbits) ~/ 6;
    var anyDc = false, anyAc = false;
    for (var comp = 0; comp < 2; comp++) {
      final src = comp == 0 ? srcU : srcV;
      final pred = comp == 0 ? pU : pV;
      final po = comp == 0 ? pUo : pVo;
      final base = comp * 64;
      for (var b = 0; b < 4; b++) {
        final bx = b & 1, by = b >> 1;
        fdct4x4(src, so + by * 4 * cw + bx * 4, cw, pred,
            po + by * 4 * ps + bx * 4, ps, dct, base + b * 16);
      }
      final c0 = dct[base], c1 = dct[base + 16];
      final c2 = dct[base + 32], c3 = dct[base + 48];
      final f0 = c0 + c1 + c2 + c3, f1 = c0 - c1 + c2 - c3;
      final f2v = c0 + c1 - c2 - c3, f3 = c0 - c1 - c2 + c3;
      for (var i = 0; i < 4; i++) {
        final w = i == 0 ? f0 : (i == 1 ? f1 : (i == 2 ? f2v : f3));
        int l;
        if (w >= 0) {
          l = (w * mf0 + f2) >> qbits;
        } else {
          l = -((-w * mf0 + f2) >> qbits);
        }
        if (l > maxCoeffLevel) l = maxCoeffLevel;
        if (l < -maxCoeffLevel) l = -maxCoeffLevel;
        if (l != 0) anyDc = true;
        _levCdc[comp * 4 + i] = l;
      }
      var compAc = false;
      var score = 0;
      for (var b = 0; b < 4; b++) {
        final n = quant4x4(
            dct, base + b * 16, _levCac, base + b * 16, qpc, intra, true);
        _curNzC[comp * 4 + b] = n;
        if (n != 0) {
          compAc = true;
          if (!intra) score += _decimateScore(_levCac, base + b * 16 + 1, 15);
        }
      }
      if (compAc && !intra && score < 7) {
        _levCac.fillRange(base, base + 64, 0);
        for (var b = 0; b < 4; b++) {
          _curNzC[comp * 4 + b] = 0;
        }
        compAc = false;
      }
      if (compAc) anyAc = true;
    }
    _cbpC = anyAc ? 2 : (anyDc ? 1 : 0);
    // Reconstruction.
    final v0 = dequantV[qpc % 6][0];
    final q6 = qpc ~/ 6;
    for (var comp = 0; comp < 2; comp++) {
      final rec = comp == 0 ? recU : recV;
      final pred = comp == 0 ? pU : pV;
      final po = comp == 0 ? pUo : pVo;
      final base = comp * 64;
      final l0 = _levCdc[comp * 4], l1 = _levCdc[comp * 4 + 1];
      final l2 = _levCdc[comp * 4 + 2], l3 = _levCdc[comp * 4 + 3];
      final dc = _dcC;
      dc[0] = l0 + l1 + l2 + l3;
      dc[1] = l0 - l1 + l2 - l3;
      dc[2] = l0 + l1 - l2 - l3;
      dc[3] = l0 - l1 - l2 + l3;
      for (var i = 0; i < 4; i++) {
        dc[i] = (dc[i] * 16 * v0 * (1 << q6)) >> 5;
      }
      for (var b = 0; b < 4; b++) {
        final bx = b & 1, by = b >> 1;
        final ro = so + by * 4 * cw + bx * 4;
        final pOff = po + by * 4 * ps + bx * 4;
        if (_cbpC == 0 || (dc[b] == 0 && _curNzC[comp * 4 + b] == 0)) {
          copy4x4(pred, pOff, ps, rec, ro, cw);
        } else {
          dequant4x4(_levCac, base + b * 16, qpc, _blk, true, dc[b]);
          idctAdd4x4(_blk, pred, pOff, ps, rec, ro, cw);
        }
      }
    }
  }

  static int _decimateScore(Int16List lev, int off, int n) {
    var idx = n - 1;
    while (idx >= 0 && lev[off + idx] == 0) {
      idx--;
    }
    var score = 0;
    while (idx >= 0) {
      final v = lev[off + idx];
      if (v > 1 || v < -1) return 9;
      idx--;
      var run = 0;
      while (idx >= 0 && lev[off + idx] == 0) {
        idx--;
        run++;
      }
      score += _decimateTab[run];
    }
    return score;
  }

  // -------------------------------------------------------------------------
  // Inter macroblocks

  void _mbP(int mbx, int mby, int qp) {
    final addr = mby * mbW + mbx;
    final x0 = mbx * 16, y0 = mby * 16;
    final so = y0 * w16 + x0;
    final lambda = lambdaTab[qp];
    _mvPred16(mbx, mby);
    final mvpx = _mvpx, mvpy = _mvpy;
    _skipMv(mbx, mby);
    final smx = _smx, smy = _smy;
    // Early skip: residual against the skip prediction quantises to zero.
    ref.mcLuma(_predY, 0, 16, x0, y0, smx, smy, 16, 16);
    final skipSad = sad16x16(srcY, so, w16, _predY, 0, 16, _bigCost);
    if (skipSad <= _skipSadLimit[qp]) {
      _codeInterLuma(mbx, mby, qp);
      if (_cbpL == 0) {
        ref.mcChroma(_predU, _predV, 0, 8, mbx * 8, mby * 8, smx, smy, 8, 8);
        _codeChroma(mbx, mby, chromaQpTable[qp], false, _predU, 0, _predV, 0, 8);
        if (_cbpC == 0) {
          _curType = mbSkip;
          _mvx = smx;
          _mvy = smy;
          _finishMb(addr, qp);
          _skipRun++;
          return;
        }
      }
    }
    final interCost = _motionSearch(mbx, mby, mvpx, mvpy, smx, smy, lambda);
    // Intra alternative.
    // Skip the intra check when the inter prediction is already very good.
    final cost16 = interCost <= 512
        ? _bigCost
        : _analyseI16(mbx, mby, lambda) + lambda * 4;
    if (cost16 < interCost) {
      _mbIntra(mbx, mby, qp, cfg.preset != H264Preset.fast, cost16);
      _finishMb(addr, qp);
      _writeMb(true);
      return;
    }
    ref.mcChroma(_predU, _predV, 0, 8, mbx * 8, mby * 8, _mvx, _mvy, 8, 8);
    _codeInterLuma(mbx, mby, qp);
    _codeChroma(mbx, mby, chromaQpTable[qp], false, _predU, 0, _predV, 0, 8);
    if (_cbpL == 0 && _cbpC == 0 && _mvx == smx && _mvy == smy) {
      _curType = mbSkip;
      _finishMb(addr, qp);
      _skipRun++;
      return;
    }
    _curType = mbInter;
    _finishMb(addr, qp);
    _writeMb(true);
  }

  /// Median motion vector prediction for a 16x16 partition (8.4.1.3).
  void _mvPred16(int mbx, int mby) {
    final addr = mby * mbW + mbx;
    final aAvail = mbx > 0, bAvail = mby > 0;
    var refA = -1, refB = -1, refC = -1;
    var ax = 0, ay = 0, bx = 0, by = 0, cx = 0, cy = 0;
    if (aAvail) {
      final n = addr - 1;
      if (mbType[n] < mbI4x4) {
        refA = 0;
        ax = mvs[(n * 16 + 3) * 2];
        ay = mvs[(n * 16 + 3) * 2 + 1];
      }
    }
    if (bAvail) {
      final n = addr - mbW;
      if (mbType[n] < mbI4x4) {
        refB = 0;
        bx = mvs[(n * 16 + 12) * 2];
        by = mvs[(n * 16 + 12) * 2 + 1];
      }
    }
    var cAvail = false;
    if (mby > 0 && mbx < mbW - 1) {
      cAvail = true;
      final n = addr - mbW + 1;
      if (mbType[n] < mbI4x4) {
        refC = 0;
        cx = mvs[(n * 16 + 12) * 2];
        cy = mvs[(n * 16 + 12) * 2 + 1];
      }
    } else if (mby > 0 && mbx > 0) {
      cAvail = true;
      final n = addr - mbW - 1;
      if (mbType[n] < mbI4x4) {
        refC = 0;
        cx = mvs[(n * 16 + 15) * 2];
        cy = mvs[(n * 16 + 15) * 2 + 1];
      }
    }
    if (!bAvail && !cAvail && aAvail) {
      refB = refA;
      refC = refA;
      bx = ax;
      by = ay;
      cx = ax;
      cy = ay;
    }
    final matches =
        (refA == 0 ? 1 : 0) + (refB == 0 ? 1 : 0) + (refC == 0 ? 1 : 0);
    if (matches == 1) {
      if (refA == 0) {
        _mvpx = ax;
        _mvpy = ay;
      } else if (refB == 0) {
        _mvpx = bx;
        _mvpy = by;
      } else {
        _mvpx = cx;
        _mvpy = cy;
      }
    } else {
      _mvpx = _median(ax, bx, cx);
      _mvpy = _median(ay, by, cy);
    }
  }

  static int _median(int a, int b, int c) {
    final mn = a < b ? (a < c ? a : c) : (b < c ? b : c);
    final mx = a > b ? (a > c ? a : c) : (b > c ? b : c);
    return a + b + c - mn - mx;
  }

  // Integer search state.
  int _bx = 0, _by = 0, _bcost = 0;
  int _sOff = 0, _sBase = 0, _sMvpx = 0, _sMvpy = 0, _sLambda = 0;

  void _checkInt(int ix, int iy) {
    if (ix < -32 || ix > 32 || iy < -32 || iy > 32) return;
    final bits = seBits[ix * 4 - _sMvpx + 2048] + seBits[iy * 4 - _sMvpy + 2048];
    final mvCost = _sLambda * bits;
    if (mvCost >= _bcost) return;
    final rs = ref.stride;
    final sad = sad16x16(srcY, _sOff, w16, ref.full, _sBase + iy * rs + ix, rs,
        _bcost - mvCost);
    final c = sad + mvCost;
    if (c < _bcost) {
      _bcost = c;
      _bx = ix;
      _by = iy;
    }
  }

  /// Motion search for the 16x16 partition. Leaves the best vector in
  /// _mvx/_mvy, its prediction in _predY and returns its cost.
  int _motionSearch(
      int mbx, int mby, int mvpx, int mvpy, int smx, int smy, int lambda) {
    final x0 = mbx * 16, y0 = mby * 16;
    final addr = mby * mbW + mbx;
    _sOff = y0 * w16 + x0;
    _sBase = (y0 + RefPicture.pad) * ref.stride + x0 + RefPicture.pad;
    _sMvpx = mvpx;
    _sMvpy = mvpy;
    _sLambda = lambda;
    _bcost = _bigCost;
    _bx = 0;
    _by = 0;
    _checkInt(0, 0);
    _checkInt((mvpx + 2) >> 2, (mvpy + 2) >> 2);
    _checkInt((smx + 2) >> 2, (smy + 2) >> 2);
    if (mbx > 0) {
      final n = (addr - 1) * 32;
      _checkInt((mvs[n] + 2) >> 2, (mvs[n + 1] + 2) >> 2);
    }
    if (mby > 0) {
      final n = (addr - mbW) * 32;
      _checkInt((mvs[n] + 2) >> 2, (mvs[n + 1] + 2) >> 2);
      if (mbx < mbW - 1) {
        final n2 = (addr - mbW + 1) * 32;
        _checkInt((mvs[n2] + 2) >> 2, (mvs[n2 + 1] + 2) >> 2);
      }
    }
    _checkInt((prevMbMv[addr * 2] + 2) >> 2, (prevMbMv[addr * 2 + 1] + 2) >> 2);
    // Hexagon search.
    for (var it = 0; it < 16; it++) {
      final cx = _bx, cy = _by;
      _checkInt(cx - 2, cy);
      _checkInt(cx + 2, cy);
      _checkInt(cx - 1, cy - 2);
      _checkInt(cx + 1, cy - 2);
      _checkInt(cx - 1, cy + 2);
      _checkInt(cx + 1, cy + 2);
      if (_bx == cx && _by == cy) break;
    }
    // Square refinement.
    {
      final cx = _bx, cy = _by;
      _checkInt(cx - 1, cy - 1);
      _checkInt(cx, cy - 1);
      _checkInt(cx + 1, cy - 1);
      _checkInt(cx - 1, cy);
      _checkInt(cx + 1, cy);
      _checkInt(cx - 1, cy + 1);
      _checkInt(cx, cy + 1);
      _checkInt(cx + 1, cy + 1);
    }
    // Half sample refinement with SAD, starting from the better of the
    // integer result and the exact predictor.
    var qx = _bx * 4, qy = _by * 4;
    var bestSad = _bcost;
    if ((mvpx != qx || mvpy != qy) &&
        mvpx.abs() <= maxMvQpel &&
        mvpy.abs() <= maxMvQpel) {
      final c = _sadSub(x0, y0, mvpx, mvpy, lambda, bestSad);
      if (c < bestSad) {
        bestSad = c;
        qx = mvpx;
        qy = mvpy;
      }
    }
    final fast = cfg.preset == H264Preset.fast;
    for (var pass = 0; pass < (fast ? 2 : 1); pass++) {
      final step = pass == 0 ? 2 : 1;
      final cx = qx, cy = qy;
      for (var k = 0; k < 8; k++) {
        if (pass == 1 && _sqDx[k] != 0 && _sqDy[k] != 0) continue;
        final nx = cx + _sqDx[k] * step, ny = cy + _sqDy[k] * step;
        final c = _sadSub(x0, y0, nx, ny, lambda, bestSad);
        if (c < bestSad) {
          bestSad = c;
          qx = nx;
          qy = ny;
        }
      }
    }
    // Quarter sample refinement with SATD.
    ref.mcLuma(_predY, 0, 16, x0, y0, qx, qy, 16, 16);
    var best = satdWxH(srcY, _sOff, w16, _predY, 0, 16, 16, 16) +
        lambda * (seBits[qx - mvpx + 2048] + seBits[qy - mvpy + 2048]);
    if (!fast) {
      final cx = qx, cy = qy;
      for (var k = 0; k < 8; k++) {
        final nx = cx + _sqDx[k], ny = cy + _sqDy[k];
        if (nx < -maxMvQpel ||
            nx > maxMvQpel ||
            ny < -maxMvQpel ||
            ny > maxMvQpel) {
          continue;
        }
        final mvCost =
            lambda * (seBits[nx - mvpx + 2048] + seBits[ny - mvpy + 2048]);
        if (mvCost >= best) continue;
        ref.mcLuma(_predTmp, 0, 16, x0, y0, nx, ny, 16, 16);
        final c = satdWxH(srcY, _sOff, w16, _predTmp, 0, 16, 16, 16) + mvCost;
        if (c < best) {
          best = c;
          qx = nx;
          qy = ny;
          final t = _predY;
          _predY = _predTmp;
          _predTmp = t;
        }
      }
    }
    _mvx = qx;
    _mvy = qy;
    return best + lambda;
  }

  /// SAD plus vector cost of a sub-sample position (prediction in _predTmp).
  int _sadSub(int x0, int y0, int qx, int qy, int lambda, int limit) {
    if (qx < -maxMvQpel || qx > maxMvQpel || qy < -maxMvQpel || qy > maxMvQpel) {
      return _bigCost;
    }
    final mvCost =
        lambda * (seBits[qx - _sMvpx + 2048] + seBits[qy - _sMvpy + 2048]);
    if (mvCost >= limit) return _bigCost;
    ref.mcLuma(_predTmp, 0, 16, x0, y0, qx, qy, 16, 16);
    return sad16x16(srcY, _sOff, w16, _predTmp, 0, 16, limit - mvCost) + mvCost;
  }

  /// Transform codes the luma residual against _predY (inter) and
  /// reconstructs it.
  void _codeInterLuma(int mbx, int mby, int qp) {
    final x0 = mbx * 16, y0 = mby * 16;
    final so = y0 * w16 + x0;
    final pred = _predY;
    final dct = _dct;
    final lev = _levY;
    for (var r = 0; r < 16; r++) {
      final bx = r & 3, by = r >> 2;
      fdct4x4(srcY, so + by * 4 * w16 + bx * 4, w16, pred, by * 64 + bx * 4,
          16, dct, r * 16);
      _curNz[r] = quant4x4(dct, r * 16, lev, r * 16, qp, false, false);
    }
    // Decimation of isolated small coefficients.
    var total = 0;
    var cbp = 0;
    for (var i8 = 0; i8 < 4; i8++) {
      var score = 0;
      var any = false;
      for (var k = 0; k < 4; k++) {
        final r = _blocksOf8x8[i8 * 4 + k];
        if (_curNz[r] != 0) {
          any = true;
          score += _decimateScore(lev, r * 16, 16);
        }
      }
      if (!any) continue;
      if (score < 4) {
        for (var k = 0; k < 4; k++) {
          final r = _blocksOf8x8[i8 * 4 + k];
          lev.fillRange(r * 16, r * 16 + 16, 0);
          _curNz[r] = 0;
        }
      } else {
        cbp |= 1 << i8;
      }
      total += score;
    }
    if (cbp != 0 && total < 6) {
      lev.fillRange(0, 256, 0);
      _curNz.fillRange(0, 16, 0);
      cbp = 0;
    }
    _cbpL = cbp;
    for (var r = 0; r < 16; r++) {
      final bx = r & 3, by = r >> 2;
      final ro = so + by * 4 * w16 + bx * 4;
      final pOff = by * 64 + bx * 4;
      if (_curNz[r] == 0) {
        copy4x4(pred, pOff, 16, recY, ro, w16);
      } else {
        dequant4x4(lev, r * 16, qp, _blk, false, 0);
        idctAdd4x4(_blk, pred, pOff, 16, recY, ro, w16);
      }
    }
  }

  // -------------------------------------------------------------------------
  // Macroblock bookkeeping and syntax

  void _finishMb(int addr, int qp) {
    _curAddr = addr;
    final t = _curType;
    if (t == mbSkip) {
      _cbpL = 0;
      _cbpC = 0;
      _curNz.fillRange(0, 16, 0);
      _curNzC.fillRange(0, 8, 0);
    }
    final hasDelta = t == mbI16x16 || (t != mbSkip && (_cbpL | _cbpC) != 0);
    if (hasDelta) {
      mbQp[addr] = qp;
      var d = qp - _qpPrev;
      if (d < -26) d += 52;
      if (d > 25) d -= 52;
      _qpDelta = d;
      _qpPrev = qp;
    } else {
      mbQp[addr] = _qpPrev;
      _qpDelta = 0;
    }
    _qpSum += mbQp[addr];
    mbType[addr] = t;
    final o = addr * 16;
    if (t == mbI16x16 && _cbpL == 0) {
      nzY.fillRange(o, o + 16, 0);
    } else {
      nzY.setRange(o, o + 16, _curNz);
    }
    if (_cbpC == 2) {
      nzC.setRange(addr * 8, addr * 8 + 8, _curNzC);
    } else {
      nzC.fillRange(addr * 8, addr * 8 + 8, 0);
    }
    if (t == mbI4x4) {
      i4Modes.setRange(o, o + 16, _curI4);
    }
    final mx = t <= mbInter ? _mvx : 0;
    final my = t <= mbInter ? _mvy : 0;
    final m = addr * 32;
    for (var i = 0; i < 32; i += 2) {
      mvs[m + i] = mx;
      mvs[m + i + 1] = my;
    }
  }

  int _nCLuma(int addr, int mbx, int mby, int bx, int by) {
    int na = 0, nb = 0;
    var availA = true, availB = true;
    if (bx > 0) {
      na = nzY[addr * 16 + by * 4 + bx - 1];
    } else if (mbx > 0) {
      na = nzY[(addr - 1) * 16 + by * 4 + 3];
    } else {
      availA = false;
    }
    if (by > 0) {
      nb = nzY[addr * 16 + (by - 1) * 4 + bx];
    } else if (mby > 0) {
      nb = nzY[(addr - mbW) * 16 + 12 + bx];
    } else {
      availB = false;
    }
    if (availA && availB) return (na + nb + 1) >> 1;
    if (availA) return na;
    if (availB) return nb;
    return 0;
  }

  int _nCChroma(int addr, int mbx, int mby, int comp, int bx, int by) {
    int na = 0, nb = 0;
    var availA = true, availB = true;
    final c = comp * 4;
    if (bx > 0) {
      na = nzC[addr * 8 + c + by * 2];
    } else if (mbx > 0) {
      na = nzC[(addr - 1) * 8 + c + by * 2 + 1];
    } else {
      availA = false;
    }
    if (by > 0) {
      nb = nzC[addr * 8 + c + bx];
    } else if (mby > 0) {
      nb = nzC[(addr - mbW) * 8 + c + 2 + bx];
    } else {
      availB = false;
    }
    if (availA && availB) return (na + nb + 1) >> 1;
    if (availA) return na;
    if (availB) return nb;
    return 0;
  }

  void _writeMb(bool pSlice) {
    final b = _bw;
    final addr = _curAddr;
    final mbx = addr % mbW, mby = addr ~/ mbW;
    if (pSlice) {
      b.ue(_skipRun);
      _skipRun = 0;
    }
    final t = _curType;
    final cbp = _cbpL | (_cbpC << 4);
    final intraBase = pSlice ? 5 : 0;
    if (t == mbInter) {
      b.ue(0); // P_L0_16x16
      b.se(_mvx - _mvpx);
      b.se(_mvy - _mvpy);
      b.ue(cbpToCodeInter[cbp]);
    } else if (t == mbI4x4) {
      b.ue(intraBase);
      for (var bi = 0; bi < 16; bi++) {
        final r = blkToRaster[bi];
        final m = _curI4[r], pm = _curI4Pred[r];
        if (m == pm) {
          b.bits(1, 1);
        } else {
          b.bits(4, m < pm ? m : m - 1);
        }
      }
      b.ue(_curCMode);
      b.ue(cbpToCodeIntra[cbp]);
    } else {
      b.ue(intraBase +
          1 +
          _curI16Mode +
          4 * _cbpC +
          (_cbpL != 0 ? 12 : 0));
      b.ue(_curCMode);
    }
    if (t == mbI16x16 || cbp != 0) {
      b.se(_qpDelta);
      // Residual.
      if (t == mbI16x16) {
        _cavlc.write(b, _levDc, 0, 16, _nCLuma(addr, mbx, mby, 0, 0));
      }
      for (var i8 = 0; i8 < 4; i8++) {
        if ((_cbpL & (1 << i8)) == 0) continue;
        for (var i4 = 0; i4 < 4; i4++) {
          final r = blkToRaster[i8 * 4 + i4];
          final nC = _nCLuma(addr, mbx, mby, r & 3, r >> 2);
          if (t == mbI16x16) {
            _cavlc.write(b, _levY, r * 16 + 1, 15, nC);
          } else {
            _cavlc.write(b, _levY, r * 16, 16, nC);
          }
        }
      }
      if (_cbpC != 0) {
        _cavlc.write(b, _levCdc, 0, 4, -1);
        _cavlc.write(b, _levCdc, 4, 4, -1);
      }
      if (_cbpC == 2) {
        for (var comp = 0; comp < 2; comp++) {
          for (var bk = 0; bk < 4; bk++) {
            final nC = _nCChroma(addr, mbx, mby, comp, bk & 1, bk >> 1);
            _cavlc.write(b, _levCac, comp * 64 + bk * 16 + 1, 15, nC);
          }
        }
      }
    }
  }

  int _curAddr = 0;
}
