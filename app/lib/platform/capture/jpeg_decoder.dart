/// A small baseline JPEG decoder for webcam MJPEG frames, straight to I420 (no RGB step).
///
/// Supports 8-bit sequential Huffman JPEG with any sampling factors (4:2:2 and 4:2:0 being
/// the webcam norm), restart markers, and frames without DHT (MJPEG streams that rely on
/// the standard tables). Progressive and arithmetic-coded JPEG return null. The integer
/// IDCT is the one of stb_image (public domain), which matches libjpeg's islow closely.
library;

import 'dart:typed_data';

class JpegPicture {
  JpegPicture(this.data, this.width, this.height);

  /// Tightly packed I420.
  final Uint8List data;
  final int width, height;
}

const List<int> _dezigzag = [
  0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, //
  28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, //
  54, 47, 55, 62, 63,
];

// Standard tables of ITU T.81 Annex K.3.
const List<int> _dcLumBits = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0];
const List<int> _dcChromBits = [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0];
const List<int> _dcVals = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
const List<int> _acLumBits = [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d];
const List<int> _acLumVals = [
  0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07, //
  0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0, //
  0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28, //
  0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, //
  0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, //
  0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, //
  0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, //
  0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5, //
  0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2, //
  0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, //
  0xf9, 0xfa,
];
const List<int> _acChromBits = [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77];
const List<int> _acChromVals = [
  0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71, //
  0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0, //
  0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26, //
  0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, //
  0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, //
  0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, //
  0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, //
  0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, //
  0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, //
  0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, //
  0xf9, 0xfa,
];

/// Lengths of the standard tables, exposed for a sanity test.
List<int> get jpegStandardTableSizes => [_acLumVals.length, _acChromVals.length, _dcVals.length];

const int _fastBits = 9;

class _Huff {
  _Huff(List<int> bits, List<int> vals) {
    var k = 0;
    for (var i = 0; i < 16; i++) {
      for (var j = 0; j < bits[i]; j++) {
        size[k++] = i + 1;
      }
    }
    size[k] = 0;
    var code = 0;
    k = 0;
    for (var j = 1; j <= 16; j++) {
      delta[j] = k - code;
      while (size[k] == j) {
        codes[k++] = code++;
      }
      maxcode[j] = code << (16 - j);
      code <<= 1;
    }
    maxcode[17] = 0x7fffffff;
    values.setRange(0, vals.length, vals);
    fast.fillRange(0, fast.length, 255);
    for (var i = 0; i < k; i++) {
      final s = size[i];
      if (s <= _fastBits) {
        final c = codes[i] << (_fastBits - s);
        final m = 1 << (_fastBits - s);
        for (var j = 0; j < m; j++) {
          fast[c + j] = i;
        }
      }
    }
  }

  final Uint8List fast = Uint8List(1 << _fastBits);
  final Int32List codes = Int32List(256);
  final Uint8List values = Uint8List(256);
  final Uint8List size = Uint8List(257);
  final Int32List maxcode = Int32List(18);
  final Int32List delta = Int32List(17);
}

class _Comp {
  _Comp(this.id, this.h, this.v, this.tq);
  final int id, h, v, tq;
  int td = 0, ta = 0, pred = 0;
  late int bw, bh; // plane size in pixels (multiple of 8)
  late Uint8List plane;
}

class _Fail implements Exception {}

class JpegDecoder {
  final List<Int32List> _q = List.generate(4, (_) => Int32List(64));
  final List<_Huff?> _dc = List.filled(4, null), _ac = List.filled(4, null);
  final Int32List _blk = Int32List(64);
  final Int32List _tmp = Int32List(64);

  late Uint8List _d;
  int _pos = 0;
  int _buf = 0, _bits = 0;
  int _marker = 0; // pending marker hit inside entropy data, 0 when none

  /// Decodes [jpg] to I420. Returns null when the frame is broken or unsupported.
  JpegPicture? decodeI420(Uint8List jpg) {
    try {
      return _decode(jpg);
    } on _Fail {
      return null;
    } on RangeError {
      return null;
    }
  }

