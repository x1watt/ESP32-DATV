/// DVB-S encoder (ETSI EN 300 421): MPEG transport stream to packed QPSK symbols.
///
/// Port of `host/dvbs.py`. Chain: energy dispersal, RS(204,188), Forney interleaver
/// (I=12, M=17), K=7 convolutional code with puncturing, QPSK mapping. Output: 4 symbols
/// per byte, first symbol in the lowest bits; per symbol bit 0 = I level, bit 1 = Q level
/// (1 = +1). This is what the QPSKT modulator in the ESP reads.
library;

import 'dart:typed_data';


const dvbsFecRates = ['1/2', '2/3', '3/4', '5/6', '7/8'];

const Map<String, (List<int>, List<int>)> _punct = {
  '1/2': ([1], [1]),
  '2/3': ([1, 0], [1, 1]),
  '3/4': ([1, 0, 1], [1, 1, 0]),
  '5/6': ([1, 0, 1, 0, 1], [1, 1, 0, 1, 0]),
  '7/8': ([1, 0, 0, 0, 1, 0, 1], [1, 1, 1, 1, 0, 1, 0]),
};

const Map<String, double> dvbsFecValue = {
  '1/2': 1 / 2,
  '2/3': 2 / 3,
  '3/4': 3 / 4,
  '5/6': 5 / 6,
  '7/8': 7 / 8,
};

/// Useful transport-stream bit rate [bit/s] at a given symbol rate.
double dvbsTsRate(double baud, String fec) =>
    baud * 2 * dvbsFecValue[fec]! * 188 / 204;

// ---- GF(256), x^8 + x^4 + x^3 + x^2 + 1 ----
final Uint8List _exp = () {
  final e = Uint8List(512);
  var x = 1;
  for (var i = 0; i < 255; i++) {
    e[i] = x;
    x <<= 1;
    if (x & 0x100 != 0) x ^= 0x11D;
  }
  for (var i = 255; i < 510; i++) {
    e[i] = e[i - 255];
  }
  return e;
}();

final Int32List _log = () {
  final l = Int32List(256);
  for (var i = 0; i < 255; i++) {
    l[_exp[i]] = i;
  }
  return l;
}();

int gfMul(int a, int b) =>
    (a == 0 || b == 0) ? 0 : _exp[_log[a] + _log[b]];

/// g(x) = (x + a^0)...(x + a^15), highest power first (17 coefficients).
final Uint8List rsGenerator = () {
  var g = <int>[1];
  for (var i = 0; i < 16; i++) {
    final r = _exp[i];
    final ng = List<int>.filled(g.length + 1, 0);
    for (var k = 0; k < g.length; k++) {
      ng[k] ^= g[k];
      ng[k + 1] ^= gfMul(g[k], r);
    }
    g = ng;
  }
  return Uint8List.fromList(g);
}();

/// Per feedback byte, the 16 products with g[1..16].
final Uint8List _rsMulTab = () {
  final t = Uint8List(256 * 16);
  for (var fb = 0; fb < 256; fb++) {
    for (var j = 0; j < 16; j++) {
      t[fb * 16 + j] = gfMul(fb, rsGenerator[j + 1]);
    }
  }
  return t;
}();

/// RS(204,188) parity of [data] (188 bytes at [off]) written to [out] at [outOff].
void rsParity(Uint8List data, int off, Uint8List out, int outOff) {
  final r = Uint8List(16);
  for (var i = 0; i < 188; i++) {
    final fb = data[off + i] ^ r[0];
    final base = fb * 16;
    for (var j = 0; j < 15; j++) {
      r[j] = r[j + 1] ^ _rsMulTab[base + j];
    }
    r[15] = _rsMulTab[base + 15];
  }
  out.setRange(outOff, outOff + 16, r);
}

/// 1503 PRBS bytes (init 100101010000000, output = stages 14 xor 15).
final Uint8List dvbsPrbs = () {
  final reg = [1, 0, 0, 1, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0];
  final out = Uint8List(1503);
  for (var i = 0; i < 1503 * 8; i++) {
    final o = reg[13] ^ reg[14];
    for (var k = 14; k > 0; k--) {
      reg[k] = reg[k - 1];
    }
    reg[0] = o;
    if (o != 0) out[i >> 3] |= 0x80 >> (i & 7);
  }
  return out;
}();

