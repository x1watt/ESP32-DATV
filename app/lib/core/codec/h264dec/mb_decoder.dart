import 'dart:typed_data';

import 'bitreader.dart';
import 'cabac.dart';
import 'cavlc.dart';
import 'deblock.dart';
import 'int_util.dart';
import 'inter_pred.dart';
import 'params.dart';
import 'picture.dart';
import 'recon.dart';
import 'slice_header.dart';
import 'tables.dart';
import 'tables_gen.dart';

// Macroblock flag bits stored per macroblock of the current picture.
const int _fIntra = 1;
const int _fI16 = 2;
const int _fPcm = 4;
const int _fSkip = 8;
const int _fNxN = 16;
const int _fT8 = 32;
const int _fDirect16 = 64;

/// Cache index of 4x4 position (x, y), x in -1..4, y in -1..3.
int _c(int x, int y) => (y + 1) * 8 + x + 1;

// Partition prediction flags: bit0 = list 0, bit1 = list 1.
const List<int> _bPart0 = [0, 1, 2, 3, 1, 1, 2, 2, 1, 1, 2, 2, 1, 1, 2, 2, 3, 3, 3, 3, 3, 3];
const List<int> _bPart1 = [0, 1, 2, 3, 1, 1, 2, 2, 2, 2, 1, 1, 3, 3, 3, 3, 1, 1, 2, 2, 3, 3];

// B sub_mb_type: prediction flags, sub partition count, width, height (4x4 units).
const List<int> _bSubPred = [0, 1, 2, 3, 1, 1, 2, 2, 3, 3, 1, 2, 3];
const List<int> _bSubShape = [0, 0, 0, 0, 1, 2, 1, 2, 1, 2, 3, 3, 3];

// Sub shape: 0 = 8x8, 1 = 8x4, 2 = 4x8, 3 = 4x4.
const List<int> _subCount = [1, 2, 2, 4];
const List<int> _subW = [2, 2, 1, 1];
const List<int> _subH = [2, 1, 2, 1];

const List<int> _cbfCatOffset = [0, 4, 8, 12, 16];
const List<int> _sigCatOffset = [0, 15, 29, 44, 47];
const List<int> _absCatOffset = [0, 10, 20, 30, 39];

/// Decodes the macroblock layer of slices into the current picture.
class SliceDecoder {
  final Cabac cabac = Cabac();
  final Cavlc cavlc = Cavlc();
  final Recon recon = Recon();
  final InterPred inter = InterPred();

  // ------------------------------------------------ picture-level state
  int mbW = 0, mbH = 0, mbCount = 0;
  late Picture cur;
  late MbInfo info;
  Uint8List _mbFlags = Uint8List(0);
  Uint8List _cbpTab = Uint8List(0);
  Uint8List _cbfDcTab = Uint8List(0);
  Uint8List _nzTab = Uint8List(0);
  Uint8List _chromaModeTab = Uint8List(0);
  Uint8List _mvdTab = Uint8List(0);
  Int8List _ipredTab = Int8List(0);
  Int32List _directTab = Int32List(0);

  void allocate(int w, int h) {
    mbW = w;
    mbH = h;
    mbCount = w * h;
    _mbFlags = Uint8List(mbCount);
    _cbpTab = Uint8List(mbCount);
    _cbfDcTab = Uint8List(mbCount);
    _nzTab = Uint8List(mbCount * 24);
    _chromaModeTab = Uint8List(mbCount);
    _mvdTab = Uint8List(2 * mbCount * 32);
    _ipredTab = Int8List(mbCount * 16);
    _directTab = Int32List(mbCount);
    _initCaches();
  }

  // ------------------------------------------------ slice-level state
  late SliceHeader sh;
  late Sps sps;
  late Pps pps;
  bool _cabac = false;
  int _sliceType = 0;
  int _sliceIdx = 0;
  int _numLists = 0;

  /// Reference lists (filled with concealment pictures where missing).
  List<Picture> refList0 = const [];
  List<Picture> refList1 = const [];
  final Uint8List refLong0 = Uint8List(33);
  final Uint8List refLong1 = Uint8List(33);
  final Int32List _refUid0 = Int32List(33);
  final Int32List _refUid1 = Int32List(33);
  int curPoc = 0;

  // Dequantisation tables: [list][qp*16 + pos] and [list][qp*64 + pos].
  final List<Int32List> _dq4 = List.generate(6, (_) => Int32List(52 * 16));
  final List<Int32List> _dq8 = List.generate(2, (_) => Int32List(52 * 64));
  ScalingMatrices? _dqFor;

  // Weighted prediction: 0 default, 1 explicit, 2 implicit.
  int _wMode = 0;
  final Int32List _implicitW1 = Int32List(32 * 32);
  final Int32List _dsf = Int32List(32);
  final Uint8List _dsfCopy = Uint8List(32);

  // ------------------------------------------------ macroblock state
  int _mb = 0, _mbX = 0, _mbY = 0;
  int _qp = 0;
  int _lastQpDelta = 0;
  bool _availA = false, _availB = false, _availC = false, _availD = false;
  int _mbA = 0, _mbB = 0, _mbC = 0, _mbD = 0;
  int _flags = 0;
  int _cbp = 0;
  bool _t8 = false;
  int _i16Mode = 0;
  int _chromaMode = 0;
  final Int8List _ipred = Int8List(16); // raster

  /// Dequantised coefficients: luma 4x4 blocks at raster*16 (or 8x8 at b8*64),
  /// Cb blocks at 256 + b*16, Cr at 320 + b*16.
  final Int32List _coef = Int32List(384);

  /// Per block flags: bit0 any coefficient, bit1 non-DC coefficient.
  /// 0..15 luma raster, 16..19 Cb, 20..23 Cr.
  final Uint8List _blkFlags = Uint8List(24);
  final Uint8List _b8Flags = Uint8List(4);
  final Int32List _dcTmp = Int32List(16);

  final List<Int32List> _refCache = [Int32List(40), Int32List(40)];
  final List<Int32List> _mvCache = [Int32List(80), Int32List(80)];
  final List<Int32List> _mvdCache = [Int32List(80), Int32List(80)];
  final Uint8List _directCache = Uint8List(40);

  int _mbPartShape = 0; // 0 16x16, 1 16x8, 2 8x16, 3 8x8
  final Int32List _partPred = Int32List(4);
  final Int32List _subType = Int32List(4);
  final Uint8List _subDirect = Uint8List(4);
  bool _p8x8Ref0 = false;

  // Residual output (CAVLC or CABAC).
  final Int32List _resIdx = Int32List(64);
  final Int32List _resLevel = Int32List(64);

  // Direct prediction scratch.
  int _dRef0 = -1, _dRef1 = -1;
  int _dMv0x = 0, _dMv0y = 0, _dMv1x = 0, _dMv1y = 0;
  int _colRef = -1, _colMvX = 0, _colMvY = 0, _colUid = -1;
  int _mvpX = 0, _mvpY = 0;

  BitReader _r = BitReader(Uint8List(8));

  /// Index of the macroblock being decoded (for error recovery).
  int get currentMb => _mb;

  /// Number of macroblocks fully decoded by the last [decodeSlice] call.
  int decodedMbs = 0;

  // ================================================================ setup

  void _prepareDequant(ScalingMatrices m) {
    if (identical(_dqFor, m)) return;
    _dqFor = m;
    for (var l = 0; l < 6; l++) {
      final w = m.m4[l];
      final t = _dq4[l];
      for (var qp = 0; qp < 52; qp++) {
        final m6 = qp % 6, sh = qp ~/ 6;
        final v = normAdjust4[m6];
        for (var pos = 0; pos < 16; pos++) {
          final i = pos >> 2, j = pos & 3;
          final n = ((i & 1) == 0 && (j & 1) == 0)
              ? v[0]
              : (((i & 1) == 1 && (j & 1) == 1) ? v[1] : v[2]);
          t[qp * 16 + pos] = (w[pos] * n) << sh;
        }
      }
    }
    for (var l = 0; l < 2; l++) {
      final w = m.m8[l];
      final t = _dq8[l];
      for (var qp = 0; qp < 52; qp++) {
        final m6 = qp % 6, sh = qp ~/ 6;
        final v = normAdjust8[m6];
        for (var pos = 0; pos < 64; pos++) {
          final i = pos >> 3, j = pos & 7;
          int n;
          if ((i & 3) == 0 && (j & 3) == 0) {
            n = v[0];
          } else if ((i & 1) == 1 && (j & 1) == 1) {
            n = v[1];
          } else if ((i & 3) == 2 && (j & 3) == 2) {
            n = v[2];
          } else if (((i & 3) == 0 && (j & 1) == 1) || ((i & 1) == 1 && (j & 3) == 0)) {
            n = v[3];
          } else if (((i & 3) == 0 && (j & 3) == 2) || ((i & 3) == 2 && (j & 3) == 0)) {
            n = v[4];
          } else {
            n = v[5];
          }
          t[qp * 64 + pos] = (w[pos] * n) << sh;
        }
      }
    }
  }

  static int _clip3(int lo, int hi, int v) => v < lo ? lo : (v > hi ? hi : v);

  void _prepareWeights() {
    _wMode = 0;
    if (_sliceType == sliceP && pps.weightedPred) _wMode = 1;
    if (_sliceType == sliceB) {
      if (pps.weightedBipredIdc == 1) _wMode = 1;
      if (pps.weightedBipredIdc == 2) _wMode = 2;
    }
    if (_sliceType == sliceB) {
      final n0 = sh.numRefIdxL0, n1 = sh.numRefIdxL1;
      for (var i = 0; i < n0; i++) {
        final poc0 = refList0[i].poc;
        final tb = _clip3(-128, 127, curPoc - poc0);
        if (_sliceType == sliceB) {
          // Temporal direct scale factors use RefPicList1[0].
          final td = _clip3(-128, 127, refList1[0].poc - poc0);
          if (td == 0 || refLong0[i] != 0) {
            _dsfCopy[i] = 1;
            _dsf[i] = 0;
          } else {
            _dsfCopy[i] = 0;
            final tx = (16384 + (td ~/ 2).abs()) ~/ td;
            _dsf[i] = _clip3(-1024, 1023, asr(tb * tx + 32, 6));
          }
        }
        if (_wMode == 2) {
          for (var j = 0; j < n1; j++) {
            final poc1 = refList1[j].poc;
            final td = _clip3(-128, 127, poc1 - poc0);
            var w1 = 32;
            if (td != 0 && refLong0[i] == 0 && refLong1[j] == 0) {
              final tx = (16384 + (td ~/ 2).abs()) ~/ td;
              final dsf = _clip3(-1024, 1023, asr(tb * tx + 32, 6));
              final d = asr(dsf, 2);
              if (d >= -64 && d <= 128) w1 = d;
            }
            _implicitW1[i * 32 + j] = w1;
          }
        }
      }
    }
  }

  /// Marks every macroblock of the picture as not yet decoded.
  void startPicture(Picture pic, MbInfo mbInfo) {
    cur = pic;
    info = mbInfo;
    info.sliceTable.fillRange(0, mbCount, -1);
  }

  // ================================================================ slice

