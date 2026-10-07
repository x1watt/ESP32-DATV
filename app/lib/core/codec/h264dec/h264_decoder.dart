import 'dart:typed_data';

import '../frame.dart';
import 'bitreader.dart';
import 'deblock.dart';
import 'mb_decoder.dart';
import 'params.dart';
import 'picture.dart';
import 'slice_header.dart';

/// Pure Dart H.264 (AVC) decoder for progressive 8-bit 4:2:0 streams
/// (Constrained Baseline, Baseline without slice groups, Main and High).
///
/// Supported: CAVLC and CABAC, I/P/B slices, multiple slices per picture,
/// all macroblock and sub-macroblock types, spatial and temporal direct
/// prediction, explicit and implicit weighted prediction, 8x8 transform and
/// intra 8x8, scaling matrices, I_PCM, deblocking, POC types 0/1/2,
/// long-term references, MMCO, reference list modification, frame_num gaps
/// and DPB bumping. Output frames are cropped and returned in display order
/// with the presentation time of the access unit they came from.
///
/// Not supported (reported as [UnsupportedError]): interlaced coding (field
/// pictures, MBAFF), 4:0:0/4:2:2/4:4:4, bit depths above 8, lossless
/// transform bypass, slice groups (FMO), SP/SI slices and data partitioning.
///
/// Corrupt data never throws: broken slices are counted in [errorCount] and
/// missing macroblocks are concealed from the previous picture.
class H264Decoder {
  H264Decoder();

  final Map<int, Sps> _spsMap = {};
  final Map<int, Pps> _ppsMap = {};
  final SliceDecoder _sd = SliceDecoder();
  final Deblocker _deblocker = Deblocker();

  Sps? _activeSps;
  MbInfo? _info;
  int _mbW = 0, _mbH = 0;

  final List<Picture> _dpb = [];
  final List<Picture> _pool = [];
  final List<I420Frame> _out = [];

  Picture? _cur;
  SliceHeader? _curHdr;
  int _curDecodedMbs = 0;
  final List<DeblockSliceParams> _sliceParams = [];
  int _uid = 0;

  // POC / frame_num state.
  bool _havePrev = false;
  int _prevPocMsb = 0;
  int _prevPocLsb = 0;
  int _prevFrameNumOffset = 0;
  int _prevFrameNum = 0;
  int _prevRefFrameNum = 0;
  int _curPocMsb = 0;
  int _curFrameNumOffset = 0;
  int _maxLongTermFrameIdx = -1;

  /// Number of slices that failed to decode (concealed).
  int errorCount = 0;

  /// Feeds Annex B data (one access unit or any chunk of complete NAL units).
  List<I420Frame> decode(Uint8List annexB, {int ptsUs = 0}) {
    return decodeNals(splitAnnexB(annexB), ptsUs: ptsUs);
  }

  /// Feeds raw NAL units (without start codes).
  List<I420Frame> decodeNals(List<Uint8List> nals, {int ptsUs = 0}) {
    for (final nal in nals) {
      if (nal.isEmpty) continue;
      final hdr = nal[0];
      if ((hdr & 0x80) != 0) continue; // forbidden_zero_bit
      final type = hdr & 31;
      final refIdc = (hdr >> 5) & 3;
      try {
        switch (type) {
          case 1:
          case 5:
            _handleSlice(nal, type, refIdc, ptsUs);
            break;
          case 2:
          case 3:
          case 4:
            throw UnsupportedError('H.264 data partitioning (Extended profile) is not supported');
          case 7:
            try {
              final sps = Sps.parse(BitReader(nalToRbsp(nal, 1)));
              _spsMap[sps.id] = sps;
            } on H264Exception {
              errorCount++;
            }
            break;
          case 8:
            try {
              final pps = Pps.parse(BitReader(nalToRbsp(nal, 1)), _spsMap);
              _ppsMap[pps.id] = pps;
            } on H264Exception {
              errorCount++;
            }
            break;
          case 9:
          case 10:
          case 11:
            _finishPicture();
            break;
          default:
            break; // SEI, filler, extensions: ignored
        }
      } on UnsupportedError {
        rethrow;
      } catch (_) {
        // Malformed data must never escape: count it and resynchronise.
        errorCount++;
        _recoverFromError();
      }
    }
    final res = List<I420Frame>.of(_out);
    _out.clear();
    return res;
  }

