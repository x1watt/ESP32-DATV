import 'dart:typed_data';

/// MSB-first bit writer producing an RBSP. All shifts stay within 32 bits so
/// the code behaves identically when compiled to JavaScript.
class BitWriter {
  Uint8List _buf = Uint8List(16384);
  int _len = 0;
  int _acc = 0;
  int _nacc = 0;

  void reset() {
    _len = 0;
    _acc = 0;
    _nacc = 0;
  }

  /// Number of bits written so far.
  int get bitCount => (_len << 3) + _nacc;

  bool get byteAligned => _nacc == 0;

  int _mLen = 0, _mAcc = 0, _mNacc = 0;

  /// Remembers the current position for [rollback].
  void mark() {
    _mLen = _len;
    _mAcc = _acc;
    _mNacc = _nacc;
  }

  /// Discards everything written since the last [mark].
  void rollback() {
    _len = _mLen;
    _acc = _mAcc;
    _nacc = _mNacc;
  }

  void _grow(int need) {
    var n = _buf.length * 2;
    while (n < need) {
      n *= 2;
    }
    final b = Uint8List(n);
    b.setRange(0, _len, _buf);
    _buf = b;
  }

  /// Writes the low [n] bits of [v] (n <= 24).
  void bits(int n, int v) {
    if (n == 0) return;
    if (_len + 4 > _buf.length) _grow(_len + 4);
    var acc = (_acc << n) | v;
    var nacc = _nacc + n;
    while (nacc >= 8) {
      nacc -= 8;
      _buf[_len++] = (acc >> nacc) & 0xFF;
    }
    _acc = acc & ((1 << nacc) - 1);
    _nacc = nacc;
  }

  /// Writes a 32-bit unsigned value.
  void u32(int v) {
    bits(16, (v >> 16) & 0xFFFF);
    bits(16, v & 0xFFFF);
  }

  void flag(bool b) => bits(1, b ? 1 : 0);

  /// Unsigned Exp-Golomb ue(v).
  void ue(int v) {
    final x = v + 1;
    final len = x.bitLength;
    final zeros = len - 1;
    if (zeros + len <= 24) {
      bits(zeros + len, x);
    } else {
      bits(zeros, 0);
      if (len > 24) {
        bits(len - 16, x >> 16);
        bits(16, x & 0xFFFF);
      } else {
        bits(len, x);
      }
    }
  }

  /// Signed Exp-Golomb se(v).
  void se(int v) => ue(v > 0 ? 2 * v - 1 : -2 * v);

  /// rbsp_trailing_bits: stop bit and zero alignment.
  void trailing() {
    bits(1, 1);
    if (_nacc > 0) bits(8 - _nacc, 0);
  }

  /// The written RBSP bytes (must be byte aligned).
  Uint8List get buffer => _buf;
  int get lengthBytes => _len;
}

/// Growable byte sink for an Annex B access unit.
class ByteSink {
  Uint8List _buf = Uint8List(65536);
  int length = 0;

  void reset() => length = 0;

  void _ensure(int extra) {
    if (length + extra <= _buf.length) return;
    var n = _buf.length * 2;
    while (n < length + extra) {
      n *= 2;
    }
    final b = Uint8List(n);
    b.setRange(0, length, _buf);
    _buf = b;
  }

  /// Appends a NAL unit with start code and emulation prevention.
  /// [longStart] selects the 4-byte start code (zero_byte present).
  void nal(int nalRefIdc, int nalType, BitWriter rbsp, {bool longStart = true}) {
    final src = rbsp.buffer;
    final n = rbsp.lengthBytes;
    // Worst case: one extra byte per two payload bytes.
    _ensure(n + (n >> 1) + 8);
    final b = _buf;
    var o = length;
    if (longStart) b[o++] = 0;
    b[o++] = 0;
    b[o++] = 0;
    b[o++] = 1;
    b[o++] = (nalRefIdc << 5) | nalType;
    var zeros = 0;
    for (var i = 0; i < n; i++) {
      final v = src[i];
      if (zeros >= 2 && v <= 3) {
        b[o++] = 3;
        zeros = 0;
      }
      b[o++] = v;
      if (v == 0) {
        zeros++;
      } else {
        zeros = 0;
      }
    }
    length = o;
  }

  Uint8List toBytes() => Uint8List.fromList(Uint8List.sublistView(_buf, 0, length));
}
