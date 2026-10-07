// ignore_for_file: avoid_print
// Dev-only hardware check: flashes the bundled firmware with the Dart flasher, then
// checks INFO. Usage (from app/): dart run tool/hw/flash_test.dart <port>
import 'dart:convert';
import 'dart:io';

import 'package:esp32_datv/core/esp/esp_link.dart';
import 'package:esp32_datv/core/esp/flasher.dart';
import 'package:esp32_datv/platform/serial/linux_serial.dart';

Future<void> main(List<String> args) async {
  final port = args[0];
  final dir = args.length > 1 ? args[1] : 'assets/firmware';
  final m = jsonDecode(File('$dir/manifest.json').readAsStringSync()) as Map<String, dynamic>;
  final images = [
    for (final i in (m['images'] as List).cast<Map<String, dynamic>>())
      FlashImage(i['file'] as String, i['offset'] as int, File('$dir/${i['file']}').readAsBytesSync(),
          md5: i['md5'] as String),
  ];
  var t = LinuxSerialTransport.open(port);
  final sw = Stopwatch()..start();
  var last = '';
  await EspFlasher(t).flash(images, progress: (s, f) {
    final l = '$s ${(f * 100).toStringAsFixed(0)}%';
    if (l != last && (f == 0 || f == 1 || (f * 100).round() % 10 == 0)) print(l);
    last = l;
  });
  print('flashed in ${sw.elapsedMilliseconds} ms');
  await t.close();
  await Future<void>.delayed(const Duration(milliseconds: 500));
  t = LinuxSerialTransport.open(port);
  final info = await EspLink(t).hello();
  print('INFO: ${info?.line}');
  await t.close();
}
