/// Keeps the ESP's symbol ring at its target fill (the main loop of `host/tx_dvbs.py`).
library;

import 'dart:async';
import 'dart:typed_data';

import '../dvb/dvbs2.dart';
import '../esp/esp_link.dart';
import '../esp/tx_config.dart';

/// Supplies packed symbol bytes; returns null when nothing is ready within [wait].
typedef SymbolPull = FutureOr<Uint8List?> Function(Duration wait);

class PacerStats {
  PacerStats({
    required this.fillMin,
    required this.fillMax,
    required this.underruns,
    required this.bytesSent,
    required this.elapsed,
    required this.target,
  });

  final int fillMin, fillMax, underruns, bytesSent, target;
  final Duration elapsed;

  double get kBytesPerSecond => elapsed.inMicroseconds == 0 ? 0 : bytesSent / elapsed.inMicroseconds * 1e3;
}

class Pacer {
  Pacer(this.link, this.plan, this.pull);

  final EspLink link;
  final TxPlan plan;
  final SymbolPull pull;
  bool _stop = false;

  void stop() => _stop = true;

  /// Bytes per second the ESP consumes.
  double get consumeRate {
    final bitsPerSym = switch (plan.mod) {
      Dvbs2Mod.qpsk => 2,
      Dvbs2Mod.psk8 => plan.bits3 ? 3 : 4,
      Dvbs2Mod.apsk16 => 4,
    };
    return plan.baudAct * bitsPerSym / 8;
  }

  /// Streams until [stop] (or the configured duration). Calls [onStats] about twice a second.
  ///
  /// Writes return long before the ESP has the bytes (kernel and USB buffers hold tens of
  /// kB), so "fill + bytes sent since the report" overshoots at low symbol rates. Instead the
  /// pacer sends at the exact consumption rate, starts with the target fill as a credit, and
  /// corrects slowly towards the target from the fill reports.
  Future<void> run({void Function(PacerStats)? onStats}) async {
    final (minTodo, maxChunk) = plan.chunking;
    final target = plan.target;
    final a16s8 = plan.a16s8;
    final seconds = plan.config.seconds;
    final rate = consumeRate;
    const kp = 2.0; // 1/s: the fill error is corrected within about half a second
    final buf = BytesBuilder(copy: false);
    Uint8List pending = Uint8List(0);
    final sw = Stopwatch()..start();
    var tRep = 0;
    var fmin = 1 << 30, fmax = 0, sent = 0;
    var credit = 2.0 * target; // bytes we may send now
    var lastUs = 0;
    var lastReports = link.reports;
    var lastReportUs = 0;
    while (!_stop && (seconds == 0 || sw.elapsedMilliseconds < seconds * 1000)) {
      await link.poll();
      final nowUs = sw.elapsedMicroseconds;
      credit += rate * (nowUs - lastUs) / 1e6;
      lastUs = nowUs;
      if (link.reports != lastReports) {
        lastReports = link.reports;
        if (link.fill < fmin) fmin = link.fill;
        if (link.fill > fmax) fmax = link.fill;
        final dt = (nowUs - lastReportUs) / 1e6;
        lastReportUs = nowUs;
        credit += 2.0 * (target - link.fill) * kp * (dt < 0.1 ? dt : 0.1);
      }
      if (credit > 4.0 * target) credit = 4.0 * target;
      final todo = credit ~/ 2; // pairs
      if (todo >= minTodo) {
        var nb = 2 * (todo < maxChunk ? todo : maxChunk);
        if (pending.length < nb) {
          buf.add(pending);
          var have = pending.length;
          while (have < nb) {
            final d = await pull(const Duration(milliseconds: 50));
            if (d == null || d.isEmpty) break;
            buf.add(d);
            have += d.length;
          }
          pending = buf.takeBytes();
        }
        if (nb > pending.length) nb = pending.length;
        if (a16s8) nb -= nb % 64; // full USB packets for the 1 MBd 16APSK loop
        if (nb > 0) {
          await link.send(Uint8List.sublistView(pending, 0, nb));
          pending = Uint8List.sublistView(pending, nb);
          credit -= nb;
          sent += nb;
        }
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 1)); // lets port messages in
      }
      if (sw.elapsedMilliseconds - tRep >= 500) {
        onStats?.call(PacerStats(
          fillMin: fmin == 1 << 30 ? 0 : fmin,
          fillMax: fmax,
          underruns: link.under,
          bytesSent: sent,
          elapsed: sw.elapsed,
          target: target,
        ));
        fmin = 1 << 30;
        fmax = 0;
        tRep = sw.elapsedMilliseconds;
      }
    }
  }
}