  int _u16(int p) => _d[p] << 8 | _d[p + 1];

  JpegPicture? _decode(Uint8List jpg) {
    _d = jpg;
    _planesReady = false;
    if (jpg.length < 4 || jpg[0] != 0xFF || jpg[1] != 0xD8) return null;
    // MJPEG frames often omit DHT: start from the standard tables every frame
    _dc[0] = _stdDcL;
    _dc[1] = _stdDcC;
    _ac[0] = _stdAcL;
    _ac[1] = _stdAcC;
    var p = 2;
    var width = 0, height = 0, restart = 0;
    final comps = <_Comp>[];
    while (p < jpg.length - 1) {
      if (jpg[p] != 0xFF) {
        p++;
        continue;
      }
      final m = jpg[p + 1];
      p += 2;
      if (m == 0xFF || m == 0x01 || (m >= 0xD0 && m <= 0xD7)) {
        if (m == 0xFF) p--;
        continue;
      }
      if (m == 0xD9) break;
      final len = _u16(p);
      final end = p + len;
      switch (m) {
        case 0xDB:
          var q = p + 2;
          while (q < end) {
            final pq = jpg[q] >> 4, tq = jpg[q] & 3;
            q++;
            final t = _q[tq];
            for (var i = 0; i < 64; i++) {
              t[i] = pq == 0 ? jpg[q + i] : _u16(q + 2 * i);
            }
            q += pq == 0 ? 64 : 128;
          }
        case 0xC4:
          var q = p + 2;
          while (q < end) {
            final tc = jpg[q] >> 4, th = jpg[q] & 3;
            final bits = jpg.sublist(q + 1, q + 17);
            var n = 0;
            for (final b in bits) {
              n += b;
            }
            if (n > 256) throw _Fail();
            final vals = jpg.sublist(q + 17, q + 17 + n);
            final h = _Huff(bits, vals);
            if (tc == 0) {
              _dc[th] = h;
            } else {
              _ac[th] = h;
            }
            q += 17 + n;
          }
        case 0xC0:
        case 0xC1:
          if (jpg[p + 2] != 8) return null;
          height = _u16(p + 3);
          width = _u16(p + 5);
          final nc = jpg[p + 7];
          comps.clear();
          for (var i = 0; i < nc; i++) {
            final b = p + 8 + 3 * i;
            comps.add(_Comp(jpg[b], jpg[b + 1] >> 4, jpg[b + 1] & 15, jpg[b + 2] & 3));
          }
        case 0xC2:
        case 0xC3:
        case 0xC5:
        case 0xC6:
        case 0xC7:
        case 0xC9:
        case 0xCA:
        case 0xCB:
        case 0xCD:
        case 0xCE:
        case 0xCF:
          return null; // progressive, lossless or arithmetic
        case 0xDD:
          restart = _u16(p + 2);
        case 0xDA:
          if (comps.isEmpty || width == 0 || height == 0) return null;
          final ns = jpg[p + 2];
          final scan = <_Comp>[];
          for (var i = 0; i < ns; i++) {
            final id = jpg[p + 3 + 2 * i], t = jpg[p + 4 + 2 * i];
            final c = comps.firstWhere((c) => c.id == id, orElse: () => throw _Fail());
            c.td = t >> 4 & 3;
            c.ta = t & 3;
            scan.add(c);
          }
          _setupPlanes(comps, width, height);
          p = _scan(comps, scan, width, height, restart, end);
          continue;
      }
      p = end;
    }
    if (comps.isEmpty || width == 0) return null;
    return _toI420(comps, width, height);
  }

  int _hmax = 1, _vmax = 1, _mcux = 0, _mcuy = 0;
  bool _planesReady = false;

