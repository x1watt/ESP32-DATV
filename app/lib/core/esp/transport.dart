import 'dart:typed_data';

/// A serial byte link to the board (USB CDC-ACM). Implementations: termios (Linux),
/// Win32 COM (Windows), usbdevfs (Android); Web Serial later.
abstract class ByteTransport {
  /// Whatever bytes are available now, waiting at most [timeout] for the first one.
  /// Returns an empty list when nothing arrived.
  Future<Uint8List> read({Duration timeout = Duration.zero});

  /// Writes all of [data]; completes once the OS accepted it. Throws [TransportError]
  /// when the device does not take data within [timeout].
  Future<void> write(Uint8List data, {Duration timeout = const Duration(seconds: 2)});

  /// Sets the modem control lines (the ESP32-C3 USB-Serial-JTAG maps them to reset and boot).
  Future<void> setSignals({bool? dtr, bool? rts});

  /// Discards pending input.
  Future<void> flushInput();

  Future<void> close();
}

class TransportError implements Exception {
  TransportError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A serial port found on the system.
class PortInfo {
  const PortInfo({
    required this.id,
    required this.name,
    this.vid,
    this.pid,
    this.serial,
    this.product,
    this.manufacturer,
  });

  /// What the platform transport needs to open it (a device path, COM name or USB device name).
  final String id;

  /// Display name.
  final String name;
  final int? vid, pid;
  final String? serial, product, manufacturer;

  /// Espressif's USB-Serial-JTAG (ESP32-C3/S3/C6/H2 native USB).
  bool get isEspressif => vid == 0x303A;

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'vid': vid,
        'pid': pid,
        'serial': serial,
        'product': product,
        'manufacturer': manufacturer,
      };

  static PortInfo fromJson(Map<String, dynamic> j) => PortInfo(
        id: j['id'] as String,
        name: j['name'] as String,
        vid: j['vid'] as int?,
        pid: j['pid'] as int?,
        serial: j['serial'] as String?,
        product: j['product'] as String?,
        manufacturer: j['manufacturer'] as String?,
      );

  @override
  String toString() {
    final ids = vid != null ? ' [${vid!.toRadixString(16).padLeft(4, '0')}:${pid?.toRadixString(16).padLeft(4, '0')}]' : '';
    return '$name$ids${serial != null ? ' $serial' : ''}';
  }
}
