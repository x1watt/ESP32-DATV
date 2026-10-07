// ignore_for_file: avoid_print
// Dev-only hardware check: streams null packets for N seconds and prints the ESP buffer.
// Usage (from app/): dart run tool/hw/tx_null.dart <port> <dvbs|qpsk|8psk|16apsk> <baud> <secs>
import 'dart:typed_data';

import 'package:esp32_datv/core/dvb/dvbs.dart';
import 'package:esp32_datv/core/dvb/dvbs2.dart';
import 'package:esp32_datv/core/dvb/ts_const.dart';
import 'package:esp32_datv/core/esp/esp_link.dart';
import 'package:esp32_datv/core/esp/tx_config.dart';
import 'package:esp32_datv/core/pipeline/pacer.dart';
import 'package:esp32_datv/platform/serial/linux_serial.dart';

Future<void> main(List<String> a) async {
  final m = a[1];
  var c = TxConfig(freqMhz: 2370, baud: int.parse(a[2]), seconds: int.parse(a[3]));
  if (m != 'dvbs') {
    c = c.copyWith(standard: Standard.dvbs2, mod: {'qpsk': Dvbs2Mod.qpsk, '8psk': Dvbs2Mod.psk8, '16apsk': Dvbs2Mod.apsk16}[m]);
  }
  final plan = TxPlan.of(c);
  print('${plan.label} ${plan.command}');
  final ts = Uint8List(188 * 8);
  for (var i = 0; i < 8; i++) {
    ts.setAll(188 * i, nullPacket);
  }
  final Uint8List Function(Uint8List) enc = c.standard == Standard.dvbs
      ? DvbsEncoder(fec: c.fec).encode
      : Dvbs2Encoder(fec: c.fec, mod: c.mod, bits3: plan.bits3).encode;
  final t = LinuxSerialTransport.open(a[0]);
  final link = EspLink(t);
  print('INFO ${(await link.hello())?.line}');
  final st = await link.start(plan.command);
  print(st.line);
  final pacer = Pacer(link, plan, (w) => enc(ts));
  await pacer.run(onStats: (s) {
    if (true) {
      print('fill ${s.fillMin}..${s.fillMax}/${s.target} under ${s.underruns} ${s.kBytesPerSecond.toStringAsFixed(1)} kB/s');
    }
  });
  print(await link.finish(sendStop: !plan.a16s8));
  await t.close();
}