  void _setupPlanes(List<_Comp> comps, int w, int h) {
    if (_planesReady) return; // several scans (non-interleaved) share the planes
    _hmax = 1;
    _vmax = 1;
    for (final c in comps) {
      if (c.h < 1 || c.h > 4 || c.v < 1 || c.v > 4) throw _Fail();
      if (c.h > _hmax) _hmax = c.h;
      if (c.v > _vmax) _vmax = c.v;
    }
    _mcux = (w + 8 * _hmax - 1) ~/ (8 * _hmax);
    _mcuy = (h + 8 * _vmax - 1) ~/ (8 * _vmax);
    for (final c in comps) {
      c.bw = _mcux * c.h * 8;
      c.bh = _mcuy * c.v * 8;
      c.plane = Uint8List(c.bw * c.bh);
    }
    _planesReady = true;
  }

  // ------------------------------------------------------------ entropy decoding

  void _resetBits() {
    _buf = 0;
    _bits = 0;
    _marker = 0;
  }

  void _fill() {
    while (_bits <= 24) {
      var b = 0;
      if (_marker == 0 && _pos < _d.length) {
        b = _d[_pos++];
        if (b == 0xFF) {
          var c = _pos < _d.length ? _d[_pos] : 0xD9;
          while (c == 0xFF) {
            _pos++;
            c = _pos < _d.length ? _d[_pos] : 0xD9;
          }
          if (c != 0) {
            _marker = c;
            _pos--; // stay on the 0xFF of the marker
            b = 0;
          } else {
            _pos++;
          }
        }
      }
      _buf |= b << (24 - _bits);
      _bits += 8;
    }
  }

  int _decodeHuff(_Huff h) {
    if (_bits < 16) _fill();
    final c = (_buf >> (32 - _fastBits)) & ((1 << _fastBits) - 1);
    final k = h.fast[c];
    if (k < 255) {
      final s = h.size[k];
      _buf = (_buf << s) & 0xFFFFFFFF;
      _bits -= s;
      return h.values[k];
    }
    final temp = _buf >> 16;
    var n = _fastBits + 1;
    while (temp >= h.maxcode[n]) {
      n++;
      if (n == 17) throw _Fail();
    }
    final idx = ((_buf >> (32 - n)) & ((1 << n) - 1)) + h.delta[n];
    if (idx < 0 || idx > 255) throw _Fail();
    _buf = (_buf << n) & 0xFFFFFFFF;
    _bits -= n;
    return h.values[idx];
  }

  int _receiveExtend(int n) {
    if (n == 0) return 0;
    if (_bits < n) _fill();
    final v = _buf >> (32 - n);
    _buf = (_buf << n) & 0xFFFFFFFF;
    _bits -= n;
    return v < (1 << (n - 1)) ? v - (1 << n) + 1 : v;
  }

  void _block(_Comp c, Uint8List out, int off, int stride) {
    final dc = _dc[c.td], ac = _ac[c.ta];
    if (dc == null || ac == null) throw _Fail();
    final q = _q[c.tq];
    final blk = _blk..fillRange(0, 64, 0);
    final t = _decodeHuff(dc);
    c.pred += _receiveExtend(t);
    blk[0] = c.pred * q[0];
    var k = 1;
    while (k < 64) {
      final rs = _decodeHuff(ac);
      final s = rs & 15, r = rs >> 4;
      if (s == 0) {
        if (rs != 0xF0) break;
        k += 16;
        continue;
      }
      k += r;
      if (k > 63) throw _Fail();
      blk[_dezigzag[k]] = _receiveExtend(s) * q[k];
      k++;
    }
    _idct(blk, out, off, stride);
  }