  void _recoverFromError() {
    // Drop the picture in progress if its state may be inconsistent.
    final cur = _cur;
    if (cur != null) {
      try {
        _finishPicture();
      } catch (_) {
        _cur = null;
        _curHdr = null;
      }
    }
  }

  /// Finishes the pending picture and outputs all remaining frames.
  List<I420Frame> flush() {
    try {
      _finishPicture();
    } on UnsupportedError {
      rethrow;
    } catch (_) {
      errorCount++;
      _cur = null;
      _curHdr = null;
    }
    while (_bump()) {}
    _dpb.clear();
    final res = List<I420Frame>.of(_out);
    _out.clear();
    return res;
  }

  /// Splits Annex B byte stream data into NAL units (views, no copies).
  static List<Uint8List> splitAnnexB(Uint8List d) {
    final res = <Uint8List>[];
    final n = d.length;
    var i = 0;
    var start = -1;
    while (i + 2 < n) {
      if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1) {
        if (start >= 0) {
          var end = i;
          while (end > start && d[end - 1] == 0) {
            end--;
          }
          if (end > start) res.add(Uint8List.sublistView(d, start, end));
        }
        i += 3;
        start = i;
      } else if (d[i + 2] > 1) {
        i += 3;
      } else {
        i++;
      }
    }
    if (start >= 0 && start < n) {
      var end = n;
      while (end > start && d[end - 1] == 0) {
        end--;
      }
      if (end > start) res.add(Uint8List.sublistView(d, start, end));
    }
    return res;
  }

  // ================================================================ slices

  void _handleSlice(Uint8List nal, int type, int refIdc, int ptsUs) {
    final r = BitReader(nalToRbsp(nal, 1));
    SliceHeader h;
    try {
      h = SliceHeader.parse(r, type, refIdc, _ppsMap, _spsMap);
    } on H264Exception {
      errorCount++;
      return;
    }
    if (h.redundantPicCnt > 0) return;
    final sps = h.sps;
    _checkSupported(sps, h);
    if (_cur != null) {
      final prev = _curHdr!;
      if (_isNewPicture(prev, h) ||
          (h.firstMb == 0 && _curDecodedMbs > 0) ||
          !identical(prev.sps, sps)) {
        _finishPicture();
      }
    }
    if (_cur == null) {
      if (!h.isIdr && !_havePrev) {
        // Cannot start decoding without an IDR or recovery point; accept I
        // slices only.
        if (h.sliceType != sliceI) return;
      }
      _startPicture(h, ptsUs);
    }
    final idx = _sliceParams.length;
    _sliceParams.add(
      DeblockSliceParams(
        h.disableDeblockingFilterIdc,
        h.sliceAlphaC0Offset,
        h.sliceBetaOffset,
        h.pps.chromaQpIndexOffset,
        h.pps.secondChromaQpIndexOffset,
      ),
    );
    if (h.sliceType != sliceI) _buildRefLists(h);
    try {
      _sd.decodeSlice(h, r, idx);
      _curDecodedMbs += _sd.decodedMbs;
    } on UnsupportedError {
      rethrow;
    } catch (e, st) {
      errorCount++;
      debugLog?.call('slice error at mb ${_sd.currentMb}: $e\n$st');
      _curDecodedMbs += _sd.decodedMbs;
      // The macroblock that failed is incomplete: mark it missing.
      _info!.sliceTable[_sd.currentMb] = -1;
    }
    if (_curDecodedMbs >= _mbW * _mbH) _finishPicture();
  }

  void _checkSupported(Sps sps, SliceHeader h) {
    if (sps.chromaFormatIdc != 1) {
      throw UnsupportedError(
        'H.264 chroma_format_idc ${sps.chromaFormatIdc} is not supported (only 4:2:0)',
      );
    }
    if (sps.bitDepthLuma != 8 || sps.bitDepthChroma != 8) {
      throw UnsupportedError('H.264 bit depth ${sps.bitDepthLuma} is not supported (only 8-bit)');
    }
    if (sps.transformBypass) {
      throw UnsupportedError('H.264 lossless transform bypass is not supported');
    }
    if (h.fieldPic) {
      throw UnsupportedError('Interlaced H.264 (field pictures) is not supported');
    }
    if (sps.mbAdaptiveFrameField) {
      throw UnsupportedError('Interlaced H.264 (MBAFF) is not supported');
    }
  }

  bool _isNewPicture(SliceHeader a, SliceHeader b) {
    if (a.frameNum != b.frameNum) return true;
    if (a.ppsId != b.ppsId) return true;
    if (a.fieldPic != b.fieldPic || a.bottomField != b.bottomField) return true;
    if ((a.nalRefIdc == 0) != (b.nalRefIdc == 0)) return true;
    if (a.isIdr != b.isIdr) return true;
    if (a.isIdr && b.isIdr && a.idrPicId != b.idrPicId) return true;
    final sps = b.sps;
    if (sps.pocType == 0) {
      if (a.pocLsb != b.pocLsb || a.deltaPocBottom != b.deltaPocBottom) return true;
    } else if (sps.pocType == 1) {
      if (a.deltaPoc0 != b.deltaPoc0 || a.deltaPoc1 != b.deltaPoc1) return true;
    }
    return false;
  }

  void _activate(Sps sps) {
    if (identical(_activeSps, sps)) return;
    final mbW = sps.picWidthInMbs, mbH = sps.frameHeightInMbs;
    if (mbW != _mbW || mbH != _mbH) {
      // Resolution change: output everything and drop old buffers.
      while (_bump()) {}
      _dpb.clear();
      _pool.clear();
      _mbW = mbW;
      _mbH = mbH;
      _info = MbInfo(mbW * mbH);
      _sd.allocate(mbW, mbH);
    }
    _activeSps = sps;
  }

  Picture _allocPicture() {
    if (_pool.isNotEmpty) {
      final p = _pool.removeLast();
      p.shortRef = false;
      p.longRef = false;
      p.neededForOutput = false;
      p.nonExisting = false;
      return p;
    }
    return Picture(_mbW, _mbH);
  }

  void _recycle(Picture p) {
    if (p.mbWidth == _mbW && p.mbHeight == _mbH && _pool.length < 4) _pool.add(p);
  }

  void _startPicture(SliceHeader h, int ptsUs) {
    final sps = h.sps;
    _activate(sps);
    if (h.isIdr) {
      _prevRefFrameNum = 0;
    } else if (_havePrev &&
        h.frameNum != _prevRefFrameNum &&
        h.frameNum != (_prevRefFrameNum + 1) % sps.maxFrameNum) {
      _fillFrameNumGap(h);
    }
    final pic = _allocPicture();
    pic.uid = ++_uid;
    pic.frameNum = h.frameNum;
    pic.ptsUs = ptsUs;
    pic.poc = _computePoc(h);
    _cur = pic;
    _curHdr = h;
    _curDecodedMbs = 0;
    _sliceParams.clear();
    _sd.startPicture(pic, _info!);
    _sd.curPoc = pic.poc;
  }

  int _computePoc(SliceHeader h) {
    final sps = h.sps;
    if (sps.pocType == 0) {
      var prevMsb = _prevPocMsb, prevLsb = _prevPocLsb;
      if (h.isIdr) {
        prevMsb = 0;
        prevLsb = 0;
      }
      final maxLsb = 1 << sps.log2MaxPocLsb;
      final lsb = h.pocLsb;
      int msb;
      if (lsb < prevLsb && prevLsb - lsb >= maxLsb ~/ 2) {
        msb = prevMsb + maxLsb;
      } else if (lsb > prevLsb && lsb - prevLsb > maxLsb ~/ 2) {
        msb = prevMsb - maxLsb;
      } else {
        msb = prevMsb;
      }
      _curPocMsb = msb;
      final top = msb + lsb;
      final bottom = top + h.deltaPocBottom;
      return top < bottom ? top : bottom;
    }
    // Types 1 and 2 need FrameNumOffset.
    int frameNumOffset;
    if (h.isIdr) {
      frameNumOffset = 0;
    } else if (_prevFrameNum > h.frameNum) {
      frameNumOffset = _prevFrameNumOffset + sps.maxFrameNum;
    } else {
      frameNumOffset = _prevFrameNumOffset;
    }
    _curFrameNumOffset = frameNumOffset;
    if (sps.pocType == 2) {
      if (h.isIdr) return 0;
      final t = 2 * (frameNumOffset + h.frameNum);
      return h.nalRefIdc == 0 ? t - 1 : t;
    }
    final n = sps.offsetForRefFrame.length;
    var absFrameNum = n != 0 ? frameNumOffset + h.frameNum : 0;
    if (h.nalRefIdc == 0 && absFrameNum > 0) absFrameNum--;
    var expected = 0;
    if (absFrameNum > 0) {
      var delta = 0;
      for (final o in sps.offsetForRefFrame) {
        delta += o;
      }
      final cycleCnt = (absFrameNum - 1) ~/ n;
      final inCycle = (absFrameNum - 1) % n;
      expected = cycleCnt * delta;
      for (var i = 0; i <= inCycle; i++) {
        expected += sps.offsetForRefFrame[i];
      }
    }
    if (h.nalRefIdc == 0) expected += sps.offsetForNonRefPic;
    final top = expected + h.deltaPoc0;
    final bottom = top + sps.offsetForTopToBottomField + h.deltaPoc1;
    return top < bottom ? top : bottom;
  }

  void _fillFrameNumGap(SliceHeader h) {
    final sps = h.sps;
    final max = sps.maxFrameNum;
    var unused = (_prevRefFrameNum + 1) % max;
    var count = (h.frameNum - unused + max) % max;
    final keep = sps.maxNumRefFrames < 1 ? 1 : sps.maxNumRefFrames;
    if (count > keep) {
      unused = (h.frameNum - keep + max) % max;
      count = keep;
    }
    Picture? src;
    for (final p in _dpb) {
      if (p.isRef && (src == null || p.uid > src.uid)) src = p;
    }
    for (var i = 0; i < count; i++) {
      final p = _allocPicture();
      p.uid = ++_uid;
      p.frameNum = unused;
      p.nonExisting = true;
      p.poc = src?.poc ?? 0;
      p.ptsUs = 0;
      if (src != null) {
        p.y.setAll(0, src.y);
        p.u.setAll(0, src.u);
        p.v.setAll(0, src.v);
      }
      p.mbIntra.fillRange(0, p.mbIntra.length, 1);
      _slidingWindow(sps, unused);
      p.shortRef = true;
      // Make room by outputting (never by dropping) waiting pictures.
      while (_dpb.length >= sps.dpbFrames) {
        if (!_bump()) break;
      }
      _dpb.add(p);
      _prevRefFrameNum = unused;
      if (_prevFrameNum > unused) _prevFrameNumOffset += max;
      _prevFrameNum = unused;
      if (sps.pocType == 2) p.poc = 2 * (_prevFrameNumOffset + unused);
      unused = (unused + 1) % max;
    }
  }

  // ======================================================= reference lists

  int _frameNumWrap(Picture p, int curFrameNum, int maxFrameNum) =>
      p.frameNum > curFrameNum ? p.frameNum - maxFrameNum : p.frameNum;

  void _buildRefLists(SliceHeader h) {
    final sps = h.sps;
    final maxFrameNum = sps.maxFrameNum;
    final cur = _cur!;
    final shortRefs = <Picture>[];
    final longRefs = <Picture>[];
    for (final p in _dpb) {
      if (identical(p, cur)) continue;
      if (p.shortRef) {
        p.frameNumWrap = _frameNumWrap(p, h.frameNum, maxFrameNum);
        shortRefs.add(p);
      } else if (p.longRef) {
        longRefs.add(p);
      }
    }
    longRefs.sort((a, b) => a.longTermFrameIdx.compareTo(b.longTermFrameIdx));
    List<Picture?> l0, l1 = const [];
    if (h.sliceType == sliceP) {
      shortRefs.sort((a, b) => b.frameNumWrap.compareTo(a.frameNumWrap));
      l0 = [...shortRefs, ...longRefs];
    } else {
      final before = shortRefs.where((p) => p.poc < cur.poc).toList()
        ..sort((a, b) => b.poc.compareTo(a.poc));
      final after = shortRefs.where((p) => p.poc >= cur.poc).toList()
        ..sort((a, b) => a.poc.compareTo(b.poc));
      l0 = [...before, ...after, ...longRefs];
      l1 = [...after, ...before, ...longRefs];
      if (l1.length > 1) {
        var same = l0.length == l1.length;
        for (var i = 0; same && i < l0.length; i++) {
          if (!identical(l0[i], l1[i])) same = false;
        }
        if (same) {
          final t = l1[0];
          l1[0] = l1[1];
          l1[1] = t;
        }
      }
    }
    final lists = <List<Picture?>>[l0, l1];
    final out = <List<Picture>>[[], []];
    for (var list = 0; list < (h.sliceType == sliceB ? 2 : 1); list++) {
      final n = list == 0 ? h.numRefIdxL0 : h.numRefIdxL1;
      final l = List<Picture?>.filled(n + 1, null);
      final init = lists[list];
      for (var i = 0; i < n && i < init.length; i++) {
        l[i] = init[i];
      }
      _modifyList(h, l, n, h.modifications[list], shortRefs, longRefs);
      // Conceal missing entries.
      Picture? fallback;
      for (var i = 0; i < n; i++) {
        if (l[i] != null) {
          fallback = l[i];
          break;
        }
      }
      fallback ??= shortRefs.isNotEmpty
          ? shortRefs.first
          : (longRefs.isNotEmpty ? longRefs.first : null);
      fallback ??= _dpb.isNotEmpty ? _dpb.last : null;
      // Nothing to predict from: use the current picture.
      fallback ??= cur;
      final res = <Picture>[];
      final longFlags = list == 0 ? _sd.refLong0 : _sd.refLong1;
      for (var i = 0; i < n; i++) {
        final p = l[i] ?? fallback;
        res.add(p);
        longFlags[i] = p.longRef ? 1 : 0;
      }
      out[list] = res;
    }
    _sd.refList0 = out[0];
    _sd.refList1 = out[1];
    final dl = debugLog;
    if (dl != null) {
      String desc(List<Picture> l) =>
          l.map((p) => p.longRef ? 'L${p.longTermFrameIdx}' : '${p.frameNum}/${p.poc}').join(' ');
      dl(
        'slice fn ${h.frameNum} poc ${cur.poc} type ${h.sliceType} mods ${h.modifications} '
        'mmco ${h.mmcos.map((m) => '${m.op}:${m.diffPicNums}/${m.longTermPicNum}/${m.longTermFrameIdx}/${m.maxLongTermFrameIdxPlus1}').toList()} '
        'L0 [${desc(out[0])}] L1 [${desc(out[1])}]',
      );
    }
  }

  /// Debug hook receiving one line per decoded slice (reference lists).
  static void Function(String)? debugLog;

  void _modifyList(
    SliceHeader h,
    List<Picture?> l,
    int n,
    List<int> mods,
    List<Picture> shortRefs,
    List<Picture> longRefs,
  ) {
    if (mods.isEmpty) return;
    final maxPicNum = h.sps.maxFrameNum;
    final currPicNum = h.frameNum;
    var pred = currPicNum;
    var refIdx = 0;
    for (var m = 0; m + 1 < mods.length; m += 2) {
      final idc = mods[m], val = mods[m + 1];
      if (refIdx > n) break;
      Picture? pic;
      bool isLong;
      int num;
      if (idc == 0 || idc == 1) {
        final absDiff = val + 1;
        int noWrap;
        if (idc == 0) {
          noWrap = pred - absDiff;
          if (noWrap < 0) noWrap += maxPicNum;
        } else {
          noWrap = pred + absDiff;
          if (noWrap >= maxPicNum) noWrap -= maxPicNum;
        }
        pred = noWrap;
        num = noWrap > currPicNum ? noWrap - maxPicNum : noWrap;
        for (final p in shortRefs) {
          if (p.frameNumWrap == num) {
            pic = p;
            break;
          }
        }
        isLong = false;
      } else if (idc == 2) {
        num = val;
        for (final p in longRefs) {
          if (p.longTermFrameIdx == num) {
            pic = p;
            break;
          }
        }
        isLong = true;
      } else {
        continue;
      }
      for (var c = n; c > refIdx; c--) {
        l[c] = l[c - 1];
      }
      l[refIdx++] = pic;
      var nIdx = refIdx;
      for (var c = refIdx; c <= n; c++) {
        final q = l[c];
        final match =
            q != null &&
            (isLong
                ? (q.longRef && q.longTermFrameIdx == num)
                : (q.shortRef && q.frameNumWrap == num));
        if (!match) l[nIdx++] = q;
      }
    }
  }

  // ============================================================ finishing

  void _finishPicture() {
    final cur = _cur;
    if (cur == null) return;
    final h = _curHdr!;
    final info = _info!;
    _conceal(cur, info);
    _deblocker.filterPicture(cur, info, _sliceParams);
    final sps = h.sps;
    final isRef = h.nalRefIdc != 0;
    var mmco5 = false;
    if (isRef) {
      mmco5 = _markReferences(h, cur);
    }
    // POC / frame_num bookkeeping for the next picture.
    if (mmco5) {
      final tempPoc = cur.poc;
      // After MMCO 5 the picture is treated as frame_num 0 with its POC
      // reduced by tempPicOrderCnt.
      cur.poc = 0;
      cur.frameNum = 0;
      _prevPocMsb = 0;
      _prevPocLsb = sps.pocType == 0 ? (_curPocMsb + h.pocLsb) - tempPoc : 0;
      _prevFrameNumOffset = 0;
      _prevFrameNum = 0;
      _prevRefFrameNum = 0;
    } else {
      if (isRef) {
        _prevPocMsb = _curPocMsb;
        _prevPocLsb = h.pocLsb;
        _prevRefFrameNum = h.frameNum;
      }
      _prevFrameNumOffset = _curFrameNumOffset;
      _prevFrameNum = h.frameNum;
    }
    _havePrev = true;
    _storePicture(cur, sps, h.isIdr || mmco5);
    _cur = null;
    _curHdr = null;
  }

  void _conceal(Picture cur, MbInfo info) {
    final n = _mbW * _mbH;
    Picture? src;
    for (final p in _dpb) {
      if (!identical(p, cur) && (src == null || p.uid > src.uid)) src = p;
    }
    var concealSlice = -1;
    for (var mb = 0; mb < n; mb++) {
      if (info.sliceTable[mb] >= 0) continue;
      if (concealSlice < 0) {
        concealSlice = _sliceParams.length;
        _sliceParams.add(DeblockSliceParams(1, 0, 0, 0, 0));
      }
      info.sliceTable[mb] = concealSlice;
      info.intra[mb] = 1;
      info.qp[mb] = 0;
      info.t8[mb] = 0;
      info.nzMask[mb] = 0;
      cur.mbIntra[mb] = 1;
      for (var i = 0; i < 16; i++) {
        cur.ref0[mb * 16 + i] = -1;
        cur.ref1[mb * 16 + i] = -1;
      }
      final mx = mb % _mbW, my = mb ~/ _mbW;
      final w = cur.width, cw = w >> 1;
      for (var y = 0; y < 16; y++) {
        final o = (my * 16 + y) * w + mx * 16;
        for (var x = 0; x < 16; x++) {
          cur.y[o + x] = src != null ? src.y[o + x] : 128;
        }
      }
      for (var y = 0; y < 8; y++) {
        final o = (my * 8 + y) * cw + mx * 8;
        for (var x = 0; x < 8; x++) {
          cur.u[o + x] = src != null ? src.u[o + x] : 128;
          cur.v[o + x] = src != null ? src.v[o + x] : 128;
        }
      }
    }
  }

  int _numRefs() {
    var n = 0;
    for (final p in _dpb) {
      if (p.isRef) n++;
    }
    return n;
  }

  void _slidingWindow(Sps sps, int curFrameNum) {
    final maxRefs = sps.maxNumRefFrames < 1 ? 1 : sps.maxNumRefFrames;
    while (_numRefs() >= maxRefs) {
      Picture? oldest;
      var oldestWrap = 0;
      for (final p in _dpb) {
        if (!p.shortRef) continue;
        final w = _frameNumWrap(p, curFrameNum, sps.maxFrameNum);
        if (oldest == null || w < oldestWrap) {
          oldest = p;
          oldestWrap = w;
        }
      }
      if (oldest == null) break;
      oldest.shortRef = false;
    }
    _removeUnused();
  }

  /// Applies reference marking (8.2.5). Returns true if MMCO 5 was used.
  bool _markReferences(SliceHeader h, Picture cur) {
    final sps = h.sps;
    if (h.isIdr) {
      for (final p in _dpb) {
        p.shortRef = false;
        p.longRef = false;
      }
      if (h.longTermReference) {
        cur.longRef = true;
        cur.longTermFrameIdx = 0;
        _maxLongTermFrameIdx = 0;
      } else {
        cur.shortRef = true;
        _maxLongTermFrameIdx = -1;
      }
      return false;
    }
    var mmco5 = false;
    if (h.adaptiveRefPicMarking) {
      final maxFrameNum = sps.maxFrameNum;
      for (final m in h.mmcos) {
        switch (m.op) {
          case 1:
            final picNum = h.frameNum - m.diffPicNums;
            for (final p in _dpb) {
              if (p.shortRef && _frameNumWrap(p, h.frameNum, maxFrameNum) == picNum) {
                p.shortRef = false;
              }
            }
            break;
          case 2:
            for (final p in _dpb) {
              if (p.longRef && p.longTermFrameIdx == m.longTermPicNum) p.longRef = false;
            }
            break;
          case 3:
            final picNum = h.frameNum - m.diffPicNums;
            for (final p in _dpb) {
              if (p.longRef && p.longTermFrameIdx == m.longTermFrameIdx) p.longRef = false;
            }
            for (final p in _dpb) {
              if (p.shortRef && _frameNumWrap(p, h.frameNum, maxFrameNum) == picNum) {
                p.shortRef = false;
                p.longRef = true;
                p.longTermFrameIdx = m.longTermFrameIdx;
              }
            }
            break;
          case 4:
            _maxLongTermFrameIdx = m.maxLongTermFrameIdxPlus1 - 1;
            for (final p in _dpb) {
              if (p.longRef && p.longTermFrameIdx > _maxLongTermFrameIdx) p.longRef = false;
            }
            break;
          case 5:
            for (final p in _dpb) {
              p.shortRef = false;
              p.longRef = false;
            }
            _maxLongTermFrameIdx = -1;
            mmco5 = true;
            break;
          case 6:
            for (final p in _dpb) {
              if (p.longRef && p.longTermFrameIdx == m.longTermFrameIdx) p.longRef = false;
            }
            cur.longRef = true;
            cur.longTermFrameIdx = m.longTermFrameIdx;
            break;
        }
      }
    } else {
      _slidingWindow(sps, h.frameNum);
    }
    if (!cur.longRef) {
      cur.shortRef = true;
      // Robustness: never exceed max_num_ref_frames.
      final maxRefs = sps.maxNumRefFrames < 1 ? 1 : sps.maxNumRefFrames;
      while (_numRefs() + 1 > maxRefs) {
        Picture? oldest;
        var oldestWrap = 0;
        for (final p in _dpb) {
          if (!p.shortRef) continue;
          final w = _frameNumWrap(p, h.frameNum, sps.maxFrameNum);
          if (oldest == null || w < oldestWrap) {
            oldest = p;
            oldestWrap = w;
          }
        }
        if (oldest == null) break;
        oldest.shortRef = false;
      }
    }
    _removeUnused();
    return mmco5;
  }

  void _removeUnused() {
    for (var i = _dpb.length - 1; i >= 0; i--) {
      final p = _dpb[i];
      if (!p.isRef && !p.neededForOutput) {
        _dpb.removeAt(i);
        _recycle(p);
      }
    }
  }

  // ============================================================== output

  void _storePicture(Picture cur, Sps sps, bool flushPrior) {
    if (flushPrior) {
      // IDR or MMCO 5: all earlier pictures precede this one in output order.
      for (;;) {
        Picture? best;
        for (final p in _dpb) {
          if (identical(p, cur) || !p.neededForOutput) continue;
          if (best == null || p.poc < best.poc) best = p;
        }
        if (best == null) break;
        _output(best);
      }
      _removeUnused();
    }
    cur.neededForOutput = true;
    final dpbSize = sps.dpbFrames;
    if (!cur.isRef) {
      while (_dpb.length >= dpbSize) {
        var minPoc = 0;
        var any = false;
        for (final p in _dpb) {
          if (p.neededForOutput && (!any || p.poc < minPoc)) {
            minPoc = p.poc;
            any = true;
          }
        }
        if (!any || cur.poc < minPoc) {
          _output(cur);
          _recycle(cur);
          return;
        }
        if (!_bump()) break;
      }
    } else {
      while (_dpb.length >= dpbSize) {
        if (!_bump()) break;
      }
    }
    _dpb.add(cur);
    final reorder = sps.bitstreamRestriction ? sps.maxNumReorderFrames : dpbSize;
    for (;;) {
      var waiting = 0;
      for (final p in _dpb) {
        if (p.neededForOutput) waiting++;
      }
      if (waiting <= reorder) break;
      if (!_bump()) break;
    }
  }

  /// Outputs the waiting picture with the smallest POC. Returns false if
  /// none is waiting.
  bool _bump() {
    Picture? best;
    for (final p in _dpb) {
      if (!p.neededForOutput) continue;
      if (best == null || p.poc < best.poc) best = p;
    }
    if (best == null) return false;
    _output(best);
    if (!best.isRef) {
      _dpb.remove(best);
      _recycle(best);
    }
    return true;
  }

  void _output(Picture p) {
    p.neededForOutput = false;
    if (p.nonExisting) return;
    final sps = _activeSps!;
    final cw = sps.croppedWidth & ~1, chh = sps.croppedHeight & ~1;
    final cx = sps.cropX, cy = sps.cropY;
    final f = I420Frame.alloc(cw, chh, ptsUs: p.ptsUs);
    final w = p.width;
    for (var y = 0; y < chh; y++) {
      final so = (cy + y) * w + cx;
      f.y.setRange(y * cw, y * cw + cw, p.y, so);
    }
    final hw = cw >> 1, hh = chh >> 1, pw = w >> 1;
    for (var y = 0; y < hh; y++) {
      final so = ((cy >> 1) + y) * pw + (cx >> 1);
      f.u.setRange(y * hw, y * hw + hw, p.u, so);
      f.v.setRange(y * hw, y * hw + hw, p.v, so);
    }
    _out.add(f);
  }
}
