/// DVB-S2 encoder (ETSI EN 302 307): MPEG transport stream to QPSK, 8PSK or 16APSK symbols.
///
/// Port of `host/dvbs2.py` (bit-exact). Chain: mode adaptation (CRC-8 in the sync byte
/// position, BBHEADER), BB scrambler, BCH, LDPC, bit interleaver (8PSK, 16APSK), mapping,
/// PLHEADER (SOF + PLSCODE, pi/2 BPSK), pilots, PL scrambler (Gold code 0).
///
/// Output for QPSK: 4 symbols per byte, bit 0 = I level, bit 1 = Q level (1 = +1), first
/// symbol in the low bits. 8PSK: angle index k (e^(j pi k / 4)), 2 symbols per byte, low
/// nibble first, or with [Dvbs2Encoder.bits3] 3 bits per symbol (8 symbols in 3 bytes).
/// 16APSK: bit quadruple v (gr-dtv point index), 2 symbols per byte, low nibble first.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'ldpc_tables.dart';

enum Dvbs2Mod { qpsk, psk8, apsk16 }

extension Dvbs2ModInfo on Dvbs2Mod {
  int get bits => switch (this) { Dvbs2Mod.qpsk => 2, Dvbs2Mod.psk8 => 3, Dvbs2Mod.apsk16 => 4 };
  String get label => switch (this) { Dvbs2Mod.qpsk => 'QPSK', Dvbs2Mod.psk8 => '8PSK', Dvbs2Mod.apsk16 => '16APSK' };
}

/// (k_bch, t) for the normal frames.
const Map<String, (int, int)> _normal = {
  '1/4': (16008, 12), '1/3': (21408, 12), '2/5': (25728, 12), '1/2': (32208, 12),
  '3/5': (38688, 12), '2/3': (43040, 10), '3/4': (48408, 12), '4/5': (51648, 12),
  '5/6': (53840, 10), '8/9': (57472, 8), '9/10': (58192, 8),
};

/// (k_bch, t) for the short frames.
const Map<String, (int, int)> _short = {
  '1/4': (3072, 12), '1/3': (5232, 12), '2/5': (6312, 12), '1/2': (7032, 12),
  '3/5': (9552, 12), '2/3': (10632, 12), '3/4': (11712, 12), '4/5': (12432, 12),
  '5/6': (13152, 12), '8/9': (14232, 12),
};

const Map<String, int> _modcodQpsk = {
  '1/4': 1, '1/3': 2, '2/5': 3, '1/2': 4, '3/5': 5, '2/3': 6, '3/4': 7, '4/5': 8,
  '5/6': 9, '8/9': 10, '9/10': 11,
};
const Map<String, int> _modcod8psk = {'3/5': 12, '2/3': 13, '3/4': 14, '5/6': 15, '8/9': 16, '9/10': 17};
const Map<String, int> _modcod16apsk = {'2/3': 18, '3/4': 19, '4/5': 20, '5/6': 21, '8/9': 22, '9/10': 23};

/// 16APSK: ratio R2 / R1 of the outer and the inner ring per code rate (EN 302 307 table 9).
const Map<String, double> apsk16Gamma = {
  '2/3': 3.15, '3/4': 2.85, '4/5': 2.75, '5/6': 2.70, '8/9': 2.60, '9/10': 2.57,
};

/// 8PSK: DVB-S2 bit triple (b0 b1 b2) -> angle index k.
const List<int> _psk8K = [1, 0, 4, 5, 2, 7, 3, 6];

/// The code rates that exist for this modulation and frame size.
List<String> dvbs2Rates(Dvbs2Mod mod, {bool short = false}) {
  final r = (short ? _short : _normal).keys.toList();
  return switch (mod) {
    Dvbs2Mod.qpsk => r,
    Dvbs2Mod.psk8 => r.where(_modcod8psk.containsKey).toList(),
    Dvbs2Mod.apsk16 => r.where(_modcod16apsk.containsKey).toList(),
  };
}

class Dvbs2FrameInfo {
  const Dvbs2FrameInfo(this.kbch, this.t, this.nldpc, this.plframe);
  final int kbch, t, nldpc;

  /// Symbols of the PLFRAME, header and pilots included.
  final int plframe;

  int get dfl => kbch - 80;
}