  int _scan(List<_Comp> all, List<_Comp> scan, int w, int h, int restart, int headerEnd) {
    _pos = headerEnd;
    _resetBits();
    for (final c in scan) {
      c.pred = 0;
    }
    var todo = restart > 0 ? restart : 1 << 30;
    void handleRestart() {
      if (--todo > 0) return;
      todo = restart > 0 ? restart : 1 << 30;
      // find the RSTn marker
      if (_marker == 0) {
        while (_pos < _d.length - 1 && !(_d[_pos] == 0xFF && _d[_pos + 1] >= 0xD0 && _d[_pos + 1] <= 0xD7)) {
          _pos++;
        }
        if (_pos < _d.length - 1) _marker = _d[_pos + 1];
      }
      if (_marker >= 0xD0 && _marker <= 0xD7) _pos += 2;
      _resetBits();
      for (final c in scan) {
        c.pred = 0;
      }
    }

    if (scan.length == 1) {
      final c = scan.first;
      final cw = (w * c.h + _hmax - 1) ~/ _hmax, chh = (h * c.v + _vmax - 1) ~/ _vmax;
      final bx = (cw + 7) >> 3, by = (chh + 7) >> 3;
      for (var j = 0; j < by; j++) {
        for (var i = 0; i < bx; i++) {
          _block(c, c.plane, j * 8 * c.bw + i * 8, c.bw);
          handleRestart();
        }
      }
    } else {
      for (var my = 0; my < _mcuy; my++) {
        for (var mx = 0; mx < _mcux; mx++) {
          for (final c in scan) {
            for (var v = 0; v < c.v; v++) {
              for (var u = 0; u < c.h; u++) {
                final y0 = (my * c.v + v) * 8, x0 = (mx * c.h + u) * 8;
                _block(c, c.plane, y0 * c.bw + x0, c.bw);
              }
            }
          }
          handleRestart();
        }
      }
    }
    // continue the marker walk after the entropy data
    var p = _pos;
    while (p < _d.length - 1 && !(_d[p] == 0xFF && _d[p + 1] != 0 && !(_d[p + 1] >= 0xD0 && _d[p + 1] <= 0xD7))) {
      p++;
    }
    return p;
  }

  // ------------------------------------------------------------ IDCT (stb_image, integer)

  static int _clamp(int x) => x < 0 ? 0 : (x > 255 ? 255 : x);

  void _idct(Int32List d, Uint8List out, int off, int stride) {
    final v = _tmp;
    for (var i = 0; i < 8; i++) {
      if (d[i + 8] == 0 &&
          d[i + 16] == 0 &&
          d[i + 24] == 0 &&
          d[i + 32] == 0 &&
          d[i + 40] == 0 &&
          d[i + 48] == 0 &&
          d[i + 56] == 0) {
        final dc = d[i] * 4;
        v[i] = v[i + 8] = v[i + 16] = v[i + 24] = v[i + 32] = v[i + 40] = v[i + 48] = v[i + 56] = dc;
        continue;
      }
      // even part
      var p2 = d[i + 16], p3 = d[i + 48];
      var p1 = (p2 + p3) * 2217;
      var t2 = p1 + p3 * -7567, t3 = p1 + p2 * 3135;
      p2 = d[i];
      p3 = d[i + 32];
      var t0 = (p2 + p3) * 4096, t1 = (p2 - p3) * 4096;
      final x0 = t0 + t3 + 512, x3 = t0 - t3 + 512, x1 = t1 + t2 + 512, x2 = t1 - t2 + 512;
      // odd part
      t0 = d[i + 56];
      t1 = d[i + 40];
      t2 = d[i + 24];
      t3 = d[i + 8];
      p3 = t0 + t2;
      var p4 = t1 + t3;
      p1 = t0 + t3;
      p2 = t1 + t2;
      final p5 = (p3 + p4) * 4816;
      t0 = t0 * 1223;
      t1 = t1 * 8410;
      t2 = t2 * 12586;
      t3 = t3 * 6149;
      p1 = p5 + p1 * -3685;
      p2 = p5 + p2 * -10498;
      p3 = p3 * -8034;
      p4 = p4 * -1598;
      t3 += p1 + p4;
      t2 += p2 + p3;
      t1 += p2 + p4;
      t0 += p1 + p3;
      v[i] = (x0 + t3) >> 10;
      v[i + 56] = (x0 - t3) >> 10;
      v[i + 8] = (x1 + t2) >> 10;
      v[i + 48] = (x1 - t2) >> 10;
      v[i + 16] = (x2 + t1) >> 10;
      v[i + 40] = (x2 - t1) >> 10;
      v[i + 24] = (x3 + t0) >> 10;
      v[i + 32] = (x3 - t0) >> 10;
    }
    for (var r = 0; r < 8; r++) {
      final b = r * 8;
      final o = off + r * stride;
      var p2 = v[b + 2], p3 = v[b + 6];
      var p1 = (p2 + p3) * 2217;
      var t2 = p1 + p3 * -7567, t3 = p1 + p2 * 3135;
      p2 = v[b];
      p3 = v[b + 4];
      var t0 = (p2 + p3) * 4096, t1 = (p2 - p3) * 4096;
      const bias = 65536 + (128 << 17);
      final x0 = t0 + t3 + bias, x3 = t0 - t3 + bias, x1 = t1 + t2 + bias, x2 = t1 - t2 + bias;
      t0 = v[b + 7];
      t1 = v[b + 5];
      t2 = v[b + 3];
      t3 = v[b + 1];
      p3 = t0 + t2;
      var p4 = t1 + t3;
      p1 = t0 + t3;
      p2 = t1 + t2;
      final p5 = (p3 + p4) * 4816;
      t0 = t0 * 1223;
      t1 = t1 * 8410;
      t2 = t2 * 12586;
      t3 = t3 * 6149;
      p1 = p5 + p1 * -3685;
      p2 = p5 + p2 * -10498;
      p3 = p3 * -8034;
      p4 = p4 * -1598;
      t3 += p1 + p4;
      t2 += p2 + p3;
      t1 += p2 + p4;
      t0 += p1 + p3;
      out[o] = _clamp((x0 + t3) >> 17);
      out[o + 7] = _clamp((x0 - t3) >> 17);
      out[o + 1] = _clamp((x1 + t2) >> 17);
      out[o + 6] = _clamp((x1 - t2) >> 17);
      out[o + 2] = _clamp((x2 + t1) >> 17);
      out[o + 5] = _clamp((x2 - t1) >> 17);
      out[o + 3] = _clamp((x3 + t0) >> 17);
      out[o + 4] = _clamp((x3 - t0) >> 17);
    }
  }