  /// Decodes slice data. Throws [H264Exception] on corrupt data; macroblocks
  /// decoded before the error remain valid.
  void decodeSlice(SliceHeader h, BitReader r, int sliceIdx) {
    sh = h;
    sps = h.sps;
    pps = h.pps;
    _r = r;
    _cabac = pps.cabac;
    _sliceType = h.sliceType;
    _sliceIdx = sliceIdx;
    _numLists = _sliceType == sliceB ? 2 : (_sliceType == sliceP ? 1 : 0);
    decodedMbs = 0;
    for (var i = 0; i < 33; i++) {
      _refUid0[i] = i < refList0.length ? refList0[i].uid : -1;
      _refUid1[i] = i < refList1.length ? refList1[i].uid : -1;
    }
    _prepareDequant(pps.scalingFor(sps));
    if (_numLists > 0) _prepareWeights();
    _qp = pps.picInitQp + h.sliceQpDelta;
    if (_qp < 0 || _qp > 51) throw H264Exception('bad slice qp');
    _lastQpDelta = 0;
    var mbAddr = h.firstMb;
    if (mbAddr >= mbCount) throw H264Exception('first_mb_in_slice out of range');
    if (_cabac) {
      while (!r.byteAligned) {
        r.u1();
      }
      cabac.initEngine(r.data, r.pos >> 3);
      cabac.initContexts(_sliceType, h.cabacInitIdc, _qp);
      for (;;) {
        if (mbAddr >= mbCount) throw H264Exception('slice overruns picture');
        _beginMb(mbAddr);
        var skipped = false;
        if (_sliceType != sliceI) {
          skipped = _cabacSkipFlag();
        }
        if (skipped) {
          _decodeSkip();
        } else {
          _macroblockLayer();
        }
        decodedMbs++;
        if (cabac.terminate() != 0) break;
        if (cabac.overrun) throw H264Exception('CABAC overrun');
        mbAddr++;
      }
    } else {
      var more = true;
      while (more) {
        if (_sliceType != sliceI) {
          final run = r.ue();
          if (run > mbCount) throw H264Exception('bad mb_skip_run');
          for (var i = 0; i < run; i++) {
            if (mbAddr >= mbCount) throw H264Exception('skip run overruns picture');
            _beginMb(mbAddr);
            _decodeSkip();
            decodedMbs++;
            mbAddr++;
          }
          if (run > 0) {
            more = r.moreRbspData();
            if (!more) break;
          }
        }
        if (mbAddr >= mbCount) throw H264Exception('slice overruns picture');
        _beginMb(mbAddr);
        _macroblockLayer();
        decodedMbs++;
        if (r.pos > r.bitLength) throw H264Exception('CAVLC overrun');
        more = r.moreRbspData();
        mbAddr++;
      }
    }
  }

  void _beginMb(int mbAddr) {
    _mb = mbAddr;
    _mbX = mbAddr % mbW;
    _mbY = mbAddr ~/ mbW;
    final st = info.sliceTable;
    final s = _sliceIdx;
    _mbA = mbAddr - 1;
    _mbB = mbAddr - mbW;
    _mbC = mbAddr - mbW + 1;
    _mbD = mbAddr - mbW - 1;
    _availA = _mbX > 0 && st[_mbA] == s;
    _availB = _mbY > 0 && st[_mbB] == s;
    _availC = _mbY > 0 && _mbX < mbW - 1 && st[_mbC] == s;
    _availD = _mbY > 0 && _mbX > 0 && st[_mbD] == s;
    st[mbAddr] = s;
    _flags = 0;
    _cbp = 0;
    _t8 = false;
  }

  // ======================================================= CABAC elements

  bool _cabacSkipFlag() {
    var inc = 0;
    if (_availA && (_mbFlags[_mbA] & _fSkip) == 0) inc++;
    if (_availB && (_mbFlags[_mbB] & _fSkip) == 0) inc++;
    return cabac.decision((_sliceType == sliceB ? 24 : 11) + inc) != 0;
  }

  /// Decodes an intra mb_type (I slice numbering 0..25). [prefixCtx] is the
  /// ctxIdxOffset (3 for I slices, 17 for P suffix, 32 for B suffix).
  int _cabacIntraMbType(int off, bool islice) {
    if (islice) {
      var inc = 0;
      if (_availA && (_mbFlags[_mbA] & _fNxN) == 0) inc++;
      if (_availB && (_mbFlags[_mbB] & _fNxN) == 0) inc++;
      if (cabac.decision(off + inc) == 0) return 0;
    } else {
      if (cabac.decision(off) == 0) return 0;
    }
    if (cabac.terminate() != 0) return 25;
    var t = 1;
    if (islice) {
      t += 12 * cabac.decision(off + 3);
      if (cabac.decision(off + 4) != 0) t += 4 + 4 * cabac.decision(off + 5);
      t += 2 * cabac.decision(off + 6);
      t += cabac.decision(off + 7);
    } else {
      t += 12 * cabac.decision(off + 1);
      if (cabac.decision(off + 2) != 0) t += 4 + 4 * cabac.decision(off + 2);
      t += 2 * cabac.decision(off + 3);
      t += cabac.decision(off + 3);
    }
    return t;
  }

  /// Returns unified mb type: for P 0..4 inter, 5.. intra; for B 0..22
  /// inter, 23.. intra; for I 0..25.
  int _cabacMbType() {
    if (_sliceType == sliceI) return _cabacIntraMbType(3, true);
    if (_sliceType == sliceP) {
      if (cabac.decision(14) == 0) {
        if (cabac.decision(15) == 0) {
          return cabac.decision(16) != 0 ? 3 : 0;
        }
        return cabac.decision(17) != 0 ? 1 : 2;
      }
      return 5 + _cabacIntraMbType(17, false);
    }
    var inc = 0;
    if (_availA && (_mbFlags[_mbA] & _fDirect16) == 0) inc++;
    if (_availB && (_mbFlags[_mbB] & _fDirect16) == 0) inc++;
    if (cabac.decision(27 + inc) == 0) return 0;
    if (cabac.decision(30) == 0) return 1 + cabac.decision(32);
    var bits = cabac.decision(31) << 3;
    bits |= cabac.decision(32) << 2;
    bits |= cabac.decision(32) << 1;
    bits |= cabac.decision(32);
    if (bits < 8) return bits + 3;
    if (bits == 13) return 23 + _cabacIntraMbType(32, false);
    if (bits == 14) return 11;
    if (bits == 15) return 22;
    bits = (bits << 1) | cabac.decision(32);
    return bits - 4;
  }

  int _cabacSubMbTypeP() {
    if (cabac.decision(21) != 0) return 0;
    if (cabac.decision(22) == 0) return 1;
    if (cabac.decision(23) != 0) return 2;
    return 3;
  }

  int _cabacSubMbTypeB() {
    if (cabac.decision(36) == 0) return 0;
    if (cabac.decision(37) == 0) return 1 + cabac.decision(39);
    var t = 3;
    if (cabac.decision(38) != 0) {
      if (cabac.decision(39) != 0) return 11 + cabac.decision(39);
      t += 4;
    }
    t += 2 * cabac.decision(39);
    t += cabac.decision(39);
    return t;
  }

  int _cabacRefIdx(int list, int x, int y) {
    final rc = _refCache[list];
    final a = _c(x - 1, y), b = _c(x, y - 1);
    var inc = 0;
    if (_sliceType == sliceB) {
      if (rc[a] > 0 && _directCache[a] == 0) inc++;
      if (rc[b] > 0 && _directCache[b] == 0) inc += 2;
    } else {
      if (rc[a] > 0) inc++;
      if (rc[b] > 0) inc += 2;
    }
    var ref = 0;
    while (cabac.decision(54 + inc) != 0) {
      ref++;
      inc = (inc >> 2) + 4;
      if (ref >= 32) throw H264Exception('bad ref_idx');
    }
    return ref;
  }

  int _cabacMvd(int base, int amvd) {
    final inc = amvd < 3 ? 0 : (amvd > 32 ? 2 : 1);
    if (cabac.decision(base + inc) == 0) return 0;
    var mvd = 1;
    var ctx = base + 3;
    while (mvd < 9 && cabac.decision(ctx) != 0) {
      if (mvd < 4) ctx++;
      mvd++;
    }
    if (mvd >= 9) {
      var k = 3;
      while (cabac.bypass() != 0) {
        mvd += 1 << k;
        k++;
        if (k > 24) throw H264Exception('bad mvd');
      }
      while (k-- > 0) {
        mvd += cabac.bypass() << k;
      }
    }
    return cabac.bypass() != 0 ? -mvd : mvd;
  }

  int _cabacQpDelta() {
    final inc = _lastQpDelta != 0 ? 1 : 0;
    if (cabac.decision(60 + inc) == 0) return 0;
    var k = 1;
    var ctx = 62;
    while (cabac.decision(ctx) != 0) {
      ctx = 63;
      k++;
      if (k > 104) throw H264Exception('bad mb_qp_delta');
    }
    return (k & 1) != 0 ? (k + 1) >> 1 : -(k >> 1);
  }

  int _cabacChromaPredMode() {
    var inc = 0;
    if (_availA && _intraNotPcm(_mbA) && _chromaModeTab[_mbA] != 0) inc++;
    if (_availB && _intraNotPcm(_mbB) && _chromaModeTab[_mbB] != 0) inc++;
    if (cabac.decision(64 + inc) == 0) return 0;
    if (cabac.decision(67) == 0) return 1;
    if (cabac.decision(67) == 0) return 2;
    return 3;
  }

  bool _intraNotPcm(int mb) {
    final f = _mbFlags[mb];
    return (f & _fIntra) != 0 && (f & _fPcm) == 0;
  }

  int _cabacCbp() {
    // Luma: cbp bits of left/top 8x8 blocks. Unavailable acts as coded.
    final cbpA = _availA ? _cbpTab[_mbA] : 0x0F;
    final cbpB = _availB ? _cbpTab[_mbB] : 0x0F;
    var cbp = 0;
    // b8 0
    var inc = (((cbpA >> 1) & 1) == 0 ? 1 : 0) + ((((cbpB >> 2) & 1) == 0) ? 2 : 0);
    cbp |= cabac.decision(73 + inc);
    // b8 1
    inc = ((cbp & 1) == 0 ? 1 : 0) + (((cbpB >> 3) & 1) == 0 ? 2 : 0);
    cbp |= cabac.decision(73 + inc) << 1;
    // b8 2
    inc = (((cbpA >> 3) & 1) == 0 ? 1 : 0) + ((cbp & 1) == 0 ? 2 : 0);
    cbp |= cabac.decision(73 + inc) << 2;
    // b8 3
    inc = (((cbp >> 2) & 1) == 0 ? 1 : 0) + (((cbp >> 1) & 1) == 0 ? 2 : 0);
    cbp |= cabac.decision(73 + inc) << 3;
    // Chroma.
    final ca = _availA ? (_cbpTab[_mbA] >> 4) : 0;
    final cb = _availB ? (_cbpTab[_mbB] >> 4) : 0;
    inc = (ca > 0 ? 1 : 0) + (cb > 0 ? 2 : 0);
    if (cabac.decision(77 + inc) == 0) return cbp;
    inc = 4 + (ca == 2 ? 1 : 0) + (cb == 2 ? 2 : 0);
    return cbp | ((1 + cabac.decision(77 + inc)) << 4);
  }

  int _cabacTransform8x8() {
    var inc = 0;
    if (_availA && (_mbFlags[_mbA] & _fT8) != 0) inc++;
    if (_availB && (_mbFlags[_mbB] & _fT8) != 0) inc++;
    return cabac.decision(399 + inc);
  }