Dvbs2FrameInfo dvbs2FrameInfo(String fec, Dvbs2Mod mod, {bool short = false, bool pilots = false}) {
  if (!dvbs2Rates(mod, short: short).contains(fec)) {
    throw ArgumentError('DVB-S2 ${mod.label} ${short ? 'short' : 'normal'} frame: FEC '
        '${dvbs2Rates(mod, short: short).join(', ')}');
  }
  final (kbch, t) = (short ? _short : _normal)[fec]!;
  final n = short ? 16200 : 64800;
  final nsymData = n ~/ mod.bits;
  final slots = nsymData ~/ 90;
  final nsym = 90 + nsymData + (pilots ? 36 * ((slots - 1) ~/ 16) : 0);
  return Dvbs2FrameInfo(kbch, t, n, nsym);
}

/// Useful transport-stream bit rate [bit/s].
double dvbs2TsRate(double baud, String fec, Dvbs2Mod mod, {bool short = false, bool pilots = false}) {
  final fi = dvbs2FrameInfo(fec, mod, short: short, pilots: pilots);
  return baud * fi.dfl / fi.plframe;
}

// ---------------------------------------------------------------- CRC-8: x^8+x^7+x^6+x^4+x^2+1
final Uint8List _crc8Tab = () {
  final t = Uint8List(256);
  for (var b = 0; b < 256; b++) {
    var c = b;
    for (var i = 0; i < 8; i++) {
      c = (c & 0x80) != 0 ? ((c << 1) ^ 0xD5) & 0xFF : (c << 1) & 0xFF;
    }
    t[b] = c;
  }
  return t;
}();

int crc8(Uint8List data, [int start = 0, int? end]) {
  var c = 0;
  final e = end ?? data.length;
  for (var i = start; i < e; i++) {
    c = _crc8Tab[c ^ data[i]];
  }
  return c;
}

// ---------------------------------------------------------------- BB scrambler: 1 + x^14 + x^15
final Map<int, Uint8List> _bbPrbs = {};

Uint8List _bbPrbsBytes(int kbch) => _bbPrbs.putIfAbsent(kbch, () {
      final reg = [1, 0, 0, 1, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0];
      final out = Uint8List(kbch >> 3);
      for (var i = 0; i < kbch; i++) {
        final o = reg[13] ^ reg[14];
        for (var k = 14; k > 0; k--) {
          reg[k] = reg[k - 1];
        }
        reg[0] = o;
        if (o != 0) out[i >> 3] |= 0x80 >> (i & 7);
      }
      return out;
    });

// ---------------------------------------------------------------- BCH
BigInt _polyMulGf2(BigInt a, BigInt b) {
  var r = BigInt.zero;
  while (b != BigInt.zero) {
    if ((b & BigInt.one) != BigInt.zero) r ^= a;
    a <<= 1;
    b >>= 1;
  }
  return r;
}

/// g(x) (bit i = coefficient of x^i): product of the minimal polynomials of a^1, a^3, ..., a^(2t-1).
BigInt bchGenerator(int m, int prim, int t) {
  final n = (1 << m) - 1;
  final exp = Int32List(n);
  final log = Int32List(n + 1);
  var x = 1;
  for (var i = 0; i < n; i++) {
    exp[i] = x;
    log[x] = i;
    x <<= 1;
    if ((x >> m) != 0) x ^= prim;
  }
  var g = BigInt.one;
  final seen = <int>{};
  for (var i = 1; i < 2 * t; i += 2) {
    final coset = <int>[];
    var j = i;
    while (!coset.contains(j)) {
      coset.add(j);
      j = (2 * j) % n;
    }
    if (seen.contains(coset[0])) continue;
    seen.add(coset[0]);
    var poly = <int>[1];
    for (final j in coset) {
      final next = List<int>.filled(poly.length + 1, 0);
      for (var k = 0; k < poly.length; k++) {
        final c = poly[k];
        next[k + 1] ^= c;
        if (c != 0) next[k] ^= exp[(log[c] + j) % n];
      }
      poly = next;
    }
    var mp = BigInt.zero;
    for (var k = 0; k < poly.length; k++) {
      assert(poly[k] == 0 || poly[k] == 1);
      if (poly[k] != 0) mp |= BigInt.one << k;
    }
    g = _polyMulGf2(g, mp);
  }
  return g;
}

