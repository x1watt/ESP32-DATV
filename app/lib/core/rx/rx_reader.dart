/// Reads receive bursts from the C3 firmware's `RXSTREAM` over a [ByteTransport].
library;

import 'dart:convert';
import 'dart:typed_data';

import '../esp/esp_link.dart';
import '../esp/transport.dart';
import 'burst.dart';

/// Receive settings.
class RxConfig {
  const RxConfig({
    required this.freqMhz,
    this.rateMsps = 16,
    this.samples = 16380,
    this.gain = -1,
    this.baud = 125000,
    this.offsetHz = 0,
  });

  /// LO frequency.
  final double freqMhz;

  /// 16 (1 ms gap-free bursts) or 80 (205 us wide-band snapshots).
  final int rateMsps;

  /// Pairs per 80 MS/s snapshot (16..16380); a 16 MS/s burst is always 16383 pairs.
  final int samples;

  /// -1 = hardware AGC, else a fixed gain table index 0..127.
  final int gain;

  /// Expected symbol rate and offset of the signal from the LO (for the constellation).
  final double baud, offsetHz;

  String get command {
    final g = gain < 0 ? 'agc' : '$gain';
    return 'RXSTREAM ${freqMhz.toStringAsFixed(3)} $rateMsps ${rateMsps == 80 ? samples : 0} $g';
  }
}

class RxReader {
  RxReader(this.t);
  final ByteTransport t;
  final BytesBuilder _buf = BytesBuilder(copy: false);
  Uint8List _pending = Uint8List(0);
  int bad = 0;

  Future<void> start(RxConfig c) async {
    await t.flushInput();
    _pending = Uint8List(0);
    await t.write(Uint8List.fromList(ascii.encode('${c.command}\n')));
  }

  /// Asks the firmware to stop and waits for its RX END line.
  Future<String> stop() async {
    await t.write(Uint8List.fromList([0x0A]));
    final sw = Stopwatch()..start();
    while (sw.elapsedMilliseconds < 3000) {
      final b = await next(timeout: const Duration(milliseconds: 100));
      if (b is String && b.startsWith('RX END')) return b;
    }
    return 'no RX END';
  }

  Future<void> _fill(Duration timeout) async {
    final d = await t.read(timeout: timeout);
    if (d.isEmpty) return;
    _buf.add(_pending);
    _buf.add(d);
    _pending = _buf.takeBytes();
  }

  /// The next burst ([RxBurst]), text line ([String]), or null if nothing complete arrived.
  Future<Object?> next({Duration timeout = const Duration(milliseconds: 50)}) async {
    for (var round = 0; round < 2; round++) {
      final nl = _pending.indexOf(0x0A);
      if (nl >= 0) {
        final line = latin1.decode(Uint8List.sublistView(_pending, 0, nl)).trim();
        final h = RxHeader.parse(line);
        if (h == null) {
          _pending = Uint8List.sublistView(_pending, nl + 1);
          if (line.startsWith('ERR')) throw EspError('ESP: $line');
          if (line.isNotEmpty) return line;
          return null;
        }
        final need = nl + 1 + h.payloadBytes;
        while (_pending.length < need) {
          final before = _pending.length;
          await _fill(const Duration(milliseconds: 200));
          if (_pending.length == before) return null; // try again later
        }
        final payload = Uint8List.sublistView(_pending, nl + 1, need);
        final burst = decodeBurst(h, payload);
        _pending = Uint8List.sublistView(_pending, need);
        if (burst == null) {
          bad++;
          return null;
        }
        return burst;
      }
      await _fill(timeout);
    }
    return null;
  }
}
