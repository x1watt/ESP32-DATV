// ignore_for_file: avoid_print
// Dev-only end-to-end check without the UI: test pattern (or null packets) through the
// encoder, mux, DVB encoder and pacer to the board.
// Usage (from app/): dart run tool/hw/e2e.dart <port> <dvbs|qpsk|8psk|16apsk> <baud> <secs> [fec]
import 'dart:async';

import 'package:esp32_datv/core/dvb/dvbs2.dart';
import 'package:esp32_datv/core/esp/transport.dart';
import 'package:esp32_datv/core/esp/tx_config.dart';
import 'package:esp32_datv/engine/engine.dart';
import 'package:esp32_datv/engine/transport_factory.dart';

Future<void> main(List<String> a) async {
  var c = TxConfig(freqMhz: 2370, baud: int.parse(a[2]), seconds: int.parse(a[3]));
  if (a[1] != 'dvbs') {
    c = c.copyWith(standard: Standard.dvbs2, mod: {'qpsk': Dvbs2Mod.qpsk, '8psk': Dvbs2Mod.psk8, '16apsk': Dvbs2Mod.apsk16}[a[1]]);
  }
  if (a.length > 4) c = c.copyWith(fec: a[4]);
  final plan = TxPlan.of(c);
  final b = plan.budget();
  print('${plan.label} cap ${(plan.capacity / 1000).toStringAsFixed(1)} kb/s, video ${b.videoBitrate} b/s '
      '${b.maxWidth}px ${b.fps} fps, audio ${b.audioKbps}k');
  final s = await DeviceSession.open(PortInfo(id: a[0], name: a[0]), TransportSpec.path(a[0]));
  final h = await s.hello();
  print('hello: ${h.line}');
  final done = Completer<void>();
  var last = 0.0;
  s.statusStream.listen((st) {
    if (st.endSummary != null || st.error != null) {
      if (!done.isCompleted) done.complete();
      return;
    }
    if (st.secs - last >= 2) {
      last = st.secs;
      print('t ${st.secs.toStringAsFixed(1)} fill ${st.fillMin}..${st.fillMax}/${st.target} under ${st.under} '
          'mux data ${st.muxData} null ${st.muxNull} late ${st.muxLate} buf ${st.buffered.toStringAsFixed(2)}s | '
          '${st.fileInfo ?? ''} enc ${st.encW}x${st.encH} ${st.encFps.toStringAsFixed(1)} fps ${st.encKbps.toStringAsFixed(0)} kb/s qp ${st.encQp} drop ${st.encDropped}');
    }
  });
  final src = a.length > 5 ? a[5] : 'test';
  final kind = src == 'null'
      ? SourceKind.nullPackets
      : src == 'test'
          ? SourceKind.testPattern
          : SourceKind.file;
  await s.startTx(c, SourceSpec(kind: kind, filePath: kind == SourceKind.file ? src : null));
  await done.future;
  print('end: ${s.status.endSummary} ${s.status.error ?? ''}');
  await s.close();
}
