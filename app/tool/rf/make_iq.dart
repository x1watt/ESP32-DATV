// ignore_for_file: avoid_print
// Dev-only: writes a HackRF transmit file (signed 8-bit I/Q) with a DVB-S or DVB-S2 QPSK
// signal of null packets (or a carrier), RRC-shaped with roll-off 0.35, to test the receiver.
//
//   dart run tool/rf/make_iq.dart <out.s8> <dvbs|dvbs2|cw> <baud> <sample_rate> [seconds] [fec]
//   hackrf_transfer -t out.s8 -f <Hz> -s <sample_rate> -x 30 -a 0 -R
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:esp32_datv/core/dvb/dvbs.dart';
import 'package:esp32_datv/core/dvb/dvbs2.dart';
import 'package:esp32_datv/core/dvb/ts_const.dart';

double rrc(double t, double b) {
  if (t.abs() < 1e-9) return 1 - b + 4 * b / math.pi;
  if ((t.abs() - 1 / (4 * b)).abs() < 1e-6) {
    return b / math.sqrt2 * ((1 + 2 / math.pi) * math.sin(math.pi / (4 * b)) + (1 - 2 / math.pi) * math.cos(math.pi / (4 * b)));
  }
  return (math.sin(math.pi * t * (1 - b)) + 4 * b * t * math.cos(math.pi * t * (1 + b))) /
      (math.pi * t * (1 - (4 * b * t) * (4 * b * t)));
}

void main(List<String> a) {
  if (a.length < 4) {
    print('usage: make_iq.dart <out.s8> <dvbs|dvbs2|cw> <baud> <sample_rate> [seconds] [fec]');
    exit(2);
  }
  final out = a[0], kind = a[1];
  final baud = int.parse(a[2]), fs = int.parse(a[3]);
  final seconds = a.length > 4 ? double.parse(a[4]) : 2.0;
  final fec = a.length > 5 ? a[5] : '1/2';
  final nOut = (fs * seconds).round();
  final iq = Int8List(nOut * 2);
  if (kind == 'cw') {
    for (var i = 0; i < nOut; i++) {
      iq[2 * i] = 100;
    }
    File(out).writeAsBytesSync(iq);
    return;
  }
  if (fs % baud != 0) throw ArgumentError('sample rate must be a multiple of the symbol rate');
  final sps = fs ~/ baud;
  final nSym = nOut ~/ sps + 64;
  // QPSK levels from the encoder (4 symbols per byte, bit 0 = I level, bit 1 = Q level, 1 = +1)
  final Uint8List Function(Uint8List) enc =
      kind == 'dvbs2' ? Dvbs2Encoder(fec: fec).encode : DvbsEncoder(fec: fec).encode;
  final ts = Uint8List(188 * 8);
  for (var i = 0; i < 8; i++) {
    ts.setAll(188 * i, nullPacket);
  }
  final si = Float64List(nSym), sq = Float64List(nSym);
  var k = 0;
  while (k < nSym) {
    for (final byte in enc(ts)) {
      for (var j = 0; j < 4 && k < nSym; j++) {
        final s = (byte >> (2 * j)) & 3;
        si[k] = (s & 1) != 0 ? 1.0 : -1.0;
        sq[k] = (s & 2) != 0 ? 1.0 : -1.0;
        k++;
      }
    }
  }
  // RRC pulse over +-8 symbols
  const span = 8;
  final taps = Float64List(2 * span * sps + 1);
  for (var i = 0; i < taps.length; i++) {
    taps[i] = rrc((i - span * sps) / sps, 0.35);
  }
  final yi = Float64List(nOut), yq = Float64List(nOut);
  for (var s = 0; s < nSym; s++) {
    final c = s * sps;
    for (var t = 0; t < taps.length; t++) {
      final n = c + t - span * sps;
      if (n < 0 || n >= nOut) continue;
      yi[n] += si[s] * taps[t];
      yq[n] += sq[s] * taps[t];
    }
  }
  var peak = 0.0;
  for (var n = 0; n < nOut; n++) {
    peak = math.max(peak, math.max(yi[n].abs(), yq[n].abs()));
  }
  final g = 110 / peak;
  for (var n = 0; n < nOut; n++) {
    iq[2 * n] = (yi[n] * g).round().clamp(-127, 127);
    iq[2 * n + 1] = (yq[n] * g).round().clamp(-127, 127);
  }
  File(out).writeAsBytesSync(iq);
  print('$kind $baud Bd, $sps samples per symbol at $fs S/s, ${seconds}s -> $out');
}