class Bch {
  Bch({required bool short, required int t}) {
    final (m, prim) = short ? (14, 0x402B) : (16, 0x1002D);
    final g = bchGenerator(m, prim, t);
    deg = g.bitLength - 1;
    nb = deg >> 3;
    _tab = Uint8List(256 * nb);
    final mask = (BigInt.one << deg) - BigInt.one;
    for (var b = 0; b < 256; b++) {
      var r = BigInt.from(b) << deg;
      for (var bit = deg + 7; bit >= deg; bit--) {
        if (((r >> bit) & BigInt.one) != BigInt.zero) r ^= g << (bit - deg);
      }
      r &= mask;
      for (var i = 0; i < nb; i++) {
        _tab[b * nb + i] = ((r >> (8 * (nb - 1 - i))) & BigInt.from(255)).toInt();
      }
    }
  }

  late final int deg;
  late final int nb;
  late final Uint8List _tab;

  /// Parity bytes (deg / 8, big-endian) of [data] (first bit = highest power).
  void parity(Uint8List data, int len, Uint8List out, int outOff) {
    final s = Uint8List(nb);
    final tab = _tab;
    final last = nb - 1;
    for (var i = 0; i < len; i++) {
      final base = (s[0] ^ data[i]) * nb;
      for (var j = 0; j < last; j++) {
        s[j] = s[j + 1] ^ tab[base + j];
      }
      s[last] = tab[base + last];
    }
    out.setRange(outOff, outOff + nb, s);
  }
}

// ---------------------------------------------------------------- LDPC
class Ldpc {
  Ldpc({required bool short, required String fec}) {
    final rows = ldpcTables[short ? 'short' : 'normal']![fec]!;
    k = rows.length * 360;
    n = short ? 16200 : 64800;
    nk = n - k;
    _q = nk ~/ 360;
    _rowStart = Int32List(rows.length + 1);
    final flat = <int>[];
    for (var g = 0; g < rows.length; g++) {
      _rowStart[g] = flat.length;
      flat.addAll(rows[g]);
    }
    _rowStart[rows.length] = flat.length;
    _addr = Int32List.fromList(flat);
  }

  late final int k, n, nk, _q;
  late final Int32List _rowStart, _addr;

  /// [bits]: k information bits (0/1) -> writes the nk parity bits into [cw] after the info bits.
  /// [cw] must hold n bits and already contain the information bits at 0..k-1.
  void encode(Uint8List cw) {
    final nk = this.nk, q = _q, k = this.k;
    final p = Uint8List.sublistView(cw, k, k + nk)..fillRange(0, nk, 0);
    final groups = _rowStart.length - 1;
    for (var g = 0; g < groups; g++) {
      final a0 = _rowStart[g], a1 = _rowStart[g + 1];
      final base = 360 * g;
      for (var i = 0; i < 360; i++) {
        if (cw[base + i] == 0) continue;
        final off = q * i;
        for (var a = a0; a < a1; a++) {
          var ix = _addr[a] + off;
          if (ix >= nk) ix -= nk;
          p[ix] ^= 1;
        }
      }
    }
    for (var j = 1; j < nk; j++) {
      p[j] ^= p[j - 1];
    }
  }
}

// ---------------------------------------------------------------- physical layer
const int _sof = 0x18D2E82;
const List<int> _rmRows = [0x55555555, 0x33333333, 0x0F0F0F0F, 0x00FF00FF, 0x0000FFFF, 0xFFFFFFFF];
final BigInt _plsScramble = BigInt.parse('719D83C953422DFA', radix: 16);

/// The 90 header bits: SOF + PLSCODE.
List<int> plHeaderBits(int modcod, bool short, bool pilots) {
  final out = <int>[];
  for (var i = 25; i >= 0; i--) {
    out.add((_sof >> i) & 1);
  }
  final pls = (modcod << 2) | (short ? 2 : 0) | (pilots ? 1 : 0);
  final b = [for (var i = 6; i >= 0; i--) (pls >> i) & 1];
  var cw = 0;
  for (var i = 0; i < 6; i++) {
    if (b[i] != 0) cw ^= _rmRows[i];
  }
  for (var i = 0; i < 32; i++) {
    final w = (cw >> (31 - i)) & 1;
    final s0 = ((_plsScramble >> (63 - 2 * i)) & BigInt.one).toInt();
    final s1 = ((_plsScramble >> (62 - 2 * i)) & BigInt.one).toInt();
    out.add(w ^ s0);
    out.add(w ^ b[6] ^ s1);
  }
  return out;
}