class DvbsEncoder {
  DvbsEncoder({this.fec = '1/2', this.swapIq = false, this.invert = false}) {
    final p = _punct[fec];
    if (p == null) throw ArgumentError('FEC: ${dvbsFecRates.join(', ')}');
    _xp = p.$1;
    _yp = p.$2;
  }

  final String fec;
  final bool swapIq;
  final bool invert;
  late final List<int> _xp, _yp;

  int _pkt = 0;
  final Uint8List _hist = Uint8List(204 * 11);
  int _cstate = 0; // last 6 input bits, newest in bit 0
  int _cpos = 0;
  int _pendBit = -1;
  int _pendSym = 0, _pendSymN = 0;

  /// [ts]: a multiple of 188 bytes, every packet starting with 0x47 -> packed symbols.
  Uint8List encode(Uint8List ts) {
    if (ts.length % 188 != 0) throw ArgumentError('TS length not a multiple of 188');
    final n = ts.length ~/ 188;
    if (n == 0) return Uint8List(0);
    // energy dispersal + RS
    final cw = Uint8List(n * 204);
    for (var i = 0; i < n; i++) {
      if (ts[i * 188] != 0x47) throw ArgumentError('TS packet without the 0x47 sync byte');
      final k = (_pkt + i) % 8;
      final o = i * 204;
      cw[o] = k == 0 ? 0xB8 : 0x47;
      final pb = 188 * k;
      for (var j = 1; j < 188; j++) {
        cw[o + j] = ts[i * 188 + j] ^ dvbsPrbs[pb + j - 1];
      }
      rsParity(cw, o, cw, o + 188);
    }
    _pkt = (_pkt + n) % 8;
    // Forney interleaver: out(t) = x[len(hist) + t - 204*(t mod 12)], x = hist ++ cw
    const hl = 204 * 11;
    final len = cw.length;
    final out = Uint8List(len);
    for (var t = 0; t < len; t++) {
      final idx = hl + t - 204 * (t % 12);
      out[t] = idx >= hl ? cw[idx - hl] : _hist[idx];
    }
    if (len >= hl) {
      _hist.setRange(0, hl, cw, len - hl);
    } else {
      _hist.setRange(0, hl - len, _hist, len);
      _hist.setRange(hl - len, hl, cw);
    }
    // convolutional code + puncturing + mapping + packing
    final res = BytesBuilder(copy: false);
    final outBuf = Uint8List(len * 2 + 2);
    var ob = 0;
    final pLen = _xp.length;
    var st = _cstate;
    var cpos = _cpos;
    var pendBit = _pendBit;
    var pendSym = _pendSym, pendSymN = _pendSymN;
    void putBit(int b) {
      if (pendBit < 0) {
        pendBit = b;
        return;
      }
      var li = 1 - pendBit, lq = 1 - b;
      pendBit = -1;
      if (invert) lq = 1 - lq;
      if (swapIq) {
        final t = li;
        li = lq;
        lq = t;
      }
      pendSym |= (li | (lq << 1)) << (2 * pendSymN);
      if (++pendSymN == 4) {
        outBuf[ob++] = pendSym;
        pendSym = 0;
        pendSymN = 0;
      }
    }

    for (var t = 0; t < len; t++) {
      final byte = out[t];
      for (var bi = 7; bi >= 0; bi--) {
        final b = (byte >> bi) & 1;
        // st bit d-1 holds the bit with delay d (d = 1..6)
        final d1 = st & 1, d2 = (st >> 1) & 1, d3 = (st >> 2) & 1;
        final d5 = (st >> 4) & 1, d6 = (st >> 5) & 1;
        final x = b ^ d1 ^ d2 ^ d3 ^ d6;
        final y = b ^ d2 ^ d3 ^ d5 ^ d6;
        st = ((st << 1) | b) & 0x3F;
        if (_xp[cpos] != 0) putBit(x);
        if (_yp[cpos] != 0) putBit(y);
        if (++cpos == pLen) cpos = 0;
      }
    }
    _cstate = st;
    _cpos = cpos;
    _pendBit = pendBit;
    _pendSym = pendSym;
    _pendSymN = pendSymN;
    res.add(Uint8List.sublistView(outBuf, 0, ob));
    return res.takeBytes();
  }
}
