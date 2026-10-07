import 'dart:typed_data';

/// Thrown for malformed or undecodable H.264 data. Unsupported (but valid)
/// stream features raise [UnsupportedError] instead.
class H264Exception implements Exception {
  H264Exception(this.message);
  final String message;
  @override
  String toString() => 'H264Exception: $message';
}

/// Removes emulation prevention bytes (00 00 03) from a NAL unit payload and
/// returns the RBSP followed by 8 zero bytes of padding, so readers can fetch
/// a few bytes past the end without bounds checks.
Uint8List nalToRbsp(Uint8List nal, int start) {
  final n = nal.length;
  final out = Uint8List(n - start + 8);
  var o = 0;
  var zeros = 0;
  for (var i = start; i < n; i++) {
    final b = nal[i];
    if (zeros >= 2 && b == 3) {
      // Skip the emulation prevention byte.
      zeros = 0;
      continue;
    }
    out[o++] = b;
    if (b == 0) {
      zeros++;
    } else {
      zeros = 0;
    }
  }
  return Uint8List.sublistView(out, 0, o + 8);
}

/// MSB-first bit reader over an RBSP produced by [nalToRbsp].
class BitReader {
  BitReader(this.data) : bitLength = (data.length - 8) * 8;

  final Uint8List data;

  /// Number of valid payload bits (excluding the padding).
  final int bitLength;
  int pos = 0;

  bool get byteAligned => (pos & 7) == 0;
  int get bitsLeft => bitLength - pos;

  /// The bits from bit offset [k] of byte [p] onwards, as a right-aligned
  /// value of (31 - k) bits. Uses only 31-bit intermediates so the result is
  /// identical with 32-bit (web) integer semantics.
  int _win31(int p, int k) =>
      ((data[p] & (0xFF >> k)) << 23) |
      (data[p + 1] << 15) |
      (data[p + 2] << 7) |
      (data[p + 3] >> 1);

  /// Reads up to 24 bits.
  int u(int n) {
    if (n == 0) return 0;
    final p = pos >> 3;
    if (p + 4 > data.length) throw H264Exception('read past end');
    final k = pos & 7;
    pos += n;
    return _win31(p, k) >> (31 - k - n);
  }

  /// Reads up to 32 bits.
  int uLong(int n) {
    if (n <= 24) return u(n);
    final hi = u(n - 16);
    return hi * 65536 + u(16);
  }

  int u1() {
    final p = pos >> 3;
    if (p >= data.length) throw H264Exception('read past end');
    final v = (data[p] >> (7 - (pos & 7))) & 1;
    pos++;
    return v;
  }

  bool flag() => u1() != 0;

  /// Peeks up to 24 bits without advancing.
  int peek(int n) {
    final p = pos >> 3;
    if (p + 4 > data.length) return 0;
    final k = pos & 7;
    return _win31(p, k) >> (31 - k - n);
  }

  void skip(int n) => pos += n;

  /// Unsigned Exp-Golomb.
  int ue() {
    final p = pos >> 3;
    if (p + 4 <= data.length) {
      final k = pos & 7;
      final avail = 31 - k;
      final w = _win31(p, k);
      if (w != 0) {
        final lz = avail - w.bitLength;
        final len = 2 * lz + 1;
        if (len <= avail) {
          pos += len;
          return (w >> (avail - len)) - 1;
        }
      }
    }
    var lz = 0;
    while (u1() == 0) {
      lz++;
      if (lz > 30) throw H264Exception('invalid exp-golomb code');
    }
    if (lz == 0) return 0;
    return (1 << lz) - 1 + uLong(lz);
  }

  /// Signed Exp-Golomb.
  int se() {
    final k = ue();
    return (k & 1) != 0 ? (k + 1) >> 1 : -(k >> 1);
  }

  /// Truncated Exp-Golomb with range [0, max].
  int te(int max) {
    if (max > 1) return ue();
    return 1 - u1();
  }

  int _stopBit = -2;

  /// Bit position of the rbsp_stop_one_bit (-1 if none).
  int get stopBitPos {
    if (_stopBit != -2) return _stopBit;
    var last = (data.length - 8) - 1;
    while (last >= 0 && data[last] == 0) {
      last--;
    }
    if (last < 0) {
      _stopBit = -1;
    } else {
      final b = data[last];
      var tz = 0;
      while (((b >> tz) & 1) == 0) {
        tz++;
      }
      _stopBit = last * 8 + (7 - tz);
    }
    return _stopBit;
  }

  /// True if more RBSP data remains before the rbsp_trailing_bits.
  bool moreRbspData() => pos < stopBitPos;
}
