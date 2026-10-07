// Conformance against an independent decoder: the system ffmpeg must decode
// every stream without a single error, produce the same number of frames and
// a picture that is bit-identical to the encoder's own reconstruction (no
// drift), with reasonable PSNR, bitrate and a never overflowed VBV.

import 'dart:io';
import 'dart:typed_data';

import 'package:esp32_datv/core/codec/h264enc/h264_encoder.dart';
import 'package:test/test.dart';

import 'synth_source.dart';
import 'test_util.dart';

class _Case {
  const _Case(this.w, this.h, this.fps, this.bitrate, this.frames,
      this.minPsnr,
      {this.preset = H264Preset.medium, this.checkRate = true});
  final int w, h, fps, bitrate, frames;
  final double minPsnr;
  final H264Preset preset;
  final bool checkRate;

  String get name => '${w}x$h ${fps}fps ${bitrate ~/ 1000}k ${preset.name}';
}

void main() {
  final skip = ffmpegAvailable() ? false : 'ffmpeg not installed';
  late Directory tmp;
  setUpAll(() => tmp = Directory.systemTemp.createTempSync('h264enc_'));
  tearDownAll(() => tmp.deleteSync(recursive: true));

  const cases = [
    // 10 s at the main operating point.
    _Case(640, 360, 25, 1000000, 250, 30),
    _Case(640, 360, 25, 1000000, 100, 30, preset: H264Preset.fast),
    _Case(320, 180, 15, 300000, 150, 30),
    _Case(854, 480, 25, 2000000, 50, 30, checkRate: false),
    _Case(176, 144, 10, 100000, 100, 25),
    // Tiny bitrates: mostly P_Skip, still conformant and within the VBV.
    _Case(160, 90, 10, 40000, 100, 18),
    _Case(160, 90, 10, 6000, 100, 5, checkRate: false),
    // Odd macroblock counts and cropping on both axes.
    _Case(202, 98, 12, 150000, 40, 25, checkRate: false),
  ];

  for (final c in cases) {
    test('ffmpeg decode ${c.name}', () {
      final cfg = H264EncoderConfig(
          width: c.w,
          height: c.h,
          fps: c.fps,
          bitrate: c.bitrate,
          preset: c.preset);
      final enc = H264Encoder(cfg);
      final src = SynthSource(c.w, c.h);
      final stream = BytesBuilder(copy: false);
      final srcYuv = BytesBuilder(copy: false);
      final recYuv = BytesBuilder(copy: false);
      var keyframes = 0;
      for (var i = 0; i < c.frames; i++) {
        final f = src.frame(i, fps: c.fps);
        final au = enc.encode(f);
        if (au.keyframe) keyframes++;
        stream.add(au.data);
        appendFrame(srcYuv, f);
        appendFrame(recYuv, enc.reconstruction());
      }
      final bytes = stream.toBytes();
      final name = c.name.replaceAll(' ', '_');
      final dec = ffmpegDecode(bytes, tmp, name);
      expect(dec.exitCode, 0, reason: dec.stderr);
      expect(dec.stderr, isEmpty);
      expect(dec.frameCount(c.w, c.h), c.frames);
      final rec = recYuv.toBytes();
      expect(firstDifference(dec.yuv, rec), -1,
          reason: 'decoder output differs from encoder reconstruction');
      final (avg, mn) = psnrStats(srcYuv.toBytes(), dec.yuv, c.w, c.h);
      final kbps = bytes.length * 8 * c.fps / c.frames / 1000;
      final info = ffprobeInfo(tmp, name);
      // ignore: avoid_print
      print('${c.name}: PSNR avg ${avg.toStringAsFixed(2)} min '
          '${mn.toStringAsFixed(2)} dB, ${kbps.toStringAsFixed(1)} kb/s, '
          'IDR $keyframes, vbv peak ${enc.vbvPeak.round()}/${cfg.vbvBits}, '
          'profile ${info?['profile']} level ${info?['level']}');
      expect(avg, greaterThan(c.minPsnr));
      expect(enc.vbvPeak, lessThanOrEqualTo(cfg.vbvBits));
      expect(enc.vbvViolations, 0);
      if (c.checkRate) {
        expect(kbps * 1000, inInclusiveRange(c.bitrate * 0.9, c.bitrate * 1.0));
      }
      if (info != null) {
        expect(info['profile'], 'Constrained Baseline');
        expect(info['width'], '${c.w}');
        expect(info['height'], '${c.h}');
      }
    }, skip: skip, timeout: const Timeout(Duration(minutes: 10)));
  }

  test('forced IDR and short GOP decode cleanly', () {
    final enc = H264Encoder(H264EncoderConfig(
        width: 128, height: 96, fps: 10, bitrate: 200000, gopFrames: 7));
    final src = SynthSource(128, 96);
    final stream = BytesBuilder(copy: false);
    final rec = BytesBuilder(copy: false);
    for (var i = 0; i < 30; i++) {
      final au = enc.encode(src.frame(i), forceIdr: i % 11 == 3);
      stream.add(au.data);
      appendFrame(rec, enc.reconstruction());
    }
    final dec = ffmpegDecode(stream.toBytes(), tmp, 'gop');
    expect(dec.exitCode, 0, reason: dec.stderr);
    expect(dec.stderr, isEmpty);
    expect(firstDifference(dec.yuv, rec.toBytes()), -1);
  }, skip: skip);
}
