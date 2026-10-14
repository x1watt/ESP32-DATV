/// Receive bursts from the C3 firmware (`RX` / `RXSTREAM`, see firmware/main/rx_burst.h).
library;

import 'dart:typed_data';

import '../ts/crc32_zlib.dart';

/// One burst of complex samples, interleaved re/im, scaled to +-1 (10-bit full scale).
/// The ESP delivers LO minus RF; samples are conjugated here so that positive
/// frequencies are above the LO, like any other receiver.
class RxBurst {
  RxBurst(this.iq, this.sampleRate, this.loHz, this.gain);
  final Float32List iq;
  final double sampleRate;
  final double loHz;

  /// Receiver gain table index the AGC (or the fixed setting) used.
  final int gain;

  int get length => iq.length ~/ 2;
}

/// Header line `RXDATA n rate lo_hz gain crc32`.
class RxHeader {
  RxHeader(this.n, this.rateMsps, this.loHz, this.gain, this.crc);
  final int n, rateMsps, gain, crc;
  final double loHz;

  int get payloadBytes => (n * 20 + 7) ~/ 8;

  static RxHeader? parse(String line) {
    final p = line.trim().split(RegExp(r'\s+'));
    if (p.length != 6 || p[0] != 'RXDATA') return null;
    final n = int.tryParse(p[1]), r = int.tryParse(p[2]), lo = double.tryParse(p[3]);
    final g = int.tryParse(p[4]), c = int.tryParse(p[5], radix: 16);
    if (n == null || r == null || lo == null || g == null || c == null) return null;
    return RxHeader(n, r, lo, g, c);
  }
}

/// Unpacks [h.n] 20-bit pairs (two pairs in five bytes, little-endian: I0 Q0 I1 Q1).
/// Returns null when the CRC does not match.
RxBurst? decodeBurst(RxHeader h, Uint8List payload) {
  if (payload.length < h.payloadBytes) return null;
  if (crc32Zlib(payload, 0, h.payloadBytes) != h.crc) return null;
  final out = Float32List(2 * h.n);
  const scale = 1 / 512;
  int s10(int x) => (x & 0x200) != 0 ? (x & 0x3ff) - 1024 : x & 0x3ff;
  for (var j = 0, o = 0; j < h.n; j += 2, o += 5) {
    final a = payload[o] | (payload[o + 1] << 8) | ((payload[o + 2] & 15) << 16);
    out[2 * j] = s10(a) * scale;
    out[2 * j + 1] = -s10(a >> 10) * scale; // conjugate: RF above the LO at positive frequency
    if (j + 1 < h.n) {
      final b = (payload[o + 2] >> 4) | (payload[o + 3] << 4) | (payload[o + 4] << 12);
      out[2 * j + 2] = s10(b) * scale;
      out[2 * j + 3] = -s10(b >> 10) * scale;
    }
  }
  return RxBurst(out, h.rateMsps * 1e6, h.loHz, h.gain);
}
