// Full-length validation: demux sintel_trailer.mp4 with the Dart MP4
// demuxer, decode every frame with the Dart H.264 decoder and compare each
// frame with system ffmpeg's yuv420p output. Skipped if ffmpeg or the clip
// is missing. Frames are compared incrementally to keep memory low.
import 'dart:io';

import 'package:esp32_datv/core/codec/h264dec/h264dec.dart';
import 'package:esp32_datv/core/codec/mp4/mp4.dart';
import 'package:flutter_test/flutter_test.dart';

import 'h264_test_util.dart';

void main() {
  final enabled = ffmpegWithX264() && File(kSintel).existsSync();

  test('sintel_trailer.mp4 decodes bit-exact vs ffmpeg (all frames)', () async {
    final mp4 = await Mp4File.open(MemoryByteSource(File(kSintel).readAsBytesSync()));
    final track = mp4.firstVideoTrack!;
    final avc = track.avc!;
    expect(track.width, 854);
    expect(track.height, 480);

    final ref = await FfmpegReference.start(kSintel);
    final dec = H264Decoder();
    dec.decodeNals([...avc.sps, ...avc.pps]);
    final pts = <int>[];
    await for (final s in mp4.samples(track.id)) {
      final frames = dec.decodeNals(
        splitLengthPrefixedNals(s.data, avc.nalLengthSize),
        ptsUs: s.ptsUs,
      );
      for (final f in frames) {
        expect(f.width, 854);
        expect(f.height, 480);
        pts.add(f.ptsUs);
        await ref.check(f);
      }
    }
    for (final f in dec.flush()) {
      pts.add(f.ptsUs);
      await ref.check(f);
    }
    final extra = await ref.finish();
    expect(extra, isFalse, reason: 'ffmpeg produced more frames');
    expect(ref.frames, track.sampleCount);
    expect(ref.mismatches, 0, reason: ref.firstMismatch);
    expect(dec.errorCount, 0);
    // Output is in presentation order.
    for (var i = 1; i < pts.length; i++) {
      expect(pts[i], greaterThan(pts[i - 1]), reason: 'pts order at $i');
    }
  }, timeout: const Timeout(Duration(minutes: 15)),
      skip: enabled ? false : 'ffmpeg or sintel_trailer.mp4 not available');
}