  /// Decodes one residual block with CABAC. Returns the number of
  /// coefficients written to [_resIdx]/[_resLevel].
  int _cabacResidual(int cat, int cbfInc, int maxNum) {
    final c = cabac;
    int sigBase, lastBase, absBase;
    if (cat == 5) {
      sigBase = 402;
      lastBase = 417;
      absBase = 426;
    } else {
      if (c.decision(85 + _cbfCatOffset[cat] + cbfInc) == 0) return 0;
      sigBase = 105 + _sigCatOffset[cat];
      lastBase = 166 + _sigCatOffset[cat];
      absBase = 227 + _absCatOffset[cat];
    }
    final idx = _resIdx;
    var n = 0;
    final last = maxNum - 1;
    var i = 0;
    var ended = false;
    if (cat == 5) {
      for (; i < last; i++) {
        if (c.decision(sigBase + sigCoeffFlagOffset8x8Frame[i]) != 0) {
          idx[n++] = i;
          if (c.decision(lastBase + lastCoeffFlagOffset8x8[i]) != 0) {
            ended = true;
            break;
          }
        }
      }
    } else if (cat == 3) {
      for (; i < last; i++) {
        final inc = i < 2 ? i : 2;
        if (c.decision(sigBase + inc) != 0) {
          idx[n++] = i;
          if (c.decision(lastBase + inc) != 0) {
            ended = true;
            break;
          }
        }
      }
    } else {
      for (; i < last; i++) {
        if (c.decision(sigBase + i) != 0) {
          idx[n++] = i;
          if (c.decision(lastBase + i) != 0) {
            ended = true;
            break;
          }
        }
      }
    }
    if (!ended) idx[n++] = last;
    final lev = _resLevel;
    var gt1 = 0, eq1 = 0;
    final gtMax = cat == 3 ? 3 : 4;
    for (var j = n - 1; j >= 0; j--) {
      int absv;
      if (c.decision(absBase + (gt1 != 0 ? 0 : (eq1 < 3 ? 1 + eq1 : 4))) == 0) {
        absv = 1;
        eq1++;
      } else {
        final ctx = absBase + 5 + (gt1 < gtMax ? gt1 : gtMax);
        var prefix = 1;
        while (prefix < 14 && c.decision(ctx) != 0) {
          prefix++;
        }
        if (prefix == 14) {
          var k = 0;
          var suf = 0;
          while (c.bypass() != 0) {
            suf += 1 << k;
            k++;
            if (k > 24) throw H264Exception('bad coeff_abs_level');
          }
          while (k-- > 0) {
            suf += c.bypass() << k;
          }
          absv = 15 + suf;
        } else {
          absv = prefix + 1;
        }
        gt1++;
      }
      lev[j] = c.bypass() != 0 ? -absv : absv;
    }
    return n;
  }

  // ===================================================== CAVLC elements

  int _cavlcMbType() {
    final v = _r.ue();
    if (_sliceType == sliceI) {
      if (v > 25) throw H264Exception('bad mb_type');
    } else if (_sliceType == sliceP) {
      if (v > 30) throw H264Exception('bad mb_type');
    } else {
      if (v > 48) throw H264Exception('bad mb_type');
    }
    return v;
  }

  // ============================================== neighbour helpers

  /// Total coefficient count of 4x4 luma block (x, y) for nC, with x or y
  /// possibly -1 (neighbour MB). Returns -1 if unavailable.
  int _nzLuma(int x, int y) {
    if (x < 0) {
      if (!_availA) return -1;
      return _nzTab[_mbA * 24 + y * 4 + 3];
    }
    if (y < 0) {
      if (!_availB) return -1;
      return _nzTab[_mbB * 24 + 12 + x];
    }
    return _nzTab[_mb * 24 + y * 4 + x];
  }

  int _nzChroma(int c, int x, int y) {
    final base = 16 + c * 4;
    if (x < 0) {
      if (!_availA) return -1;
      return _nzTab[_mbA * 24 + base + y * 2 + 1];
    }
    if (y < 0) {
      if (!_availB) return -1;
      return _nzTab[_mbB * 24 + base + 2 + x];
    }
    return _nzTab[_mb * 24 + base + y * 2 + x];
  }

  static int _predNc(int a, int b) {
    if (a >= 0 && b >= 0) return (a + b + 1) >> 1;
    if (a >= 0) return a;
    if (b >= 0) return b;
    return 0;
  }

  /// CABAC coded_block_flag ctxIdxInc for luma 4x4 block (x, y)
  /// (cat 1 and 2) based on the stored coefficient counts.
  int _cbfIncLuma(int x, int y) {
    final intra = (_flags & _fIntra) != 0;
    int a, b;
    if (x > 0) {
      a = _nzTab[_mb * 24 + y * 4 + x - 1] != 0 ? 1 : 0;
    } else if (_availA) {
      final f = _mbFlags[_mbA];
      if ((f & _fPcm) != 0) {
        a = 1;
      } else {
        a = _nzTab[_mbA * 24 + y * 4 + 3] != 0 ? 1 : 0;
      }
    } else {
      a = intra ? 1 : 0;
    }
    if (y > 0) {
      b = _nzTab[_mb * 24 + (y - 1) * 4 + x] != 0 ? 1 : 0;
    } else if (_availB) {
      final f = _mbFlags[_mbB];
      if ((f & _fPcm) != 0) {
        b = 1;
      } else {
        b = _nzTab[_mbB * 24 + 12 + x] != 0 ? 1 : 0;
      }
    } else {
      b = intra ? 1 : 0;
    }
    return a + 2 * b;
  }

  int _cbfIncChromaAc(int c, int x, int y) {
    final intra = (_flags & _fIntra) != 0;
    final base = 16 + c * 4;
    int a, b;
    if (x > 0) {
      a = _nzTab[_mb * 24 + base + y * 2] != 0 ? 1 : 0;
    } else if (_availA) {
      a = (_mbFlags[_mbA] & _fPcm) != 0 ? 1 : (_nzTab[_mbA * 24 + base + y * 2 + 1] != 0 ? 1 : 0);
    } else {
      a = intra ? 1 : 0;
    }
    if (y > 0) {
      b = _nzTab[_mb * 24 + base + x] != 0 ? 1 : 0;
    } else if (_availB) {
      b = (_mbFlags[_mbB] & _fPcm) != 0 ? 1 : (_nzTab[_mbB * 24 + base + 2 + x] != 0 ? 1 : 0);
    } else {
      b = intra ? 1 : 0;
    }
    return a + 2 * b;
  }

  /// ctxIdxInc for DC blocks: [bit] 0 luma DC, 1 Cb DC, 2 Cr DC.
  int _cbfIncDc(int bit) {
    final intra = (_flags & _fIntra) != 0;
    int a, b;
    if (_availA) {
      a = (_mbFlags[_mbA] & _fPcm) != 0 ? 1 : ((_cbfDcTab[_mbA] >> bit) & 1);
    } else {
      a = intra ? 1 : 0;
    }
    if (_availB) {
      b = (_mbFlags[_mbB] & _fPcm) != 0 ? 1 : ((_cbfDcTab[_mbB] >> bit) & 1);
    } else {
      b = intra ? 1 : 0;
    }
    return a + 2 * b;
  }

  // ===================================================== macroblock layer

  void _macroblockLayer() {
    final cab = _cabac;
    final mbType = cab ? _cabacMbType() : _cavlcMbType();
    var iType = -1;
    if (_sliceType == sliceI) {
      iType = mbType;
    } else if (_sliceType == sliceP) {
      if (mbType >= 5) iType = mbType - 5;
    } else {
      if (mbType >= 23) iType = mbType - 23;
    }
    if (iType >= 0) {
      _decodeIntraMb(iType);
    } else {
      _decodeInterMb(mbType);
    }
  }

  void _decodeIntraMb(int iType) {
    final cab = _cabac;
    _flags = _fIntra;
    // Intra macroblocks have no motion.
    _clearMotion();
    if (iType == 25) {
      _decodePcm();
      return;
    }
    final mb = _mb;
    if (iType == 0) {
      _flags |= _fNxN;
      if (pps.transform8x8Mode) {
        _t8 = (cab ? _cabacTransform8x8() : _r.u1()) != 0;
        if (_t8) _flags |= _fT8;
      }
      _parseIntraNxNModes();
    } else {
      _flags |= _fI16;
      _i16Mode = (iType - 1) & 3;
      final chroma = ((iType - 1) >> 2) % 3;
      final luma = iType >= 13 ? 15 : 0;
      _cbp = luma | (chroma << 4);
      for (var i = 0; i < 16; i++) {
        _ipred[i] = 2;
      }
    }
    _chromaMode = cab ? _cabacChromaPredMode() : _r.ue();
    if (_chromaMode > 3) throw H264Exception('bad intra_chroma_pred_mode');
    if (iType == 0) {
      if (cab) {
        _cbp = _cabacCbp();
      } else {
        final v = _r.ue();
        if (v > 47) throw H264Exception('bad cbp');
        _cbp = golombToIntraCbp[v];
      }
    }
    _mbFlags[mb] = _flags;
    _residualAndQp();
    _storeMbCommon();
    _reconIntra();
  }

  void _parseIntraNxNModes() {
    final cab = _cabac;
    final constrained = pps.constrainedIntraPred;
    final dcA = !_availA || (constrained && (_mbFlags[_mbA] & _fIntra) == 0);
    final dcB = !_availB || (constrained && (_mbFlags[_mbB] & _fIntra) == 0);
    final ipred = _ipred;
    if (_t8) {
      for (var b8 = 0; b8 < 4; b8++) {
        final x = (b8 & 1) * 2, y = (b8 >> 1) * 2;
        final pred = _predIntraMode(x, y, dcA, dcB);
        int mode;
        if (cab) {
          if (cabac.decision(68) != 0) {
            mode = pred;
          } else {
            var rem = cabac.decision(69);
            rem |= cabac.decision(69) << 1;
            rem |= cabac.decision(69) << 2;
            mode = rem < pred ? rem : rem + 1;
          }
        } else {
          if (_r.u1() != 0) {
            mode = pred;
          } else {
            final rem = _r.u(3);
            mode = rem < pred ? rem : rem + 1;
          }
        }
        ipred[y * 4 + x] = mode;
        ipred[y * 4 + x + 1] = mode;
        ipred[y * 4 + x + 4] = mode;
        ipred[y * 4 + x + 5] = mode;
      }
    } else {
      for (var blk = 0; blk < 16; blk++) {
        final x = blkX[blk], y = blkY[blk];
        final pred = _predIntraMode(x, y, dcA, dcB);
        int mode;
        if (cab) {
          if (cabac.decision(68) != 0) {
            mode = pred;
          } else {
            var rem = cabac.decision(69);
            rem |= cabac.decision(69) << 1;
            rem |= cabac.decision(69) << 2;
            mode = rem < pred ? rem : rem + 1;
          }
        } else {
          if (_r.u1() != 0) {
            mode = pred;
          } else {
            final rem = _r.u(3);
            mode = rem < pred ? rem : rem + 1;
          }
        }
        ipred[y * 4 + x] = mode;
      }
    }
  }

  int _predIntraMode(int x, int y, bool dcA, bool dcB) {
    if ((x == 0 && dcA) || (y == 0 && dcB)) return 2;
    final a = x > 0 ? _ipred[y * 4 + x - 1] : _ipredTab[_mbA * 16 + y * 4 + 3];
    final b = y > 0 ? _ipred[(y - 1) * 4 + x] : _ipredTab[_mbB * 16 + 12 + x];
    return a < b ? a : b;
  }

