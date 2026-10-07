/// The USB link to the ESP32-DATV firmware (port of `host/esp_link.py`).
///
/// Text commands go down, a raw symbol stream goes down after the TX command, and the ESP
/// sends back 4-byte fill reports (0xB7, fill_lo, fill_hi, underruns) interleaved with text.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'transport.dart';

class EspError implements Exception {
  EspError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Firmware identification from the INFO reply ("ESP32DATV 1").
class FirmwareInfo {
  const FirmwareInfo(this.version, this.line);
  final int version;
  final String line;
}

/// Parsed "OK QPSKT LO ... BAUD ... OUT ..." line.
class TxStarted {
  TxStarted(this.line) : kv = _kv(line);
  final String line;
  final Map<String, String> kv;

  static Map<String, String> _kv(String line) {
    final p = line.trim().split(RegExp(r'\s+'));
    final m = <String, String>{};
    for (var i = 2; i + 1 < p.length; i += 2) {
      m[p[i]] = p[i + 1];
    }
    return m;
  }

  double get loHz => double.tryParse(kv['LO'] ?? '') ?? 0;
  double get baud => double.tryParse(kv['BAUD'] ?? '') ?? 0;
  int get outRate => int.tryParse(kv['OUT'] ?? '') ?? 0;
  String get modulation => kv['MOD'] ?? '';
}

Future<void> _sleep(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

class EspLink {
  EspLink(this.t);

  final ByteTransport t;
  final List<int> _buf = [];
  final StringBuffer _text = StringBuffer();

  /// Symbol pairs (2 bytes) in the ESP ring at the last report.
  int fill = 0;

  /// Ring underruns (saturates at 255).
  int under = 0;

  /// Pairs sent since the last report.
  int sentSince = 0;
  int reports = 0;

  String get text => _text.toString();

  void clearText() => _text.clear();

  /// Sends INFO until the firmware answers. Returns null if it never does.
  Future<FirmwareInfo?> hello({int tries = 8, int bootWaitMs = 1200}) async {
    await _sleep(bootWaitMs);
    for (var i = 0; i < tries; i++) {
      try {
        await t.write(Uint8List.fromList(ascii.encode('\nINFO\n')), timeout: const Duration(milliseconds: 700));
      } on TransportError {
        // the board does not read USB (no or other firmware)
        await _sleep(200);
        continue;
      }
      final sw = Stopwatch()..start();
      while (sw.elapsedMilliseconds < 700) {
        await poll(timeout: const Duration(milliseconds: 20));
        final m = RegExp(r'ESP32DATV\s+(\d+)').firstMatch(text);
        if (m != null) {
          await _sleep(100);
          await t.flushInput();
          _buf.clear();
          final line = text.split(RegExp(r'[\r\n]+')).firstWhere((l) => l.contains('ESP32DATV'), orElse: () => m[0]!);
          _text.clear();
          return FirmwareInfo(int.parse(m[1]!), line.trim());
        }
      }
    }
    return null;
  }

  /// Reads what is there and splits fill reports from text.
  Future<void> poll({Duration timeout = Duration.zero}) async {
    final data = await t.read(timeout: timeout);
    if (data.isNotEmpty) _buf.addAll(data);
    var i = 0;
    while (i < _buf.length) {
      if (_buf[i] == 0xB7) {
        if (i + 4 > _buf.length) break;
        fill = _buf[i + 1] | (_buf[i + 2] << 8);
        under = _buf[i + 3];
        sentSince = 0;
        reports++;
        i += 4;
      } else {
        _text.writeCharCode(_buf[i]);
        i++;
      }
    }
    _buf.removeRange(0, i);
  }

  /// Sends a simple command and returns the first reply line.
  Future<String> query(String cmd, {Duration timeout = const Duration(seconds: 2)}) async {
    _text.clear();
    await t.write(Uint8List.fromList(ascii.encode('$cmd\n')));
    final sw = Stopwatch()..start();
    while (sw.elapsed < timeout) {
      await poll(timeout: const Duration(milliseconds: 20));
      final s = text;
      final nl = s.indexOf('\n');
      if (nl >= 0) return s.substring(0, nl).trim();
    }
    throw EspError('No answer to $cmd');
  }

  /// Sends a TX command and waits for its "OK QPSKT ..." line or an ERR.
  Future<TxStarted> start(String cmd, {Duration timeout = const Duration(seconds: 8)}) async {
    _text.clear();
    fill = 0;
    under = 0;
    sentSince = 0;
    reports = 0;
    await t.write(Uint8List.fromList(ascii.encode('$cmd\n')));
    final sw = Stopwatch()..start();
    while (sw.elapsed < timeout) {
      await poll(timeout: const Duration(milliseconds: 10));
      for (final ln in const LineSplitter().convert(text)) {
        if (ln.startsWith('OK QPSKT')) return TxStarted(ln);
        if (ln.startsWith('ERR')) {
          final hint = ln.contains('out of memory')
              ? ' (firmware built with ESP-IDF 5.x has too little contiguous heap for this rate: '
                  'install the bundled firmware)'
              : '';
          throw EspError('ESP: $ln$hint');
        }
      }
    }
    final s = text;
    throw EspError('No answer from the ESP: ${s.length > 200 ? s.substring(s.length - 200) : s}');
  }

  Future<void> send(Uint8List data) => t.write(data);

  /// Waits for the TX END summary (the ESP stops 0.5 s after the last byte).
  Future<String> finish({Duration timeout = const Duration(seconds: 5), bool sendStop = true}) async {
    if (sendStop) {
      try {
        await t.write(Uint8List.fromList([0xA5, 0xFF]), timeout: const Duration(milliseconds: 300));
      } on TransportError {
        // ignore
      }
    }
    final sw = Stopwatch()..start();
    while (sw.elapsed < timeout) {
      await poll(timeout: const Duration(milliseconds: 20));
      final s = text;
      if (s.contains('TX END') && s.trimRight().endsWith(')')) break;
    }
    final lines = const LineSplitter().convert(text).where((l) => l.contains('TX END')).toList();
    return lines.isEmpty ? 'no summary from the ESP' : lines.join('\n').trim();
  }
}
