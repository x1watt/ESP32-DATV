import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/esp/transport.dart';
import '../../engine/transport_factory.dart';
import 'linux_serial.dart';
import 'windows_serial.dart';

const MethodChannel _usb = MethodChannel('datv/usb');

/// Serial ports on this system, Espressif boards first.
Future<List<PortInfo>> listPorts() async {
  List<PortInfo> ports;
  if (Platform.isAndroid) {
    final l = (await _usb.invokeListMethod<Map>('list')) ?? [];
    ports = [
      for (final d in l)
        PortInfo(
          id: d['name'] as String,
          name: (d['product'] as String?) ?? (d['name'] as String),
          vid: d['vid'] as int?,
          pid: d['pid'] as int?,
          serial: d['serial'] as String?,
          product: d['product'] as String?,
          manufacturer: d['manufacturer'] as String?,
        ),
    ];
  } else if (Platform.isWindows) {
    ports = listWindowsPorts();
  } else {
    ports = listLinuxPorts();
  }
  ports.sort((a, b) => (a.isEspressif == b.isEspressif) ? 0 : (a.isEspressif ? -1 : 1));
  return ports;
}

/// What a link isolate needs to open [p]. On Android this asks for USB permission and
/// claims the device on the main isolate first.
Future<TransportSpec> prepareTransport(PortInfo p) async {
  if (!Platform.isAndroid) return TransportSpec.path(p.id);
  final r = await _usb.invokeMapMethod<String, Object?>('open', {'name': p.id});
  if (r == null) throw TransportError('Cannot open ${p.name}');
  return TransportSpec.androidFd(p.id,
      fd: r['fd'] as int,
      epIn: r['epIn'] as int,
      epOut: r['epOut'] as int,
      iface: r['iface'] as int,
      maxPacket: r['maxPacket'] as int? ?? 64);
}

Future<void> releaseTransport(PortInfo p) async {
  if (Platform.isAndroid) await _usb.invokeMethod('close', {'name': p.id});
}