  // ------------------------------------------------------------ output

  JpegPicture _toI420(List<_Comp> comps, int w, int h) {
    _planesReady = false;
    final cw = (w + 1) >> 1, ch = (h + 1) >> 1;
    final out = Uint8List(w * h + 2 * cw * ch);
    final y = comps[0];
    for (var r = 0; r < h; r++) {
      out.setRange(r * w, r * w + w, y.plane, r * y.bw);
    }
    if (comps.length < 3) {
      out.fillRange(w * h, out.length, 128);
    } else {
      for (var k = 1; k <= 2; k++) {
        final c = comps[k];
        final base = w * h + (k - 1) * cw * ch;
        // chroma sample position of output pixel (x, y) in the 2x2-subsampled grid
        final sxNum = 2 * c.h, syNum = 2 * c.v;
        final rowAvg = syNum >= 2 * _vmax;
        for (var r = 0; r < ch; r++) {
          final sy = (r * syNum) ~/ _vmax;
          final row0 = (sy < c.bh ? sy : c.bh - 1) * c.bw;
          // when chroma has full vertical resolution (4:2:2), average the two rows
          final row1 = rowAvg && sy + 1 < c.bh ? row0 + c.bw : row0;
          final d = base + r * cw;
          if (sxNum == _hmax) {
            if (row1 == row0) {
              out.setRange(d, d + cw, c.plane, row0);
            } else {
              for (var x = 0; x < cw; x++) {
                out[d + x] = (c.plane[row0 + x] + c.plane[row1 + x] + 1) >> 1;
              }
            }
          } else {
            for (var x = 0; x < cw; x++) {
              final sx = (x * sxNum) ~/ _hmax;
              out[d + x] = (c.plane[row0 + sx] + c.plane[row1 + sx] + 1) >> 1;
            }
          }
        }
      }
    }
    return JpegPicture(out, w, h);
  }
}

final _Huff _stdDcL = _Huff(_dcLumBits, _dcVals);
final _Huff _stdDcC = _Huff(_dcChromBits, _dcVals);
final _Huff _stdAcL = _Huff(_acLumBits, _acLumVals);
final _Huff _stdAcC = _Huff(_acChromBits, _acChromVals);
