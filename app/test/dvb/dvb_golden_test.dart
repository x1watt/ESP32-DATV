import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:esp32_datv/core/dvb/dvbs.dart';
import 'package:esp32_datv/core/dvb/dvbs2.dart';
import 'package:test/test.dart';

Uint8List goldenTs(int n) {
  var x = 0x2545F491;
  final out = Uint8List(n * 188);
  var o = 0;
  for (var p = 0; p < n; p++) {
    out[o++] = 0x47;
    for (var i = 0; i < 187; i++) {
      x ^= (x << 13) & 0xFFFFFFFF;
      x ^= x >> 17;
      x ^= (x << 5) & 0xFFFFFFFF;
      out[o++] = (x >> 11) & 255;
    }
  }
  return out;
}

String sha(List<int> b) => sha256.convert(b).toString();

Dvbs2Mod modOf(String s) =>
    {'qpsk': Dvbs2Mod.qpsk, '8psk': Dvbs2Mod.psk8, '16apsk': Dvbs2Mod.apsk16}[s]!;

void main() {
  final g = jsonDecode(File('test/fixtures/dvb_goldens.json').readAsStringSync()) as Map<String, dynamic>;
  final ts = goldenTs(g['packets'] as int);

  test('dvbs2.py built-in GOLDEN hashes (120 packets)', () {
    final t120 = goldenTs(120);
    const golden = {
      ('normal', '1/2', false, Dvbs2Mod.qpsk): 'b6e638f7edd4f2f0',
      ('normal', '3/4', true, Dvbs2Mod.qpsk): '0d3788b63e1cdb7d',
      ('short', '2/3', false, Dvbs2Mod.qpsk): '7a12e0b7f21f23e2',
      ('short', '1/4', true, Dvbs2Mod.qpsk): 'fad3eb819a6cd97a',
      ('normal', '2/3', true, Dvbs2Mod.psk8): '181d2d8334e78f7b',
      ('short', '3/5', false, Dvbs2Mod.psk8): '85f75b336f7d6f59',
      ('normal', '3/4', true, Dvbs2Mod.apsk16): '260bd1c3ef9eda78',
      ('short', '2/3', false, Dvbs2Mod.apsk16): '4c9f2fa994176bcf',
    };
    golden.forEach((k, v) {
      final e = Dvbs2Encoder(fec: k.$2, short: k.$1 == 'short', pilots: k.$3, mod: k.$4);
      expect(sha(e.encode(t120)).substring(0, 16), v, reason: '$k');
    });
  });

  test('DVB-S matches host/dvbs.py', () {
    (g['dvbs'] as Map<String, dynamic>).forEach((key, want) {
      final p = key.split('|');
      final e = DvbsEncoder(fec: p[0], swapIq: p[1] == '1', invert: p[2] == '1');
      final b = BytesBuilder()
        ..add(e.encode(Uint8List.sublistView(ts, 0, 188 * 7)))
        ..add(e.encode(Uint8List.sublistView(ts, 188 * 7)));
      expect(sha(b.takeBytes()), want, reason: key);
    });
  });

  test('DVB-S2 matches host/dvbs2.py for every mode', () {
    for (final m in (g['dvbs2'] as List).cast<Map<String, dynamic>>()) {
      final e = Dvbs2Encoder(
        fec: m['fec'] as String,
        short: m['frame'] == 'short',
        pilots: m['pilots'] as bool,
        swapIq: m['swap'] as bool,
        invert: m['invert'] as bool,
        mod: modOf(m['mod'] as String),
        bits3: m['bits3'] as bool,
      );
      final out = e.encode(ts);
      expect(out.length, m['len'], reason: '$m');
      expect(sha(out), m['sha256'], reason: '$m');
    }
  });

  test('chunking invariance', () {
    final a = Dvbs2Encoder(fec: '2/3', mod: Dvbs2Mod.apsk16, pilots: true).encode(ts);
    final e = Dvbs2Encoder(fec: '2/3', mod: Dvbs2Mod.apsk16, pilots: true);
    final b = BytesBuilder();
    for (var o = 0; o < ts.length; o += 188 * 3) {
      b.add(e.encode(Uint8List.sublistView(ts, o, (o + 188 * 3).clamp(0, ts.length))));
    }
    expect(sha(b.takeBytes()), sha(a));
  });

  test('throughput', () {
    final big = goldenTs(2000);
    for (final (mod, fec) in [(Dvbs2Mod.qpsk, '1/2'), (Dvbs2Mod.apsk16, '2/3')]) {
      final e = Dvbs2Encoder(fec: fec, mod: mod);
      final sw = Stopwatch()..start();
      e.encode(big);
      final mbps = big.length * 8 / sw.elapsedMicroseconds;
      // ignore: avoid_print
      print('DVB-S2 ${mod.label} $fec: ${mbps.toStringAsFixed(2)} Mbit/s TS (JIT)');
    }
    final e = DvbsEncoder(fec: '1/2');
    final sw = Stopwatch()..start();
    e.encode(big);
    // ignore: avoid_print
    print('DVB-S 1/2: ${(big.length * 8 / sw.elapsedMicroseconds).toStringAsFixed(2)} Mbit/s TS (JIT)');
  });
}
