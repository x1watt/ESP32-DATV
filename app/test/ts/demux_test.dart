import 'dart:typed_data';

import 'package:esp32_datv/core/codec/h264dec/h264_decoder.dart';
import 'package:esp32_datv/core/codec/h264enc/h264_encoder.dart';
import 'package:esp32_datv/core/codec/image/convert.dart';
import 'package:esp32_datv/core/ts/demux.dart';
import 'package:esp32_datv/core/ts/mux.dart';
import 'package:test/test.dart';

void main() {
  test('demuxer reads the service and decodes the video the muxer sent', () {
    const w = 160, h = 96, fps = 10;
    final enc = H264Encoder(H264EncoderConfig(width: w, height: h, fps: fps, bitrate: 150000));
    final mux = TsMuxer(muxRate: 400000, serviceName: 'TEST CALL', providerName: 'Me', audio: StreamKind.mp2);
    final ts = BytesBuilder();
    for (var i = 0; i < 25; i++) {
      final f = testPattern(w, h, i, fps, ptsUs: i * 100000, text: 'HI');
      final out = enc.encode(f);
      mux.addVideo(out.data, ptsUs: f.ptsUs, key: out.keyframe);
      // a fake MPEG audio frame
      mux.addAudio(Uint8List.fromList([0xFF, 0xFD, 0x90, 0x00, ...List.filled(100, 0x55)]), ptsUs: f.ptsUs);
      while (mux.queuedBytes > 0) {
        ts.add(mux.take(8));
      }
    }
    ts.add(mux.take(64));
    final all = ts.takeBytes();

    final dec = H264Decoder();
    final frames = [];
    var audio = 0;
    late TsDemuxer d;
    d = TsDemuxer(
      onPes: (p) {
        final s = d.streams.firstWhere((s) => s.pid == p.pid);
        if (s.isVideo) {
          frames.addAll(dec.decode(p.data, ptsUs: p.ptsUs ?? 0));
        } else {
          audio++;
        }
      },
    );
    // odd chunk sizes exercise the packet carry
    for (var i = 0; i < all.length; i += 1000) {
      d.feed(Uint8List.sublistView(all, i, (i + 1000).clamp(0, all.length)));
    }
    d.flush();
    frames.addAll(dec.flush());

    expect(d.serviceName, 'TEST CALL');
    expect(d.providerName, 'Me');
    expect(d.streams.map((s) => s.label), ['H.264 video', 'MPEG audio']);
    expect(d.ccErrors + d.syncErrors + d.crcErrors, 0);
    expect(frames.length, 25);
    expect(frames.first.width, w);
    expect(frames.first.height, h);
    expect(audio, 25);
    expect(dec.errorCount, 0);
  });

  test('a continuity gap is counted and the broken packet dropped', () {
    final mux = TsMuxer(muxRate: 400000);
    final enc = H264Encoder(H264EncoderConfig(width: 64, height: 64, fps: 10, bitrate: 100000));
    for (var i = 0; i < 3; i++) {
      final out = enc.encode(testPattern(64, 64, i, 10, ptsUs: i * 100000));
      mux.addVideo(out.data, ptsUs: i * 100000, key: out.keyframe);
    }
    final pk = <Uint8List>[];
    while (mux.queuedBytes > 0) {
      final b = mux.take(1);
      pk.add(b);
    }
    // drop one video data packet in the middle
    final videoIdx = [
      for (var i = 0; i < pk.length; i++)
        if (((pk[i][1] & 0x1F) << 8 | pk[i][2]) == 0x100 && (pk[i][3] & 0x10) != 0) i,
    ];
    pk.removeAt(videoIdx[videoIdx.length ~/ 2]);
    final d = TsDemuxer(onPes: (_) {});
    for (final p in pk) {
      d.feed(p);
    }
    expect(d.ccErrors, 1);
  });
}