  void _clearMotion() {
    final pic = cur;
    final base = _mb * 16;
    for (var i = 0; i < 16; i++) {
      pic.ref0[base + i] = -1;
      pic.ref1[base + i] = -1;
      pic.refId0[base + i] = -1;
      pic.refId1[base + i] = -1;
    }
    pic.mv0.fillRange(base * 2, base * 2 + 32, 0);
    pic.mv1.fillRange(base * 2, base * 2 + 32, 0);
    if (_cabac) {
      _mvdTab.fillRange(_mb * 32, _mb * 32 + 32, 0);
      _mvdTab.fillRange((mbCount + _mb) * 32, (mbCount + _mb) * 32 + 32, 0);
    }
    _directTab[_mb] = 0;
    pic.mbIntra[_mb] = 1;
  }

  void _decodePcm() {
    _flags |= _fPcm;
    final mb = _mb;
    Uint8List data;
    int p;
    if (_cabac) {
      p = cabac.alignedBytePos();
      data = _r.data;
    } else {
      while (!_r.byteAligned) {
        _r.u1();
      }
      p = _r.pos >> 3;
      data = _r.data;
    }
    if (p + 384 > data.length - 8) throw H264Exception('truncated I_PCM');
    final pic = cur;
    final w = pic.width, cw = w >> 1;
    final lo = _mbY * 16 * w + _mbX * 16;
    for (var y = 0; y < 16; y++) {
      for (var x = 0; x < 16; x++) {
        pic.y[lo + y * w + x] = data[p++];
      }
    }
    final co = _mbY * 8 * cw + _mbX * 8;
    for (var c = 0; c < 2; c++) {
      final pl = c == 0 ? pic.u : pic.v;
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          pl[co + y * cw + x] = data[p++];
        }
      }
    }
    if (_cabac) {
      cabac.initEngine(data, p);
    } else {
      _r.pos = p * 8;
    }
    _mbFlags[mb] = _flags;
    _cbp = 0x2F;
    _cbpTab[mb] = 0x2F;
    _cbfDcTab[mb] = 7;
    _nzTab.fillRange(mb * 24, mb * 24 + 24, 16);
    _chromaModeTab[mb] = 0;
    for (var i = 0; i < 16; i++) {
      _ipredTab[mb * 16 + i] = 2;
    }
    _lastQpDelta = 0;
    info.qp[mb] = 0;
    info.intra[mb] = 1;
    info.t8[mb] = 0;
    info.nzMask[mb] = 0xFFFF;
  }

  // ------------------------------------------------------------ residual

  void _residualAndQp() {
    final intra16 = (_flags & _fI16) != 0;
    if ((_cbp & 0x3F) != 0 || intra16) {
      final dq = _cabac ? _cabacQpDelta() : _r.se();
      if (dq < -26 || dq > 25) throw H264Exception('bad mb_qp_delta');
      _lastQpDelta = dq;
      _qp = (_qp + dq + 52) % 52;
      _residual();
    } else {
      _lastQpDelta = 0;
      _clearResidualState();
    }
  }

  void _clearResidualState() {
    _nzTab.fillRange(_mb * 24, _mb * 24 + 24, 0);
    _cbfDcTab[_mb] = 0;
    for (var i = 0; i < 24; i++) {
      _blkFlags[i] = 0;
    }
    _b8Flags[0] = _b8Flags[1] = _b8Flags[2] = _b8Flags[3] = 0;
  }

  void _residual() {
    _clearResidualState();
    final mb = _mb;
    final intra = (_flags & _fIntra) != 0;
    final qp = _qp;
    final coef = _coef;
    final cab = _cabac;
    var cbfDc = 0;
    // ---- luma
    if ((_flags & _fI16) != 0) {
      // DC
      int n;
      if (cab) {
        n = _cabacResidual(0, _cbfIncDc(0), 16);
      } else {
        n = cavlc.decode(_r, _predNc(_nzLuma(-1, 0), _nzLuma(0, -1)), 16);
        _copyCavlc(n);
      }
      if (n > 0) {
        cbfDc |= 1;
        final c = _dcTmp;
        for (var i = 0; i < 16; i++) {
          c[i] = 0;
        }
        for (var i = 0; i < n; i++) {
          c[zigzag4x4[_resIdx[i]]] = _resLevel[i];
        }
        _lumaDcDequant(c, _dq4[0][qp * 16]);
        for (var i = 0; i < 16; i++) {
          final v = c[i];
          if (v != 0) {
            coef[i * 16] = v;
            _blkFlags[i] = 1;
          }
        }
      }
      for (var blk = 0; blk < 16; blk++) {
        final x = blkX[blk], y = blkY[blk];
        final rb = y * 4 + x;
        if ((_cbp & (1 << (blk >> 2))) == 0) continue;
        int n2;
        if (cab) {
          n2 = _cabacResidual(1, _cbfIncLuma(x, y), 15);
        } else {
          n2 = cavlc.decode(_r, _predNc(_nzLuma(x - 1, y), _nzLuma(x, y - 1)), 15);
          _copyCavlc(n2);
        }
        _nzTab[mb * 24 + rb] = n2;
        if (n2 > 0) {
          final dq = _dq4[0];
          final o = rb * 16;
          for (var i = 0; i < n2; i++) {
            final pos = zigzag4x4[_resIdx[i] + 1];
            coef[o + pos] = asr(_resLevel[i] * dq[qp * 16 + pos] + 8, 4);
          }
          _blkFlags[rb] |= 3;
        }
      }
    } else if (!_t8) {
      final dq = _dq4[intra ? 0 : 3];
      for (var blk = 0; blk < 16; blk++) {
        if ((_cbp & (1 << (blk >> 2))) == 0) continue;
        final x = blkX[blk], y = blkY[blk];
        final rb = y * 4 + x;
        int n;
        if (cab) {
          n = _cabacResidual(2, _cbfIncLuma(x, y), 16);
        } else {
          n = cavlc.decode(_r, _predNc(_nzLuma(x - 1, y), _nzLuma(x, y - 1)), 16);
          _copyCavlc(n);
        }
        _nzTab[mb * 24 + rb] = n;
        if (n > 0) {
          final o = rb * 16;
          var fl = 1;
          for (var i = 0; i < n; i++) {
            final pos = zigzag4x4[_resIdx[i]];
            coef[o + pos] = asr(_resLevel[i] * dq[qp * 16 + pos] + 8, 4);
            if (pos != 0) fl = 3;
          }
          _blkFlags[rb] = fl;
        }
      }
    } else {
      final dq = _dq8[intra ? 0 : 1];
      for (var b8 = 0; b8 < 4; b8++) {
        if ((_cbp & (1 << b8)) == 0) continue;
        final o = b8 * 64;
        final bx = (b8 & 1) * 2, by = (b8 >> 1) * 2;
        var fl = 0;
        if (cab) {
          final n = _cabacResidual(5, 0, 64);
          for (var i = 0; i < n; i++) {
            final pos = zigzag8x8[_resIdx[i]];
            coef[o + pos] = asr(_resLevel[i] * dq[qp * 64 + pos] + 32, 6);
            fl |= pos != 0 ? 3 : 1;
          }
          for (var k = 0; k < 4; k++) {
            _nzTab[mb * 24 + (by + (k >> 1)) * 4 + bx + (k & 1)] = n;
          }
        } else {
          for (var k = 0; k < 4; k++) {
            final x = bx + (k & 1), y = by + (k >> 1);
            final n = cavlc.decode(_r, _predNc(_nzLuma(x - 1, y), _nzLuma(x, y - 1)), 16);
            _nzTab[mb * 24 + y * 4 + x] = n;
            for (var i = 0; i < n; i++) {
              final pos = zigzag8x8[4 * cavlc.outIdx[i] + k];
              coef[o + pos] = asr(cavlc.outLevel[i] * dq[qp * 64 + pos] + 32, 6);
              fl |= pos != 0 ? 3 : 1;
            }
          }
        }
        _b8Flags[b8] = fl;
      }
    }
    // ---- chroma
    final cbpC = _cbp >> 4;
    if (cbpC != 0) {
      for (var c = 0; c < 2; c++) {
        final qpc =
            chromaQpTable[_clip3(
              0,
              51,
              qp + (c == 0 ? pps.chromaQpIndexOffset : pps.secondChromaQpIndexOffset),
            )];
        int n;
        if (cab) {
          n = _cabacResidual(3, _cbfIncDc(1 + c), 4);
        } else {
          n = cavlc.decode(_r, -1, 4);
          _copyCavlc(n);
        }
        if (n > 0) {
          cbfDc |= 2 << c;
          final d = _dcTmp;
          d[0] = d[1] = d[2] = d[3] = 0;
          for (var i = 0; i < n; i++) {
            d[_resIdx[i]] = _resLevel[i];
          }
          final c0 = d[0], c1 = d[1], c2 = d[2], c3 = d[3];
          final f0 = c0 + c1 + c2 + c3;
          final f1 = c0 - c1 + c2 - c3;
          final f2 = c0 + c1 - c2 - c3;
          final f3 = c0 - c1 - c2 + c3;
          final scale = _dq4[(intra ? 1 : 4) + c][qpc * 16];
          final base = 256 + c * 64;
          final fb = 16 + c * 4;
          final v0 = asr(f0 * scale, 5), v1 = asr(f1 * scale, 5);
          final v2 = asr(f2 * scale, 5), v3 = asr(f3 * scale, 5);
          coef[base] = v0;
          coef[base + 16] = v1;
          coef[base + 32] = v2;
          coef[base + 48] = v3;
          if (v0 != 0) _blkFlags[fb] = 1;
          if (v1 != 0) _blkFlags[fb + 1] = 1;
          if (v2 != 0) _blkFlags[fb + 2] = 1;
          if (v3 != 0) _blkFlags[fb + 3] = 1;
        }
      }
      if ((cbpC & 2) != 0) {
        for (var c = 0; c < 2; c++) {
          final qpc =
              chromaQpTable[_clip3(
                0,
                51,
                qp + (c == 0 ? pps.chromaQpIndexOffset : pps.secondChromaQpIndexOffset),
              )];
          final dq = _dq4[(intra ? 1 : 4) + c];
          for (var b = 0; b < 4; b++) {
            final x = b & 1, y = b >> 1;
            int n;
            if (cab) {
              n = _cabacResidual(4, _cbfIncChromaAc(c, x, y), 15);
            } else {
              n = cavlc.decode(_r, _predNc(_nzChroma(c, x - 1, y), _nzChroma(c, x, y - 1)), 15);
              _copyCavlc(n);
            }
            _nzTab[mb * 24 + 16 + c * 4 + b] = n;
            if (n > 0) {
              final o = 256 + c * 64 + b * 16;
              for (var i = 0; i < n; i++) {
                final pos = zigzag4x4[_resIdx[i] + 1];
                coef[o + pos] = asr(_resLevel[i] * dq[qpc * 16 + pos] + 8, 4);
              }
              _blkFlags[16 + c * 4 + b] |= 3;
            }
          }
        }
      }
    }
    _cbfDcTab[mb] = cbfDc;
  }

  void _copyCavlc(int n) {
    final oi = cavlc.outIdx, ol = cavlc.outLevel;
    for (var i = 0; i < n; i++) {
      _resIdx[i] = oi[i];
      _resLevel[i] = ol[i];
    }
  }

  /// Inverse Hadamard and scaling of the Intra16x16 DC (8.5.10).
  final Int32List _hTmp = Int32List(16);

  void _lumaDcDequant(Int32List c, int scale) {
    final t = _hTmp;
    for (var i = 0; i < 4; i++) {
      final a = c[i * 4], b = c[i * 4 + 1], cc = c[i * 4 + 2], d = c[i * 4 + 3];
      final s0 = a + b, s1 = a - b, s2 = cc + d, s3 = cc - d;
      t[i * 4] = s0 + s2;
      t[i * 4 + 1] = s0 - s2;
      t[i * 4 + 2] = s1 - s3;
      t[i * 4 + 3] = s1 + s3;
    }
    for (var j = 0; j < 4; j++) {
      final a = t[j], b = t[4 + j], cc = t[8 + j], d = t[12 + j];
      final s0 = a + b, s1 = a - b, s2 = cc + d, s3 = cc - d;
      c[j] = asr((s0 + s2) * scale + 32, 6);
      c[4 + j] = asr((s0 - s2) * scale + 32, 6);
      c[8 + j] = asr((s1 - s3) * scale + 32, 6);
      c[12 + j] = asr((s1 + s3) * scale + 32, 6);
    }
  }

  /// Debug hook: called with a description of every decoded macroblock.
  static void Function(String)? debugLog;

  void _storeMbCommon() {
    final mb = _mb;
    final dl = debugLog;
    if (dl != null) {
      dl(
        'mb $mb flags $_flags cbp $_cbp qp $_qp t8 $_t8 i16 $_i16Mode cm $_chromaMode ipred ${_ipred.toList()} nz ${_nzTab.sublist(mb * 24, mb * 24 + 24).toList()}',
      );
    }
    _mbFlags[mb] = _flags;
    _cbpTab[mb] = _cbp;
    _chromaModeTab[mb] = (_flags & _fIntra) != 0 ? _chromaMode : 0;
    final it = _ipredTab;
    if ((_flags & _fNxN) != 0) {
      for (var i = 0; i < 16; i++) {
        it[mb * 16 + i] = _ipred[i];
      }
    } else {
      for (var i = 0; i < 16; i++) {
        it[mb * 16 + i] = 2;
      }
    }
    info.qp[mb] = _qp;
    info.intra[mb] = (_flags & _fIntra) != 0 ? 1 : 0;
    info.uniform[mb] = 0;
    info.t8[mb] = _t8 ? 1 : 0;
    var mask = 0;
    if (_t8) {
      for (var b8 = 0; b8 < 4; b8++) {
        if (_b8Flags[b8] != 0) {
          final bx = (b8 & 1) * 2, by = (b8 >> 1) * 2;
          mask |= 0x33 << (by * 4 + bx);
        }
      }
    } else {
      for (var i = 0; i < 16; i++) {
        if (_nzTab[mb * 24 + i] != 0) mask |= 1 << i;
      }
    }
    info.nzMask[mb] = mask;
  }

  // ------------------------------------------------------------ intra recon

  bool _intraAvail(bool avail, int mbN) =>
      avail && (!pps.constrainedIntraPred || (_mbFlags[mbN] & _fIntra) != 0);

  void _reconIntra() {
    final pic = cur;
    final w = pic.width;
    final lo = _mbY * 16 * w + _mbX * 16;
    final aA = _intraAvail(_availA, _mbA);
    final aB = _intraAvail(_availB, _mbB);
    final aC = _intraAvail(_availC, _mbC);
    final aD = _intraAvail(_availD, _mbD);
    final y = pic.y;
    final coef = _coef;
    if ((_flags & _fI16) != 0) {
      recon.intra16x16(y, lo, w, _i16Mode, aB, aA, aD);
      for (var rb = 0; rb < 16; rb++) {
        final f = _blkFlags[rb];
        if (f == 0) continue;
        final off = lo + (rb >> 2) * 4 * w + (rb & 3) * 4;
        if (f == 1) {
          Recon.dcAdd(coef, rb * 16, y, off, w, 4);
        } else {
          recon.idct4Add(coef, rb * 16, y, off, w);
        }
      }
    } else if (_t8) {
      for (var b8 = 0; b8 < 4; b8++) {
        final bx = b8 & 1, by = b8 >> 1;
        final top = by > 0 || aB;
        final left = bx > 0 || aA;
        final tl = (bx > 0 && by > 0) ? true : (bx == 0 && by == 0 ? aD : (bx == 0 ? aA : aB));
        final tr = by == 0 ? (bx == 0 ? aB : aC) : (bx == 0);
        final off = lo + by * 8 * w + bx * 8;
        recon.intra8x8(y, off, w, _ipred[by * 8 + bx * 2], top, left, tl, tr);
        final f = _b8Flags[b8];
        if (f == 1) {
          Recon.dcAdd(coef, b8 * 64, y, off, w, 8);
        } else if (f != 0) {
          recon.idct8Add(coef, b8 * 64, y, off, w);
        }
      }
    } else {
      for (var blk = 0; blk < 16; blk++) {
        final bx = blkX[blk], by = blkY[blk];
        final top = by > 0 || aB;
        final left = bx > 0 || aA;
        final tl = (bx > 0 && by > 0) ? true : (bx == 0 && by == 0 ? aD : (bx == 0 ? aA : aB));
        bool tr;
        if (by == 0) {
          tr = bx < 3 ? aB : aC;
        } else if (bx == 3) {
          tr = false;
        } else {
          tr = rasterBlk[(by - 1) * 4 + bx + 1] < blk;
        }
        final rb = by * 4 + bx;
        final off = lo + by * 4 * w + bx * 4;
        recon.intra4x4(y, off, w, _ipred[rb], top, left, tl, tr);
        final f = _blkFlags[rb];
        if (f == 1) {
          Recon.dcAdd(coef, rb * 16, y, off, w, 4);
        } else if (f != 0) {
          recon.idct4Add(coef, rb * 16, y, off, w);
        }
      }
    }
    // Chroma.
    final cw = w >> 1;
    final co = _mbY * 8 * cw + _mbX * 8;
    recon.intraChroma(pic.u, co, cw, _chromaMode, aB, aA, aD);
    recon.intraChroma(pic.v, co, cw, _chromaMode, aB, aA, aD);
    _addChromaResidual();
  }

  void _addChromaResidual() {
    final pic = cur;
    final cw = pic.width >> 1;
    final co = _mbY * 8 * cw + _mbX * 8;
    final coef = _coef;
    for (var c = 0; c < 2; c++) {
      final pl = c == 0 ? pic.u : pic.v;
      for (var b = 0; b < 4; b++) {
        final f = _blkFlags[16 + c * 4 + b];
        if (f == 0) continue;
        final off = co + (b >> 1) * 4 * cw + (b & 1) * 4;
        final ci = 256 + c * 64 + b * 16;
        if (f == 1) {
          Recon.dcAdd(coef, ci, pl, off, cw, 4);
        } else {
          recon.idct4Add(coef, ci, pl, off, cw);
        }
      }
    }
  }

  void _addLumaResidual() {
    final pic = cur;
    final w = pic.width;
    final lo = _mbY * 16 * w + _mbX * 16;
    final coef = _coef;
    final y = pic.y;
    if (_t8) {
      for (var b8 = 0; b8 < 4; b8++) {
        final f = _b8Flags[b8];
        if (f == 0) continue;
        final off = lo + (b8 >> 1) * 8 * w + (b8 & 1) * 8;
        if (f == 1) {
          Recon.dcAdd(coef, b8 * 64, y, off, w, 8);
        } else {
          recon.idct8Add(coef, b8 * 64, y, off, w);
        }
      }
    } else {
      for (var rb = 0; rb < 16; rb++) {
        final f = _blkFlags[rb];
        if (f == 0) continue;
        final off = lo + (rb >> 2) * 4 * w + (rb & 3) * 4;
        if (f == 1) {
          Recon.dcAdd(coef, rb * 16, y, off, w, 4);
        } else {
          recon.idct4Add(coef, rb * 16, y, off, w);
        }
      }
    }
  }

  // ============================================================ inter

  /// Loads the neighbouring motion data (row above, column to the left and
  /// the C and D corners) into the caches. Interior entries are always
  /// written by the macroblock before they are read; the column right of
  /// the macroblock stays "not available" (set once in [_initCaches]).
  /// [full] also loads CABAC mvd and direct-flag neighbours.
  void _fillInterCaches({bool full = true}) {
    final pic = cur;
    final st = mbCount;
    for (var list = 0; list < _numLists; list++) {
      final rc = _refCache[list];
      final mc = _mvCache[list];
      final refs = list == 0 ? pic.ref0 : pic.ref1;
      final mvs = list == 0 ? pic.mv0 : pic.mv1;
      if (_availB) {
        final base = _mbB * 16 + 12;
        for (var x = 0; x < 4; x++) {
          final p = 1 + x;
          rc[p] = refs[base + x];
          mc[p * 2] = mvs[(base + x) * 2];
          mc[p * 2 + 1] = mvs[(base + x) * 2 + 1];
        }
      } else {
        for (var p = 1; p < 5; p++) {
          rc[p] = -2;
          mc[p * 2] = 0;
          mc[p * 2 + 1] = 0;
        }
      }
      if (_availD) {
        final g = _mbD * 16 + 15;
        rc[0] = refs[g];
        mc[0] = mvs[g * 2];
        mc[1] = mvs[g * 2 + 1];
      } else {
        rc[0] = -2;
        mc[0] = 0;
        mc[1] = 0;
      }
      if (_availC) {
        final g = _mbC * 16 + 12;
        rc[5] = refs[g];
        mc[10] = mvs[g * 2];
        mc[11] = mvs[g * 2 + 1];
      } else {
        rc[5] = -2;
        mc[10] = 0;
        mc[11] = 0;
      }
      if (_availA) {
        for (var y = 0; y < 4; y++) {
          final g = _mbA * 16 + y * 4 + 3;
          final p = (y + 1) * 8;
          rc[p] = refs[g];
          mc[p * 2] = mvs[g * 2];
          mc[p * 2 + 1] = mvs[g * 2 + 1];
        }
      } else {
        for (var y = 0; y < 4; y++) {
          final p = (y + 1) * 8;
          rc[p] = -2;
          mc[p * 2] = 0;
          mc[p * 2 + 1] = 0;
        }
      }
      if (full && _cabac) {
        final md = _mvdCache[list];
        final tb = list * st;
        if (_availB) {
          final base = ((tb + _mbB) * 16 + 12) * 2;
          for (var x = 0; x < 8; x++) {
            md[2 + x] = _mvdTab[base + x];
          }
        } else {
          for (var x = 0; x < 8; x++) {
            md[2 + x] = 0;
          }
        }
        if (_availA) {
          for (var y = 0; y < 4; y++) {
            final g = ((tb + _mbA) * 16 + y * 4 + 3) * 2;
            final p = (y + 1) * 16;
            md[p] = _mvdTab[g];
            md[p + 1] = _mvdTab[g + 1];
          }
        } else {
          for (var y = 0; y < 4; y++) {
            final p = (y + 1) * 16;
            md[p] = 0;
            md[p + 1] = 0;
          }
        }
      }
    }
    if (full && _cabac && _sliceType == sliceB) {
      final dc = _directCache;
      final mB = _availB ? _directTab[_mbB] : 0;
      for (var x = 0; x < 4; x++) {
        dc[1 + x] = (mB >> (12 + x)) & 1;
      }
      final mA = _availA ? _directTab[_mbA] : 0;
      for (var y = 0; y < 4; y++) {
        dc[(y + 1) * 8] = (mA >> (y * 4 + 3)) & 1;
      }
    }
  }

  /// One-time cache initialisation: entries right of the macroblock are
  /// never available.
  void _initCaches() {
    for (var list = 0; list < 2; list++) {
      _refCache[list].fillRange(0, 40, -2);
      for (var y = 0; y < 4; y++) {
        _refCache[list][(y + 1) * 8 + 5] = -2;
      }
    }
  }

  /// Motion vector prediction (8.4.1.3) for a partition at (x, y) with width
  /// [w] (4x4 units). [shape] 1 = 16x8, 2 = 8x16, otherwise median.
  void _mvPred(int list, int x, int y, int w, int ref, int shape) {
    final rc = _refCache[list];
    final mc = _mvCache[list];
    final a = _c(x - 1, y), b = _c(x, y - 1);
    final cx = x + w, cy = y - 1;
    var ci = _c(cx, cy);
    var refC = rc[ci];
    if (cy >= 0 && cx <= 3 && rasterBlk[cy * 4 + cx] > rasterBlk[y * 4 + x]) {
      refC = -2;
    }
    if (refC == -2) {
      ci = _c(x - 1, y - 1);
      refC = rc[ci];
    }
    final refA = rc[a], refB = rc[b];
    if (shape == 1) {
      if (y == 0) {
        if (refB == ref) {
          _mvpX = mc[b * 2];
          _mvpY = mc[b * 2 + 1];
          return;
        }
      } else if (refA == ref) {
        _mvpX = mc[a * 2];
        _mvpY = mc[a * 2 + 1];
        return;
      }
    } else if (shape == 2) {
      if (x == 0) {
        if (refA == ref) {
          _mvpX = mc[a * 2];
          _mvpY = mc[a * 2 + 1];
          return;
        }
      } else if (refC == ref) {
        _mvpX = mc[ci * 2];
        _mvpY = mc[ci * 2 + 1];
        return;
      }
    }
    if (refB == -2 && refC == -2 && refA != -2) {
      _mvpX = mc[a * 2];
      _mvpY = mc[a * 2 + 1];
      return;
    }
    final ma = refA == ref, mb = refB == ref, mcm = refC == ref;
    final cnt = (ma ? 1 : 0) + (mb ? 1 : 0) + (mcm ? 1 : 0);
    if (cnt == 1) {
      final s = ma ? a : (mb ? b : ci);
      _mvpX = mc[s * 2];
      _mvpY = mc[s * 2 + 1];
      return;
    }
    final ax = refA < 0 ? 0 : mc[a * 2], ay = refA < 0 ? 0 : mc[a * 2 + 1];
    final bx = refB < 0 ? 0 : mc[b * 2], by = refB < 0 ? 0 : mc[b * 2 + 1];
    final cxv = refC < 0 ? 0 : mc[ci * 2], cyv = refC < 0 ? 0 : mc[ci * 2 + 1];
    _mvpX = _median(ax, bx, cxv);
    _mvpY = _median(ay, by, cyv);
  }

  static int _median(int a, int b, int c) {
    if (a > b) {
      final t = a;
      a = b;
      b = t;
    }
    // now a <= b
    if (c < a) return a;
    if (c > b) return b;
    return c;
  }

  void _setRegion(int list, int x, int y, int w, int h, int ref, int mx, int my) {
    final rc = _refCache[list];
    final mc = _mvCache[list];
    for (var yy = y; yy < y + h; yy++) {
      for (var xx = x; xx < x + w; xx++) {
        final p = _c(xx, yy);
        rc[p] = ref;
        mc[p * 2] = mx;
        mc[p * 2 + 1] = my;
      }
    }
  }

  void _setRefRegion(int list, int x, int y, int w, int h, int ref) {
    final rc = _refCache[list];
    for (var yy = y; yy < y + h; yy++) {
      for (var xx = x; xx < x + w; xx++) {
        rc[_c(xx, yy)] = ref;
      }
    }
  }

  void _setMvdRegion(int list, int x, int y, int w, int h, int ax, int ay) {
    final md = _mvdCache[list];
    for (var yy = y; yy < y + h; yy++) {
      for (var xx = x; xx < x + w; xx++) {
        final p = _c(xx, yy);
        md[p * 2] = ax;
        md[p * 2 + 1] = ay;
      }
    }
  }

  void _decodeSkip() {
    _flags = _fSkip;
    final mb = _mb;
    _fillInterCaches(full: false);
    if (_sliceType == sliceP) {
      final rc = _refCache[0];
      final mc = _mvCache[0];
      final a = _c(-1, 0), b = _c(0, -1);
      int mx = 0, my = 0;
      if (rc[a] == -2 ||
          rc[b] == -2 ||
          (rc[a] == 0 && mc[a * 2] == 0 && mc[a * 2 + 1] == 0) ||
          (rc[b] == 0 && mc[b * 2] == 0 && mc[b * 2 + 1] == 0)) {
        mx = 0;
        my = 0;
      } else {
        _mvPred(0, 0, 0, 4, 0, 0);
        mx = _mvpX;
        my = _mvpY;
      }
      _setRegion(0, 0, 0, 4, 4, 0, mx, my);
      _mbPartShape = 0;
    } else {
      _flags |= _fDirect16;
      _mbPartShape = 3;
      _directAll();
    }
    _mbFlags[mb] = _flags;
    _cbp = 0;
    _lastQpDelta = 0;
    _clearResidualState();
    if (_cabac) _clearMvdTab();
    _storeMbCommon();
    _storeMotion();
    _interPredict();
  }

  void _clearMvdTab() {
    _mvdTab.fillRange(_mb * 32, _mb * 32 + 32, 0);
    if (_numLists > 1) {
      _mvdTab.fillRange((mbCount + _mb) * 32, (mbCount + _mb) * 32 + 32, 0);
    }
  }

  void _decodeInterMb(int mbType) {
    final cab = _cabac;
    _flags = 0;
    _fillInterCaches();
    final isB = _sliceType == sliceB;
    var directMask = 0;
    _p8x8Ref0 = false;
    if (cab) {
      for (var l = 0; l < _numLists; l++) {
        // Interior mvd values default to zero (direct / unused lists).
        final md = _mvdCache[l];
        for (var y = 0; y < 4; y++) {
          for (var x = 0; x < 4; x++) {
            final p = _c(x, y);
            md[p * 2] = 0;
            md[p * 2 + 1] = 0;
          }
        }
      }
    }
    var noSubLt8x8 = true;
    if (!isB) {
      if (mbType <= 2) {
        _mbPartShape = mbType;
        _partPred[0] = 1;
        _partPred[1] = 1;
      } else {
        _mbPartShape = 3;
        _p8x8Ref0 = mbType == 4;
        for (var i = 0; i < 4; i++) {
          final st = cab ? _cabacSubMbTypeP() : _r.ue();
          if (st > 3) throw H264Exception('bad sub_mb_type');
          _subType[i] = st;
          _subDirect[i] = 0;
          if (st != 0) noSubLt8x8 = false;
        }
      }
    } else {
      if (mbType == 0) {
        _flags |= _fDirect16;
        _mbPartShape = 3;
        _directAll();
        directMask = 0xFFFF;
        if (!sps.direct8x8Inference) noSubLt8x8 = false;
      } else if (mbType <= 3) {
        _mbPartShape = 0;
        _partPred[0] = mbType;
      } else if (mbType <= 21) {
        _mbPartShape = (mbType & 1) == 0 ? 1 : 2;
        _partPred[0] = _bPart0[mbType];
        _partPred[1] = _bPart1[mbType];
      } else {
        _mbPartShape = 3;
        var anyDirect = false;
        for (var i = 0; i < 4; i++) {
          final st = cab ? _cabacSubMbTypeB() : _r.ue();
          if (st > 12) throw H264Exception('bad sub_mb_type');
          _subType[i] = st;
          _subDirect[i] = st == 0 ? 1 : 0;
          if (st == 0) {
            anyDirect = true;
            if (!sps.direct8x8Inference) noSubLt8x8 = false;
          } else if (_bSubShape[st] != 0) {
            noSubLt8x8 = false;
          }
        }
        if (anyDirect) {
          _directPrepare();
          for (var i = 0; i < 4; i++) {
            if (_subDirect[i] != 0) {
              _directB8(i);
              final bx = (i & 1) * 2, by = (i >> 1) * 2;
              directMask |= 0x33 << (by * 4 + bx);
              for (var k = 0; k < 4; k++) {
                _directCache[_c(bx + (k & 1), by + (k >> 1))] = 1;
              }
            }
          }
        }
      }
    }
    if (isB && cab) {
      // Interior direct flags for ref_idx contexts.
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          _directCache[_c(x, y)] = (directMask >> (y * 4 + x)) & 1;
        }
      }
    }
    if (mbType != 0 || !isB) {
      if (_mbPartShape == 3) {
        _parseSubMbPred(isB);
      } else {
        _parseMbPred();
      }
    }
    _directTab[_mb] = directMask;
    // coded_block_pattern
    if (cab) {
      _cbp = _cabacCbp();
    } else {
      final v = _r.ue();
      if (v > 47) throw H264Exception('bad cbp');
      _cbp = golombToInterCbp[v];
    }
    if ((_cbp & 15) != 0 && pps.transform8x8Mode && noSubLt8x8) {
      _t8 = (cab ? _cabacTransform8x8() : _r.u1()) != 0;
      if (_t8) _flags |= _fT8;
    }
    _mbFlags[_mb] = _flags;
    _residualAndQp();
    _storeMbCommon();
    if (cab) _storeMvd();
    _storeMotion();
    _interPredict();
    _addLumaResidual();
    _addChromaResidual();
  }

  void _parseMbPred() {
    final cab = _cabac;
    final nParts = _mbPartShape == 0 ? 1 : 2;
    for (var list = 0; list < _numLists; list++) {
      final nRef = list == 0 ? sh.numRefIdxL0 : sh.numRefIdxL1;
      // Partitions not using this list (set first: they are neighbours
      // for the ref_idx contexts of later partitions).
      for (var p = 0; p < nParts; p++) {
        if ((_partPred[p] & (1 << list)) != 0) continue;
        final x = _mbPartShape == 2 ? p * 2 : 0;
        final y = _mbPartShape == 1 ? p * 2 : 0;
        final w = _mbPartShape == 2 ? 2 : 4;
        final h = _mbPartShape == 1 ? 2 : 4;
        _setRegion(list, x, y, w, h, -1, 0, 0);
      }
      for (var p = 0; p < nParts; p++) {
        if ((_partPred[p] & (1 << list)) == 0) continue;
        final x = _mbPartShape == 2 ? p * 2 : 0;
        final y = _mbPartShape == 1 ? p * 2 : 0;
        final w = _mbPartShape == 2 ? 2 : 4;
        final h = _mbPartShape == 1 ? 2 : 4;
        var ref = 0;
        if (nRef > 1) {
          ref = cab ? _cabacRefIdx(list, x, y) : _r.te(nRef - 1);
          if (ref >= nRef) throw H264Exception('ref_idx out of range');
        }
        _setRefRegion(list, x, y, w, h, ref);
      }
    }
    for (var list = 0; list < _numLists; list++) {
      final rc = _refCache[list];
      for (var p = 0; p < nParts; p++) {
        if ((_partPred[p] & (1 << list)) == 0) continue;
        final x = _mbPartShape == 2 ? p * 2 : 0;
        final y = _mbPartShape == 1 ? p * 2 : 0;
        final w = _mbPartShape == 2 ? 2 : 4;
        final h = _mbPartShape == 1 ? 2 : 4;
        final ref = rc[_c(x, y)];
        int dx, dy;
        if (cab) {
          final md = _mvdCache[list];
          final a = _c(x - 1, y), b = _c(x, y - 1);
          dx = _cabacMvd(40, md[a * 2] + md[b * 2]);
          dy = _cabacMvd(47, md[a * 2 + 1] + md[b * 2 + 1]);
          _setMvdRegion(list, x, y, w, h, _absClamp(dx), _absClamp(dy));
        } else {
          dx = _r.se();
          dy = _r.se();
        }
        _mvPred(list, x, y, w, ref, _mbPartShape);
        _setRegion(list, x, y, w, h, ref, _mvpX + dx, _mvpY + dy);
      }
    }
  }

  static int _absClamp(int v) {
    if (v < 0) v = -v;
    return v > 70 ? 70 : v;
  }

  void _parseSubMbPred(bool isB) {
    final cab = _cabac;
    for (var list = 0; list < _numLists; list++) {
      final nRef = list == 0 ? sh.numRefIdxL0 : sh.numRefIdxL1;
      for (var i = 0; i < 4; i++) {
        if (_subDirect[i] != 0) continue;
        final pred = isB ? _bSubPred[_subType[i]] : 1;
        final x = (i & 1) * 2, y = (i >> 1) * 2;
        if ((pred & (1 << list)) == 0) {
          _setRegion(list, x, y, 2, 2, -1, 0, 0);
          continue;
        }
        var ref = 0;
        if (nRef > 1 && !_p8x8Ref0) {
          ref = cab ? _cabacRefIdx(list, x, y) : _r.te(nRef - 1);
          if (ref >= nRef) throw H264Exception('ref_idx out of range');
        }
        _setRefRegion(list, x, y, 2, 2, ref);
      }
    }
    for (var list = 0; list < _numLists; list++) {
      final rc = _refCache[list];
      for (var i = 0; i < 4; i++) {
        if (_subDirect[i] != 0) continue;
        final st = _subType[i];
        final pred = isB ? _bSubPred[st] : 1;
        if ((pred & (1 << list)) == 0) continue;
        final shape = isB ? _bSubShape[st] : st;
        final x0 = (i & 1) * 2, y0 = (i >> 1) * 2;
        final ref = rc[_c(x0, y0)];
        final n = _subCount[shape], sw = _subW[shape], shh = _subH[shape];
        for (var j = 0; j < n; j++) {
          int x, y;
          if (shape == 1) {
            x = x0;
            y = y0 + j;
          } else if (shape == 2) {
            x = x0 + j;
            y = y0;
          } else {
            x = x0 + (j & 1);
            y = y0 + (j >> 1);
          }
          int dx, dy;
          if (cab) {
            final md = _mvdCache[list];
            final a = _c(x - 1, y), b = _c(x, y - 1);
            dx = _cabacMvd(40, md[a * 2] + md[b * 2]);
            dy = _cabacMvd(47, md[a * 2 + 1] + md[b * 2 + 1]);
            _setMvdRegion(list, x, y, sw, shh, _absClamp(dx), _absClamp(dy));
          } else {
            dx = _r.se();
            dy = _r.se();
          }
          _mvPred(list, x, y, sw, ref, 0);
          _setRegion(list, x, y, sw, shh, ref, _mvpX + dx, _mvpY + dy);
        }
      }
    }
  }

  // ------------------------------------------------------------ direct

  void _directAll() {
    if (sh.directSpatial) _directPrepare();
    for (var i = 0; i < 4; i++) {
      _directB8(i);
    }
  }

  static int _minPositive(int a, int b) {
    if (a >= 0 && b >= 0) return a < b ? a : b;
    return a > b ? a : b;
  }

  /// Spatial direct: derive reference indices and predictors (8.4.1.2.2).
  void _directPrepare() {
    if (!sh.directSpatial) return;
    for (var list = 0; list < 2; list++) {
      final rc = _refCache[list];
      final refA = rc[_c(-1, 0)];
      final refB = rc[_c(0, -1)];
      var refC = rc[_c(4, -1)];
      if (refC == -2) refC = rc[_c(-1, -1)];
      var r = _minPositive(refA, _minPositive(refB, refC));
      if (r < 0) r = -1;
      if (list == 0) {
        _dRef0 = r;
      } else {
        _dRef1 = r;
      }
    }
    if (_dRef0 < 0 && _dRef1 < 0) {
      _dRef0 = 0;
      _dRef1 = 0;
      _dMv0x = _dMv0y = _dMv1x = _dMv1y = 0;
      _dZero = true;
      return;
    }
    _dZero = false;
    if (_dRef0 >= 0) {
      _mvPred(0, 0, 0, 4, _dRef0, 0);
      _dMv0x = _mvpX;
      _dMv0y = _mvpY;
    } else {
      _dMv0x = _dMv0y = 0;
    }
    if (_dRef1 >= 0) {
      _mvPred(1, 0, 0, 4, _dRef1, 0);
      _dMv1x = _mvpX;
      _dMv1y = _mvpY;
    } else {
      _dMv1x = _dMv1y = 0;
    }
  }

  bool _dZero = false;

  void _colocated(int rasterBlk) {
    final cp = refList1.isNotEmpty ? refList1[0] : null;
    if (cp == null || cp.nonExisting || cp.mbIntra[_mb] != 0) {
      _colRef = -1;
      _colMvX = 0;
      _colMvY = 0;
      _colUid = -1;
      return;
    }
    final g = _mb * 16 + rasterBlk;
    if (cp.ref0[g] >= 0) {
      _colRef = cp.ref0[g];
      _colMvX = cp.mv0[g * 2];
      _colMvY = cp.mv0[g * 2 + 1];
      _colUid = cp.refId0[g];
    } else {
      _colRef = cp.ref1[g];
      _colMvX = cp.mv1[g * 2];
      _colMvY = cp.mv1[g * 2 + 1];
      _colUid = cp.refId1[g];
    }
  }

  static const List<int> _cornerBlk = [0, 3, 12, 15];

  /// Direct prediction for 8x8 block [b8], storing into the caches.
  void _directB8(int b8) {
    final bx = (b8 & 1) * 2, by = (b8 >> 1) * 2;
    final infer = sps.direct8x8Inference;
    if (sh.directSpatial) {
      if (_dZero) {
        _setRegion(0, bx, by, 2, 2, 0, 0, 0);
        _setRegion(1, bx, by, 2, 2, 0, 0, 0);
        return;
      }
      final colShort = refList1.isNotEmpty && refLong1[0] == 0;
      // With direct_8x8_inference the whole 8x8 block shares one co-located
      // 4x4 block (a corner), so it is filled as a single region.
      final n = infer ? 1 : 4;
      final sz = infer ? 2 : 1;
      for (var k = 0; k < n; k++) {
        final x = bx + (k & 1), y = by + (k >> 1);
        _colocated(infer ? _cornerBlk[b8] : y * 4 + x);
        final colZero =
            colShort &&
            _colRef == 0 &&
            _colMvX >= -1 &&
            _colMvX <= 1 &&
            _colMvY >= -1 &&
            _colMvY <= 1;
        if (_dRef0 < 0) {
          _setRegion(0, x, y, sz, sz, -1, 0, 0);
        } else if (_dRef0 == 0 && colZero) {
          _setRegion(0, x, y, sz, sz, 0, 0, 0);
        } else {
          _setRegion(0, x, y, sz, sz, _dRef0, _dMv0x, _dMv0y);
        }
        if (_dRef1 < 0) {
          _setRegion(1, x, y, sz, sz, -1, 0, 0);
        } else if (_dRef1 == 0 && colZero) {
          _setRegion(1, x, y, sz, sz, 0, 0, 0);
        } else {
          _setRegion(1, x, y, sz, sz, _dRef1, _dMv1x, _dMv1y);
        }
      }
    } else {
      final n = infer ? 1 : 4;
      final sz = infer ? 2 : 1;
      for (var k = 0; k < n; k++) {
        final x = bx + (k & 1), y = by + (k >> 1);
        _colocated(infer ? _cornerBlk[b8] : y * 4 + x);
        var ref0 = 0;
        var mvx = _colMvX, mvy = _colMvY;
        if (_colRef < 0) {
          mvx = 0;
          mvy = 0;
        } else {
          final n0 = sh.numRefIdxL0;
          ref0 = -1;
          for (var i = 0; i < n0; i++) {
            if (_refUid0[i] == _colUid) {
              ref0 = i;
              break;
            }
          }
          if (ref0 < 0) ref0 = 0;
        }
        int m0x, m0y, m1x, m1y;
        if (_dsfCopy[ref0] != 0) {
          m0x = mvx;
          m0y = mvy;
          m1x = 0;
          m1y = 0;
        } else {
          final dsf = _dsf[ref0];
          m0x = asr(dsf * mvx + 128, 8);
          m0y = asr(dsf * mvy + 128, 8);
          m1x = m0x - mvx;
          m1y = m0y - mvy;
        }
        _setRegion(0, x, y, sz, sz, ref0, m0x, m0y);
        _setRegion(1, x, y, sz, sz, 0, m1x, m1y);
      }
    }
  }

  // ------------------------------------------------------------ storage

  void _storeMotion() {
    final pic = cur;
    final base = _mb * 16;
    pic.mbIntra[_mb] = 0;
    for (var list = 0; list < 2; list++) {
      final refs = list == 0 ? pic.ref0 : pic.ref1;
      final ids = list == 0 ? pic.refId0 : pic.refId1;
      final mvs = list == 0 ? pic.mv0 : pic.mv1;
      if (list >= _numLists) {
        for (var i = 0; i < 16; i++) {
          refs[base + i] = -1;
          ids[base + i] = -1;
        }
        mvs.fillRange(base * 2, base * 2 + 32, 0);
        continue;
      }
      final rc = _refCache[list];
      final mc = _mvCache[list];
      final uids = list == 0 ? _refUid0 : _refUid1;
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          final p = _c(x, y);
          final i = base + y * 4 + x;
          final r = rc[p];
          refs[i] = r;
          ids[i] = r >= 0 ? uids[r] : -1;
          mvs[i * 2] = mc[p * 2];
          mvs[i * 2 + 1] = mc[p * 2 + 1];
        }
      }
    }
    _directTab[_mb] = (_flags & _fDirect16) != 0 ? 0xFFFF : _directTab[_mb];
  }

  void _storeMvd() {
    for (var list = 0; list < _numLists; list++) {
      final md = _mvdCache[list];
      final base = (list * mbCount + _mb) * 32;
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          final p = _c(x, y);
          _mvdTab[base + (y * 4 + x) * 2] = md[p * 2];
          _mvdTab[base + (y * 4 + x) * 2 + 1] = md[p * 2 + 1];
        }
      }
    }
  }

  // ------------------------------------------------------------ inter pred

  final Uint8List _pl0 = Uint8List(256);
  final Uint8List _pl1 = Uint8List(256);
  final Uint8List _pc0 = Uint8List(64);
  final Uint8List _pc1 = Uint8List(64);

  void _interPredict() {
    switch (_mbPartShape) {
      case 0:
        info.uniform[_mb] = 1;
        _mcRegion(0, 0, 4, 4);
        return;
      case 1:
        _mcRegion(0, 0, 4, 2);
        _mcRegion(0, 2, 4, 2);
        return;
      case 2:
        _mcRegion(0, 0, 2, 4);
        _mcRegion(2, 0, 2, 4);
        return;
    }
    // 8x8 (also direct macroblocks): merge identical regions when possible.
    if (_uniform(0, 0, 4, 4)) {
      info.uniform[_mb] = 1;
      _mcRegion(0, 0, 4, 4);
      return;
    }
    for (var b8 = 0; b8 < 4; b8++) {
      final x0 = (b8 & 1) * 2, y0 = (b8 >> 1) * 2;
      if (_uniform(x0, y0, 2, 2)) {
        _mcRegion(x0, y0, 2, 2);
        continue;
      }
      // Use the declared sub partitioning when not direct; for direct use
      // 4x4 blocks.
      var shape = 3;
      if ((_flags & _fDirect16) == 0 && _subDirect[b8] == 0) {
        shape = _sliceType == sliceB ? _bSubShape[_subType[b8]] : _subType[b8];
      }
      switch (shape) {
        case 1:
          _mcRegion(x0, y0, 2, 1);
          _mcRegion(x0, y0 + 1, 2, 1);
          break;
        case 2:
          _mcRegion(x0, y0, 1, 2);
          _mcRegion(x0 + 1, y0, 1, 2);
          break;
        default:
          _mcRegion(x0, y0, 1, 1);
          _mcRegion(x0 + 1, y0, 1, 1);
          _mcRegion(x0, y0 + 1, 1, 1);
          _mcRegion(x0 + 1, y0 + 1, 1, 1);
      }
    }
  }

  bool _uniform(int x0, int y0, int w, int h) {
    final p0 = _c(x0, y0);
    for (var list = 0; list < _numLists; list++) {
      final rc = _refCache[list];
      final mc = _mvCache[list];
      final r = rc[p0], mx = mc[p0 * 2], my = mc[p0 * 2 + 1];
      for (var y = y0; y < y0 + h; y++) {
        for (var x = x0; x < x0 + w; x++) {
          final p = _c(x, y);
          if (rc[p] != r || mc[p * 2] != mx || mc[p * 2 + 1] != my) return false;
        }
      }
    }
    return true;
  }

  Picture? _refPic(int list, int ref) {
    final l = list == 0 ? refList0 : refList1;
    if (ref < 0 || ref >= l.length) return l.isNotEmpty ? l[0] : null;
    return l[ref];
  }

  void _mcRegion(int x, int y, int w, int h) {
    final p = _c(x, y);
    final r0 = _refCache[0][p];
    final r1 = _numLists > 1 ? _refCache[1][p] : -1;
    final pic = cur;
    final pw = pic.width, ph = pic.height;
    final cw = pw >> 1, chh = ph >> 1;
    final px = _mbX * 16 + x * 4, py = _mbY * 16 + y * 4;
    final bw = w * 4, bh = h * 4;
    final lOff = py * pw + px;
    final cOff = (py >> 1) * cw + (px >> 1);
    final cbw = bw >> 1, cbh = bh >> 1;
    if (r0 < 0 && r1 < 0) return;
    final bi = r0 >= 0 && r1 >= 0;
    if (!bi) {
      final list = r0 >= 0 ? 0 : 1;
      final ref = r0 >= 0 ? r0 : r1;
      final rp = _refPic(list, ref);
      if (rp == null) return;
      final mc = _mvCache[list];
      final mx = mc[p * 2], my = mc[p * 2 + 1];
      if (_wMode != 1) {
        inter.luma(
          rp.y,
          pw,
          ph,
          px + asr(mx, 2),
          py + asr(my, 2),
          mx & 3,
          my & 3,
          bw,
          bh,
          pic.y,
          lOff,
          pw,
        );
        final cx = (px >> 1) + asr(mx, 3), cy = (py >> 1) + asr(my, 3);
        inter.chroma(rp.u, cw, chh, cx, cy, mx & 7, my & 7, cbw, cbh, pic.u, cOff, cw);
        inter.chroma(rp.v, cw, chh, cx, cy, mx & 7, my & 7, cbw, cbh, pic.v, cOff, cw);
        return;
      }
      // Explicit weighted single-list prediction.
      final k = list * 32 + ref;
      inter.luma(rp.y, pw, ph, px + asr(mx, 2), py + asr(my, 2), mx & 3, my & 3, bw, bh, _pl0, 0, 16);
      _weight1(
        _pl0,
        16,
        pic.y,
        lOff,
        pw,
        bw,
        bh,
        sh.lumaWeight[k],
        sh.lumaOffset[k],
        sh.lumaLog2Denom,
      );
      final cx = (px >> 1) + asr(mx, 3), cy = (py >> 1) + asr(my, 3);
      inter.chroma(rp.u, cw, chh, cx, cy, mx & 7, my & 7, cbw, cbh, _pc0, 0, 8);
      _weight1(
        _pc0,
        8,
        pic.u,
        cOff,
        cw,
        cbw,
        cbh,
        sh.chromaWeight[k * 2],
        sh.chromaOffset[k * 2],
        sh.chromaLog2Denom,
      );
      inter.chroma(rp.v, cw, chh, cx, cy, mx & 7, my & 7, cbw, cbh, _pc0, 0, 8);
      _weight1(
        _pc0,
        8,
        pic.v,
        cOff,
        cw,
        cbw,
        cbh,
        sh.chromaWeight[k * 2 + 1],
        sh.chromaOffset[k * 2 + 1],
        sh.chromaLog2Denom,
      );
      return;
    }
    final rp0 = _refPic(0, r0), rp1 = _refPic(1, r1);
    if (rp0 == null || rp1 == null) return;
    final m0 = _mvCache[0], m1 = _mvCache[1];
    final mx0 = m0[p * 2], my0 = m0[p * 2 + 1];
    final mx1 = m1[p * 2], my1 = m1[p * 2 + 1];
    inter.luma(
      rp0.y,
      pw,
      ph,
      px + asr(mx0, 2),
      py + asr(my0, 2),
      mx0 & 3,
      my0 & 3,
      bw,
      bh,
      _pl0,
      0,
      16,
    );
    inter.luma(
      rp1.y,
      pw,
      ph,
      px + asr(mx1, 2),
      py + asr(my1, 2),
      mx1 & 3,
      my1 & 3,
      bw,
      bh,
      _pl1,
      0,
      16,
    );
    final c0x = (px >> 1) + asr(mx0, 3), c0y = (py >> 1) + asr(my0, 3);
    final c1x = (px >> 1) + asr(mx1, 3), c1y = (py >> 1) + asr(my1, 3);
    if (_wMode == 0) {
      _avg2(_pl0, _pl1, 16, pic.y, lOff, pw, bw, bh);
      inter.chroma(rp0.u, cw, chh, c0x, c0y, mx0 & 7, my0 & 7, cbw, cbh, _pc0, 0, 8);
      inter.chroma(rp1.u, cw, chh, c1x, c1y, mx1 & 7, my1 & 7, cbw, cbh, _pc1, 0, 8);
      _avg2(_pc0, _pc1, 8, pic.u, cOff, cw, cbw, cbh);
      inter.chroma(rp0.v, cw, chh, c0x, c0y, mx0 & 7, my0 & 7, cbw, cbh, _pc0, 0, 8);
      inter.chroma(rp1.v, cw, chh, c1x, c1y, mx1 & 7, my1 & 7, cbw, cbh, _pc1, 0, 8);
      _avg2(_pc0, _pc1, 8, pic.v, cOff, cw, cbw, cbh);
      return;
    }
    int lw0, lw1, lo0, lo1, ld;
    int cw0u, cw1u, co0u, co1u, cw0v, cw1v, co0v, co1v, cd;
    if (_wMode == 1) {
      final k0 = r0, k1 = 32 + r1;
      lw0 = sh.lumaWeight[k0];
      lw1 = sh.lumaWeight[k1];
      lo0 = sh.lumaOffset[k0];
      lo1 = sh.lumaOffset[k1];
      ld = sh.lumaLog2Denom;
      cw0u = sh.chromaWeight[k0 * 2];
      cw1u = sh.chromaWeight[k1 * 2];
      co0u = sh.chromaOffset[k0 * 2];
      co1u = sh.chromaOffset[k1 * 2];
      cw0v = sh.chromaWeight[k0 * 2 + 1];
      cw1v = sh.chromaWeight[k1 * 2 + 1];
      co0v = sh.chromaOffset[k0 * 2 + 1];
      co1v = sh.chromaOffset[k1 * 2 + 1];
      cd = sh.chromaLog2Denom;
    } else {
      final w1 = _implicitW1[r0 * 32 + r1];
      lw0 = 64 - w1;
      lw1 = w1;
      lo0 = lo1 = 0;
      ld = 5;
      cw0u = cw0v = lw0;
      cw1u = cw1v = lw1;
      co0u = co1u = co0v = co1v = 0;
      cd = 5;
    }
    _weight2(_pl0, _pl1, 16, pic.y, lOff, pw, bw, bh, lw0, lw1, lo0, lo1, ld);
    inter.chroma(rp0.u, cw, chh, c0x, c0y, mx0 & 7, my0 & 7, cbw, cbh, _pc0, 0, 8);
    inter.chroma(rp1.u, cw, chh, c1x, c1y, mx1 & 7, my1 & 7, cbw, cbh, _pc1, 0, 8);
    _weight2(_pc0, _pc1, 8, pic.u, cOff, cw, cbw, cbh, cw0u, cw1u, co0u, co1u, cd);
    inter.chroma(rp0.v, cw, chh, c0x, c0y, mx0 & 7, my0 & 7, cbw, cbh, _pc0, 0, 8);
    inter.chroma(rp1.v, cw, chh, c1x, c1y, mx1 & 7, my1 & 7, cbw, cbh, _pc1, 0, 8);
    _weight2(_pc0, _pc1, 8, pic.v, cOff, cw, cbw, cbh, cw0v, cw1v, co0v, co1v, cd);
  }

  static void _avg2(
    Uint8List a,
    Uint8List b,
    int st,
    Uint8List d,
    int dOff,
    int dSt,
    int w,
    int h,
  ) {
    for (var y = 0; y < h; y++) {
      final so = y * st, dO = dOff + y * dSt;
      for (var x = 0; x < w; x++) {
        d[dO + x] = (a[so + x] + b[so + x] + 1) >> 1;
      }
    }
  }

  static void _weight1(
    Uint8List a,
    int st,
    Uint8List d,
    int dOff,
    int dSt,
    int w,
    int h,
    int wt,
    int o,
    int logWD,
  ) {
    if (logWD >= 1) {
      final rnd = 1 << (logWD - 1);
      for (var y = 0; y < h; y++) {
        final so = y * st, dO = dOff + y * dSt;
        for (var x = 0; x < w; x++) {
          final v = asr(a[so + x] * wt + rnd, logWD) + o;
          d[dO + x] = v < 0 ? 0 : (v > 255 ? 255 : v);
        }
      }
    } else {
      for (var y = 0; y < h; y++) {
        final so = y * st, dO = dOff + y * dSt;
        for (var x = 0; x < w; x++) {
          final v = a[so + x] * wt + o;
          d[dO + x] = v < 0 ? 0 : (v > 255 ? 255 : v);
        }
      }
    }
  }

  static void _weight2(
    Uint8List a,
    Uint8List b,
    int st,
    Uint8List d,
    int dOff,
    int dSt,
    int w,
    int h,
    int w0,
    int w1,
    int o0,
    int o1,
    int logWD,
  ) {
    final rnd = 1 << logWD;
    final o = asr(o0 + o1 + 1, 1);
    final sh = logWD + 1;
    for (var y = 0; y < h; y++) {
      final so = y * st, dO = dOff + y * dSt;
      for (var x = 0; x < w; x++) {
        final v = asr(a[so + x] * w0 + b[so + x] * w1 + rnd, sh) + o;
        d[dO + x] = v < 0 ? 0 : (v > 255 ? 255 : v);
      }
    }
  }
}
