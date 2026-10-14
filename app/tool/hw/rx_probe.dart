// ignore_for_file: avoid_print
// Dev-only: receives bursts with the C3 and prints the QPSK analysis.
// Usage (from app/): dart run tool/hw/rx_probe.dart <port> <f_MHz> <baud> <offset_kHz> [bursts] [gain]
import 'package:esp32_datv/core/esp/esp_link.dart';
import 'package:esp32_datv/core/rx/burst.dart';
import 'package:esp32_datv/core/rx/qpsk_analyzer.dart';
import 'package:esp32_datv/core/rx/rx_reader.dart';
import 'package:esp32_datv/platform/serial/linux_serial.dart';

Future<void> main(List<String> a) async {
  final t = LinuxSerialTransport.open(a[0]);
  final info = await EspLink(t).hello();
  print('INFO ${info?.line}');
  final cfg = RxConfig(
    freqMhz: double.parse(a[1]),
    baud: double.parse(a[2]),
    offsetHz: double.parse(a[3]) * 1e3,
    gain: a.length > 5 ? int.parse(a[5]) : -1,
  );
  final r = RxReader(t);
  await r.start(cfg);
  final want = a.length > 4 ? int.parse(a[4]) : 10;
  var got = 0;
  final sw = Stopwatch()..start();
  while (got < want && sw.elapsed.inSeconds < 30) {
    final x = await r.next();
    if (x is RxBurst) {
      got++;
      final q = analyzeQpsk(x.iq, x.sampleRate, cfg.offsetHz, cfg.baud);
      print('burst $got: ${x.length} pairs gain ${x.gain} level ${q.levelDbfs.toStringAsFixed(1)} dBFS | '
          'centre ${(q.centreOffsetHz / 1e3).toStringAsFixed(1)} kHz SNR ${q.snrDb.toStringAsFixed(1)} dB '
          'MER ${q.merDb.toStringAsFixed(1)} dB (${q.symbols.length ~/ 2} symbols)');
    } else if (x is String) {
      print('text: $x');
    }
  }
  print('${(got / sw.elapsedMilliseconds * 1000).toStringAsFixed(1)} bursts/s, crc errors ${r.bad}');
  print(await r.stop());
  await t.close();
}