/// PL scrambling sequence R(i) in 0..3 (Gold code n = 0), 33282 entries.
final Uint8List plRotation = () {
  const n = (1 << 18) - 1;
  const len = 33282;
  final x = Uint8List(n + 20);
  final y = Uint8List(n + 20);
  x[0] = 1;
  for (var i = 0; i < 18; i++) {
    y[i] = 1;
  }
  for (var i = 0; i < n + 2 - 18; i++) {
    x[i + 18] = x[i + 7] ^ x[i];
    y[i + 18] = y[i + 10] ^ y[i + 7] ^ y[i + 5] ^ y[i];
  }
  int z(int i) => x[i % n] ^ y[i];
  final r = Uint8List(len);
  for (var i = 0; i < len; i++) {
    r[i] = z(i) + 2 * z((i + 131072) % n);
  }
  return r;
}();

/// The 16 constellation points of a 16APSK code rate as (re, im).
List<(double, double)> apsk16Points(String fec) {
  const angles = [45, -45, 135, -135, 15, -15, 165, -165, 75, -75, 105, -105, 45, -45, 135, -135];
  final g = apsk16Gamma[fec]!;
  final r1 = 4.0 / math.sqrt(4.0 + 12.0 * g * g);
  return [
    for (var v = 0; v < 16; v++)
      (
        (v < 12 ? g * r1 : r1) * math.cos(angles[v] * math.pi / 180),
        (v < 12 ? g * r1 : r1) * math.sin(angles[v] * math.pi / 180),
      ),
  ];
}

Uint8List _apsk16Map((double, double) Function((double, double) z) f) {
  final z = apsk16Points('2/3');
  final out = Uint8List(16);
  for (var v = 0; v < 16; v++) {
    final t = f(z[v]);
    var best = 0;
    var bd = double.infinity;
    for (var u = 0; u < 16; u++) {
      final dr = z[u].$1 - t.$1, di = z[u].$2 - t.$2;
      final d = dr * dr + di * di;
      if (d < bd) {
        bd = d;
        best = u;
      }
    }
    out[v] = best;
  }
  return out;
}

/// A quarter turn (the PL scrambler).
final Uint8List apsk16Rot = _apsk16Map((z) => (-z.$2, z.$1));

/// Q -> -Q.
final Uint8List apsk16Conj = _apsk16Map((z) => (z.$1, -z.$2));

/// I <-> Q.
final Uint8List apsk16Swap = _apsk16Map((z) => (z.$2, z.$1));

/// Rotation applied r times (r = 0..3), per point.
final Uint8List _apsk16RotN = () {
  final t = Uint8List(64);
  for (var v = 0; v < 16; v++) {
    var w = v;
    for (var r = 0; r < 4; r++) {
      t[r * 16 + v] = w;
      w = apsk16Rot[w];
    }
  }
  return t;
}();

const Map<int, int> _apsk16Hdr = {1: 0, 3: 2, 5: 3, 7: 1};

class Dvbs2Encoder {
  Dvbs2Encoder({
    this.fec = '1/2',
    this.short = false,
    this.pilots = false,
    this.swapIq = false,
    this.invert = false,
    this.mod = Dvbs2Mod.qpsk,
    bool bits3 = false,
  }) : bits3 = bits3 && mod == Dvbs2Mod.psk8 {
    final fi = dvbs2FrameInfo(fec, mod, short: short, pilots: pilots);
    kbch = fi.kbch;
    dfl = fi.dfl;
    nsym = fi.plframe;
    nldpc = fi.nldpc;
    _bch = Bch(short: short, t: fi.t);
    _ldpc = Ldpc(short: short, fec: fec);
    if (_ldpc.k != kbch + _bch.deg) throw StateError('BCH/LDPC size mismatch');
    final modcod = switch (mod) {
      Dvbs2Mod.qpsk => _modcodQpsk[fec]!,
      Dvbs2Mod.psk8 => _modcod8psk[fec]!,
      Dvbs2Mod.apsk16 => _modcod16apsk[fec]!,
    };
    final hdr = plHeaderBits(modcod, short, pilots);
    _hdrI = Int8List(90);
    _hdrQ = Int8List(90);
    _hdrK = Uint8List(90);
    _hdrV = Uint8List(90);
    for (var i = 0; i < 90; i++) {
      final a = 1 - 2 * hdr[i];
      final hi = i.isEven ? a : -a;
      _hdrI[i] = hi;
      _hdrQ[i] = a;
      final k = hi == 1 ? (a == 1 ? 1 : 7) : (a == 1 ? 3 : 5);
      _hdrK[i] = k;
      _hdrV[i] = _apsk16Hdr[k]!;
    }
    _bbBuf = Uint8List(kbch >> 3);
    _cwBits = Uint8List(nldpc);
    _syms = Uint8List(nsym);
  }

