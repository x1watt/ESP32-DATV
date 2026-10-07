import 'dart:convert';
import 'dart:io';

import 'package:esp32_datv/core/dvb/dvbs.dart';
import 'package:esp32_datv/core/dvb/dvbs2.dart';
import 'package:esp32_datv/core/esp/tx_config.dart';
import 'package:test/test.dart';

void main() {
  test('sps, actual baud, capacity and budget match host/tx_dvbs.py', () {
    final g = (jsonDecode(File('test/fixtures/plan_goldens.json').readAsStringSync()) as List)
        .cast<Map<String, dynamic>>();
    for (final m in g) {
      final mod = {'qpsk': Dvbs2Mod.qpsk, '8psk': Dvbs2Mod.psk8, '16apsk': Dvbs2Mod.apsk16}[m['mod']]!;
      final baud = m['baud'] as int;
      int sps() => switch (mod) {
            Dvbs2Mod.apsk16 => autoSps16apsk(baud),
            Dvbs2Mod.psk8 => autoSps8psk(baud),
            Dvbs2Mod.qpsk => autoSpsQpsk(baud),
          };
      if (m['error'] == true) {
        expect(sps, throwsA(isA<ConfigError>()), reason: '$m');
        continue;
      }
      final s = sps();
      expect(s, m['sps'], reason: '$m');
      final ba = outputBaud(baud, s, mod);
      expect(ba, closeTo((m['baud_act'] as num).toDouble(), 1e-6), reason: '$m');
      final cap = dvbs2TsRate(ba, m['fec'] as String, mod);
      expect(cap, closeTo((m['cap'] as num).toDouble(), 1e-6));
      if (m['cap_dvbs'] != null) expect(dvbsTsRate(ba, '1/2'), closeTo((m['cap_dvbs'] as num).toDouble(), 1e-6));
      final b = StreamBudget.forCapacity(cap);
      expect(b.muxRate, m['mux']);
      expect(b.audioKbps, m['aud']);
      expect(b.fps, m['fps']);
      expect(b.maxWidth, m['w']);
      expect(b.videoBitrate, m['vb']);
    }
  });

  test('command line as tx_dvbs.py builds it', () {
    const c = TxConfig(freqMhz: 2402, baud: 1000000, fec: '1/2');
    final p = TxPlan.of(c);
    expect(p.command, 'QPSKT 2402.000 1000000 8 300 86400 0 3000 -22 47 9994 79');
    final p2 = TxPlan.of(c.copyWith(standard: Standard.dvbs2, mod: Dvbs2Mod.apsk16, fec: '2/3', baud: 1000000));
    expect(p2.command, 'A16T 2402.000 1000000 8 420 86400 0 7000 -22 47 9994 79 315');
  });

  test('band check', () {
    expect(() => TxPlan.of(const TxConfig(freqMhz: 2300.2, baud: 1000000)), throwsA(isA<ConfigError>()));
    expect(() => TxPlan.of(const TxConfig(freqMhz: 2200)), throwsA(isA<ConfigError>()));
  });
}
