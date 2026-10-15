import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:esp32_datv/core/codec/h264enc/h264_encoder.dart';
import 'package:esp32_datv/core/codec/image/convert.dart';
import 'package:esp32_datv/core/ts/mux.dart';
import 'package:esp32_datv/engine/monitor_isolate.dart';
import 'package:test/test.dart';

void main() {
  test('the monitor isolate shows the transmitted picture and stream contents', () async {
    const w = 320, h = 180, fps = 10;
    final enc = H264Encoder(H264EncoderConfig(width: w, height: h, fps: fps, bitrate: 200000));
    final mux = TsMuxer(muxRate: 400000, serviceName: 'MONITOR TEST');
    final ts = BytesBuilder();
    for (var i = 0; i < 30; i++) {
      final f = testPattern(w, h, i, fps, ptsUs: i * 100000, text: 'ON AIR');
      final out = enc.encode(f);
      mux.addVideo(out.data, ptsUs: f.ptsUs, key: out.keyframe);
      while (mux.queuedBytes > 0) {
        ts.add(mux.take(8));
      }
    }
    final all = ts.takeBytes();

    final events = ReceivePort();
    final acks = ReceivePort();
    final ready = Completer<SendPort>();
    final previews = <Map>[];
    final infos = <Map>[];
    events.listen((m) {
      m as Map;
      switch (m['ev']) {
        case 'monitorReady':
          ready.complete(m['port'] as SendPort);
        case 'preview':
          previews.add(m);
        case 'monitorInfo':
          infos.add(m);
        case 'isolateError':
          fail('${m['msg']}');
      }
    });
    final iso = await Isolate.spawn(monitorIsolateMain, MonitorIsolateArgs(events.sendPort));
    final port = await ready.future;
    // chunks as the link sends them, paced over a little more than a second
    const chunk = 188 * 64;
    for (var i = 0; i < all.length; i += chunk) {
      port.send({
        'k': 'ts',
        'data': TransferableTypedData.fromList([Uint8List.sublistView(all, i, (i + chunk).clamp(0, all.length))]),
        'gap': false,
        'ack': acks.sendPort,
      });
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    // more null packets so that the last info is sent
    for (var i = 0; i < 20; i++) {
      port.send({
        'k': 'ts',
        'data': TransferableTypedData.fromList([mux.take(64)]),
        'gap': false,
      });
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    port.send({'k': 'stop'});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    iso.kill();
    events.close();
    acks.close();

    expect(previews, isNotEmpty);
    final p = previews.last;
    final rgba = (p['data'] as TransferableTypedData).materialize().asUint8List();
    expect(p['w'], w);
    expect(p['h'], h);
    expect(rgba.length, w * h * 4);
    // colour bars: the picture is not flat
    final top = [
      for (var x = 20; x < w; x += 40)
        (rgba[(10 * w + x) * 4] >> 5, rgba[(10 * w + x) * 4 + 1] >> 5, rgba[(10 * w + x) * 4 + 2] >> 5),
    ];
    expect(top.toSet().length, greaterThan(5));
    final info = infos.last;
    expect(info['service'], 'MONITOR TEST');
    expect(info['streams'], ['H.264 video (PID 0x0100)']);
    expect(info['frames'], greaterThanOrEqualTo(29));
    expect(info['w'], w);
    expect(info['decErrors'], 0);
    expect(info['ccErrors'], 0);
  });
}