  final String fec;
  final bool short, pilots, swapIq, invert;
  final Dvbs2Mod mod;
  final bool bits3;
  late final int kbch, dfl, nsym, nldpc;
  late final Bch _bch;
  late final Ldpc _ldpc;
  late final Int8List _hdrI, _hdrQ;
  late final Uint8List _hdrK, _hdrV;
  late final Uint8List _bbBuf, _cwBits, _syms;

  int _crcPrev = 0;
  Uint8List _stream = Uint8List(1 << 16);
  int _sHead = 0, _sTail = 0; // valid bytes are _stream[_sHead.._sTail)
  int _pos = 0; // stream byte number of _stream[_sHead]

  // pending symbols that did not fill a byte yet
  int _pend = 0, _pendN = 0;

  double get packetsPerFrame => dfl / 1504.0;
  int get _needBytes => dfl ~/ 8;
  bool get ready => _sTail - _sHead >= _needBytes;

  /// Add TS packets (a multiple of 188 bytes, each starting with 0x47).
  void push(Uint8List ts) {
    if (ts.length % 188 != 0) throw ArgumentError('TS length not a multiple of 188');
    final need = _sTail - _sHead + ts.length;
    if (_sTail + ts.length > _stream.length) {
      if (need <= _stream.length ~/ 2) {
        _stream.setRange(0, _sTail - _sHead, _stream, _sHead);
      } else {
        final ns = Uint8List(math.max(_stream.length * 2, need * 2));
        ns.setRange(0, _sTail - _sHead, _stream, _sHead);
        _stream = ns;
      }
      _sTail -= _sHead;
      _sHead = 0;
    }
    for (var o = 0; o < ts.length; o += 188) {
      if (ts[o] != 0x47) throw ArgumentError('TS packet without the 0x47 sync byte');
      _stream[_sTail] = _crcPrev;
      _stream.setRange(_sTail + 1, _sTail + 188, ts, o + 1);
      _crcPrev = crc8(ts, o + 1, o + 188);
      _sTail += 188;
    }
  }

  /// The next BBFRAME (k_bch bits as bytes), BB scrambled.
  Uint8List bbframe() {
    final nb = _needBytes;
    final first = ((_pos + 187) ~/ 188) * 188;
    final syncd = first < _pos + nb ? (first - _pos) * 8 : 65535;
    final bb = _bbBuf;
    final h = [0xF0, 0x00, 0x05, 0xE0, dfl >> 8, dfl & 255, 0x47, syncd >> 8, syncd & 255];
    for (var i = 0; i < 9; i++) {
      bb[i] = h[i];
    }
    bb[9] = crc8(bb, 0, 9);
    bb.setRange(10, 10 + nb, _stream, _sHead);
    _sHead += nb;
    _pos += nb;
    final prbs = _bbPrbsBytes(kbch);
    for (var i = 0; i < bb.length; i++) {
      bb[i] ^= prbs[i];
    }
    return bb;
  }

  /// BCH + LDPC: the codeword bits of a BBFRAME, as 0/1 bytes in _cwBits.
  void _fec(Uint8List bb) {
    final par = Uint8List(_bch.nb);
    _bch.parity(bb, bb.length, par, 0);
    final cw = _cwBits;
    var o = 0;
    for (var i = 0; i < bb.length; i++) {
      final b = bb[i];
      for (var s = 7; s >= 0; s--) {
        cw[o++] = (b >> s) & 1;
      }
    }
    for (var i = 0; i < par.length; i++) {
      final b = par[i];
      for (var s = 7; s >= 0; s--) {
        cw[o++] = (b >> s) & 1;
      }
    }
    _ldpc.encode(cw);
  }

