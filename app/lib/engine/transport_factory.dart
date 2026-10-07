import 'dart:io';

import '../core/esp/transport.dart';
import '../platform/serial/android_usb.dart';
import '../platform/serial/linux_serial.dart';
import '../platform/serial/windows_serial.dart';

/// How to open a port inside an isolate (plain data, sendable between isolates).
class TransportSpec {
  const TransportSpec.path(this.id) : fd = -1, epIn = 0, epOut = 0, iface = 0, maxPacket = 64;
  const TransportSpec.androidFd(this.id, {required this.fd, required this.epIn, required this.epOut, required this.iface, this.maxPacket = 64});

  /// Device path (Linux), COM name (Windows) or USB device name (Android).
  final String id;

  /// Android: the usbdevfs file descriptor from UsbDeviceConnection.
  final int fd;
  final int epIn, epOut, iface, maxPacket;
}

Future<ByteTransport> openTransport(TransportSpec s) async {
  if (Platform.isAndroid) {
    return AndroidUsbTransport.open(fd: s.fd, epIn: s.epIn, epOut: s.epOut, iface: s.iface, maxPacket: s.maxPacket);
  }
  if (Platform.isWindows) return WindowsSerialTransport.open(s.id);
  return LinuxSerialTransport.open(s.id);
}
