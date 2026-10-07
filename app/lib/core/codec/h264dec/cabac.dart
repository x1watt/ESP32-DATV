import 'dart:typed_data';

import 'int_util.dart';
import 'tables_gen.dart';

/// Number of CABAC contexts used for 4:2:0 frame coding.
const int numCabacContexts = 460;

/// Packed state (pStateIdx << 1 | valMPS) transition tables.
final Uint8List _nextMps = () {
  final t = Uint8List(128);
  for (var s = 0; s < 64; s++) {
    final n = s < 62 ? s + 1 : s;
    t[s * 2] = n * 2;
    t[s * 2 + 1] = n * 2 + 1;
  }
  return t;
}();

final Uint8List _nextLps = () {
  final t = Uint8List(128);
  for (var s = 0; s < 64; s++) {
    final n = transIdxLps[s];
    for (var mps = 0; mps < 2; mps++) {
      final newMps = s == 0 ? 1 - mps : mps;
      t[s * 2 + mps] = n * 2 + newMps;
    }
  }
  return t;
}();

/// rangeTabLPS indexed by (packed >> 1) * 4 + qIdx.
final Uint8List _rangeLps = rangeTabLps;

final Uint8List _normShift = () {
  final t = Uint8List(512);
  for (var i = 1; i < 512; i++) {
    var s = 0;
    while ((i << s) < 256) {
      s++;
    }
    t[i] = s;
  }
  return t;
}();

/// CABAC arithmetic decoding engine (9.3.1.2, 9.3.3.2).
///
/// The offset register is kept as `value = codIOffset << bits | prefetched`
/// so renormalisation only adjusts [bits]; bytes are fetched 16 bits at a
/// time. All quantities stay below 2^25 (safe for 32-bit targets).
class Cabac {
  final Uint8List state = Uint8List(numCabacContexts);
  Uint8List _data = Uint8List(8);
  int _pos = 0;
  int _start = 0;
  int _range = 510;
  int _value = 0;
  int _bits = 0;

  int _byte(int p) => p < _data.length ? _data[p] : 0;

  /// Initialises the engine at byte [bytePos] of [data].
  void initEngine(Uint8List data, int bytePos) {
    _data = data;
    _start = bytePos;
    _pos = bytePos + 3;
    _value = (_byte(bytePos) << 16) | (_byte(bytePos + 1) << 8) | _byte(bytePos + 2);
    _bits = 15;
    _range = 510;
  }

  /// Initialises all context variables (9.3.1.1).
  void initContexts(int sliceType, int cabacInitIdc, int qp) {
    final Int8List tab;
    var base = 0;
    if (sliceType == 2) {
      tab = cabacInitI;
    } else {
      tab = cabacInitPB;
      base = cabacInitIdc * numCabacContexts * 2;
    }
    final q = qp < 0 ? 0 : (qp > 51 ? 51 : qp);
    for (var i = 0; i < numCabacContexts; i++) {
      final m = tab[base + i * 2];
      final n = tab[base + i * 2 + 1];
      var pre = asr(m * q, 4) + n;
      if (pre < 1) pre = 1;
      if (pre > 126) pre = 126;
      state[i] = pre <= 63 ? (63 - pre) << 1 : ((pre - 64) << 1) | 1;
    }
  }

  void _refill() {
    _value = (_value << 16) | (_byte(_pos) << 8) | _byte(_pos + 1);
    _pos += 2;
    _bits += 16;
  }

  /// DecodeDecision for context [ctx].
  int decision(int ctx) {
    final s = state[ctx];
    final lps = _rangeLps[((s >> 1) << 2) + ((_range >> 6) & 3)];
    final r = _range - lps;
    final scaled = r << _bits;
    if (_value < scaled) {
      state[ctx] = _nextMps[s];
      if (r < 256) {
        _range = r << 1;
        if (--_bits < 0) _refill();
      } else {
        _range = r;
      }
      return s & 1;
    } else {
      _value -= scaled;
      state[ctx] = _nextLps[s];
      final sh = _normShift[lps];
      _range = lps << sh;
      _bits -= sh;
      if (_bits < 0) _refill();
      return (s & 1) ^ 1;
    }
  }

  /// DecodeBypass.
  int bypass() {
    if (--_bits < 0) _refill();
    final scaled = _range << _bits;
    if (_value >= scaled) {
      _value -= scaled;
      return 1;
    }
    return 0;
  }

  /// DecodeTerminate.
  int terminate() {
    _range -= 2;
    final scaled = _range << _bits;
    if (_value >= scaled) return 1;
    if (_range < 256) {
      _range <<= 1;
      if (--_bits < 0) _refill();
    }
    return 0;
  }

  /// Byte position of the first byte after the CABAC data consumed so far
  /// (used for I_PCM samples after a terminate bin equal to 1).
  int alignedBytePos() {
    final consumedBits = (_pos - _start) * 8 - _bits;
    return _start + ((consumedBits + 7) >> 3);
  }

  /// True if the decoder has read well past the end of the slice data.
  bool get overrun => _pos > _data.length + 16;
}