  /// One PLFRAME of the next BBFRAME as symbol values in _syms: QPSK levels (li | lq << 1),
  /// 8PSK k, or 16APSK v, before invert / swap.
  void _plframe(Uint8List bb) {
    _fec(bb);
    final cw = _cwBits;
    final out = _syms;
    final rot = plRotation;
    final nData = nldpc ~/ mod.bits;
    var o = 90;
    var r = 0; // index into the scrambling sequence
    switch (mod) {
      case Dvbs2Mod.qpsk:
        for (var i = 0; i < 90; i++) {
          out[i] = (_hdrI[i] > 0 ? 1 : 0) | (_hdrQ[i] > 0 ? 2 : 0);
        }
      case Dvbs2Mod.psk8:
        out.setRange(0, 90, _hdrK);
      case Dvbs2Mod.apsk16:
        out.setRange(0, 90, _hdrV);
    }
    final third = nldpc ~/ 3, quarter = nldpc ~/ 4;
    final rev = fec == '3/5';
    for (var s = 0; s < nData; s++) {
      if (pilots && s > 0 && s % 1440 == 0) {
        // 36 pilot symbols after every 16 slots, none after the last
        for (var p = 0; p < 36; p++) {
          out[o++] = _scramble(mod == Dvbs2Mod.qpsk ? 3 : (mod == Dvbs2Mod.psk8 ? 1 : 0), rot[r++]);
        }
      }
      int v;
      switch (mod) {
        case Dvbs2Mod.qpsk:
          // bit 0 -> +1 (level 1)
          v = (1 - cw[2 * s]) | ((1 - cw[2 * s + 1]) << 1);
        case Dvbs2Mod.psk8:
          final c0 = cw[s], c1 = cw[third + s], c2 = cw[2 * third + s];
          v = rev ? _psk8K[c2 << 2 | c1 << 1 | c0] : _psk8K[c0 << 2 | c1 << 1 | c2];
        case Dvbs2Mod.apsk16:
          v = cw[s] << 3 | cw[quarter + s] << 2 | cw[2 * quarter + s] << 1 | cw[3 * quarter + s];
      }
      out[o++] = _scramble(v, rot[r++]);
    }
    assert(o == nsym);
  }

  int _scramble(int v, int r) {
    if (r == 0) return v;
    switch (mod) {
      case Dvbs2Mod.qpsk:
        // li/lq: level 1 = +1. Multiply by j^r.
        final i = (v & 1) != 0 ? 1 : -1, q = (v & 2) != 0 ? 1 : -1;
        int ci, cq;
        switch (r) {
          case 1:
            ci = -q;
            cq = i;
          case 2:
            ci = -i;
            cq = -q;
          default:
            ci = q;
            cq = -i;
        }
        return (ci > 0 ? 1 : 0) | (cq > 0 ? 2 : 0);
      case Dvbs2Mod.psk8:
        return (v + 2 * r) & 7;
      case Dvbs2Mod.apsk16:
        return _apsk16RotN[r * 16 + v];
    }
  }

  void _pack(BytesBuilder outB) {
    final syms = _syms;
    final n = syms.length;
    final buf = Uint8List(n + 8);
    var ob = 0;
    var pend = _pend, pendN = _pendN;
    switch (mod) {
      case Dvbs2Mod.qpsk:
        for (var i = 0; i < n; i++) {
          var li = syms[i] & 1, lq = (syms[i] >> 1) & 1;
          if (invert) lq = 1 - lq;
          if (swapIq) {
            final t = li;
            li = lq;
            lq = t;
          }
          pend |= (li | (lq << 1)) << (2 * pendN);
          if (++pendN == 4) {
            buf[ob++] = pend;
            pend = 0;
            pendN = 0;
          }
        }
      case Dvbs2Mod.psk8:
        for (var i = 0; i < n; i++) {
          var k = syms[i];
          if (invert) k = (8 - k) & 7;
          if (swapIq) k = (2 - k) & 7;
          if (bits3) {
            pend |= k << (3 * pendN);
            if (++pendN == 8) {
              buf[ob++] = pend & 255;
              buf[ob++] = (pend >> 8) & 255;
              buf[ob++] = (pend >> 16) & 255;
              pend = 0;
              pendN = 0;
            }
          } else {
            pend |= k << (4 * pendN);
            if (++pendN == 2) {
              buf[ob++] = pend;
              pend = 0;
              pendN = 0;
            }
          }
        }
      case Dvbs2Mod.apsk16:
        for (var i = 0; i < n; i++) {
          var v = syms[i];
          if (invert) v = apsk16Conj[v];
          if (swapIq) v = apsk16Swap[v];
          pend |= v << (4 * pendN);
          if (++pendN == 2) {
            buf[ob++] = pend;
            pend = 0;
            pendN = 0;
          }
        }
    }
    _pend = pend;
    _pendN = pendN;
    outB.add(Uint8List.sublistView(buf, 0, ob));
  }

  /// Push packets and return the packed symbols of every PLFRAME that is complete now.
  Uint8List encode(Uint8List ts) {
    push(ts);
    final out = BytesBuilder(copy: false);
    while (ready) {
      _plframe(bbframe());
      _pack(out);
    }
    return out.takeBytes();
  }
}
