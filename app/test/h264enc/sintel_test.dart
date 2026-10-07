// Real video check: the Sintel trailer from media/, decoded and scaled with
// the system ffmpeg (dev only), encoded, then decoded again with ffmpeg.

import 'dart:io';
import 'dart:typed_data';

import 'package:esp32_datv/core/codec/frame.dart';
import 'package:esp32_datv/core/codec/h264enc/h264_encoder.dart';
import 'package:test/test.dart';

import 'test_util.dart';

const _media = '../media/sintel_trailer.mp4';

void main() {
  final skip = !ffmpegAvailable()
      ? 'ffmpeg not installed'
      : (!File(_media).existsSync() ? 'media/sintel_trailer.mp4 missing' : false);
  late Directory tmp;
  setUpAll(() => tmp = Directory.systemTemp.createTempSync('h264enc_sintel_'));
  tearDownAll(() => tmp.deleteSync(recursive: true));

  for (final c in const [
    (640, 272, 24, 800000, H264Preset.medium, 0.0),
    (640, 272, 24, 800000, H264Preset.fast, 0.0),
    (320, 136, 24, 250000, H264Preset.medium, 0.0),
    (320, 136, 12, 60000, H264Preset.fast, 0.0),
    // Busier part of the trailer (action scenes).
    (640, 272, 24, 800000, H264Preset.medium, 20.0),
    (640, 272, 24, 800000, H264Preset.fast, 20.0),
    (320, 136, 24, 250000, H264Preset.medium, 20.0),
  ]) {
    final (w, h, fps, br, preset, start) = c;
    final name = 'sintel@${start.round()}s ${w}x$h ${fps}fps ${br ~/ 1000}k '
        '${preset.name}';
    test(name, () {
      const frames = 300;
      final raw =
          ffmpegLoadVideo(_media, w, h, frames, startSeconds: start)!;
      final fs = w * h * 3 ~/ 2;
      final n = raw.length ~/ fs;
      expect(n, frames);
      final enc = H264Encoder(H264EncoderConfig(
          width: w, height: h, fps: fps, bitrate: br, preset: preset));
      final stream = BytesBuilder(copy: false);
      final rec = BytesBuilder(copy: false);
      final sw = Stopwatch();
      for (var i = 0; i < n; i++) {
        final o = i * fs;
        final f = I420Frame(
            w,
            h,
            Uint8List.sublistView(raw, o, o + w * h),
            Uint8List.sublistView(raw, o + w * h, o + w * h * 5 ~/ 4),
            Uint8List.sublistView(raw, o + w * h * 5 ~/ 4, o + fs),
            ptsUs: i * 1000000 ~/ fps);
        sw.start();
        final au = enc.encode(f);
        sw.stop();
        stream.add(au.data);
        appendFrame(rec, enc.reconstruction());
      }
      final bytes = stream.toBytes();
      final dec = ffmpegDecode(bytes, tmp, name.replaceAll(' ', '_'));
      expect(dec.exitCode, 0, reason: dec.stderr);
      expect(dec.stderr, isEmpty);
      expect(dec.frameCount(w, h), n);
      expect(firstDifference(dec.yuv, rec.toBytes()), -1);
      final (avg, mn) = psnrStats(raw, dec.yuv, w, h);
      final kbps = bytes.length * 8 * fps / n / 1000;
      // ignore: avoid_print
      print('$name: PSNR avg ${avg.toStringAsFixed(2)} min '
          '${mn.toStringAsFixed(2)} dB, ${kbps.toStringAsFixed(1)} kb/s, '
          'encode ${(n / sw.elapsedMicroseconds * 1e6).toStringAsFixed(1)} '
          'fps (JIT)');
      expect(kbps * 1000, lessThanOrEqualTo(br));
      expect(enc.vbvViolations, 0);
      expect(avg, greaterThan(28));
    }, skip: skip, timeout: const Timeout(Duration(minutes: 10)));
  }
}
