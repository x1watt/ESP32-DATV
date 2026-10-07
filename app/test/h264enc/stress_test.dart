// Stress: screen-capture like content (sharp terminal text that scrolls and
// gets typed, sudden scene changes), irregular timestamps and low QP so that
// large coefficients, CAVLC escapes, the VBV cap path and big mb_qp_delta
// steps are all exercised. Every stream must decode with ffmpeg without a
// single error and match the encoder reconstruction bit for bit.

import 'dart:io';
import 'dart:typed_data';

import 'package:esp32_datv/core/codec/frame.dart';
import 'package:esp32_datv/core/codec/h264enc/h264_encoder.dart';
import 'package:test/test.dart';

import 'test_util.dart';

/// Terminal like frames: 5x7 glyph cells, scrolling lines, a typing cursor,
/// and a different scene (colours, font scale, layout) every [sceneLen].
class TextScreen {
  TextScreen(this.w, this.h, {this.sceneLen = 37});
  final int w, h, sceneLen;
  int _seed = 1;

  int _rand() {
    _seed = (_seed * 1103515245 + 12345) & 0x7fffffff;
    return _seed >> 8;
  }

  I420Frame frame(int n, int ptsUs) {
    final f = I420Frame.alloc(w, h, ptsUs: ptsUs);
    final scene = n ~/ sceneLen;
    final scale = 1 + scene % 3;
    final invert = scene.isOdd;
    final bg = invert ? 235 : 16 + (scene * 37) % 40;
    final fg = invert ? 16 : 235;
    final cellW = 6 * scale, cellH = 9 * scale;
    final scroll = (n % sceneLen) * (scale + 1); // pixels scrolled
    final cols = w ~/ cellW;
    for (var y = 0; y < h; y++) {
      final vy = y + scroll;
      final line = vy ~/ cellH, gy = (vy % cellH) ~/ scale;
      for (var x = 0; x < w; x++) {
        var v = bg;
        final col = x ~/ cellW, gx = (x % cellW) ~/ scale;
        // Lines grow as if typed: the last visible line is partial.
        final typed = line * cols + col <
            (scroll ~/ cellH + h ~/ cellH) * cols + (n % sceneLen) * 3;
        if (gx < 5 && gy < 7 && typed) {
          _seed = (line * 7919 + col * 104729 + scene * 31) & 0x7fffffff;
          final glyph = _rand();
          if (((glyph >> (gy * 5 + gx) % 23) & 1) == 1) v = fg;
        }
        f.y[y * w + x] = v;
      }
    }
    // A window with a fine checkerboard (max frequency coefficients).
    final bx = (scene * 53) % (w ~/ 2), by = (scene * 29) % (h ~/ 2);
    for (var y = by; y < by + h ~/ 4 && y < h; y++) {
      for (var x = bx; x < bx + w ~/ 4 && x < w; x++) {
        f.y[y * w + x] = ((x ^ y) & 1) == 0 ? 0 : 255;
      }
    }
    final cw = w >> 1, ch = h >> 1;
    for (var y = 0; y < ch; y++) {
      for (var x = 0; x < cw; x++) {
        final colour = (scene % 4 == 2) && x < cw ~/ 3;
        f.u[y * cw + x] = colour ? (x * 8) & 0xff : 128;
        f.v[y * cw + x] = colour ? 255 - ((y * 8) & 0xff) : 128;
      }
    }
    return f;
  }
}

void main() {
  final skip = ffmpegAvailable() ? false : 'ffmpeg not installed';
  late Directory tmp;
  setUpAll(() => tmp = Directory.systemTemp.createTempSync('h264enc_stress_'));
  tearDownAll(() => tmp.deleteSync(recursive: true));

  for (final c in const [
    (640, 360, 25, 735400, H264Preset.fast, 10),
    (640, 360, 25, 735400, H264Preset.medium, 10),
    (640, 360, 25, 150000, H264Preset.fast, 10),
    (320, 180, 15, 150000, H264Preset.medium, 10),
    // QP 0 allowed: largest coefficients and level_prefix escapes.
    (320, 180, 15, 4000000, H264Preset.medium, 0),
    (160, 90, 10, 34000, H264Preset.fast, 10),
  ]) {
    final (w, h, fps, br, preset, qpMin) = c;
    final name = 'stress ${w}x$h ${fps}fps ${br ~/ 1000}k ${preset.name} '
        'qpMin $qpMin';
    test(name, () {
      final src = TextScreen(w, h);
      final enc = H264Encoder(H264EncoderConfig(
          width: w,
          height: h,
          fps: fps,
          bitrate: br,
          preset: preset,
          qpMin: qpMin));
      final stream = BytesBuilder(copy: false);
      final rec = BytesBuilder(copy: false);
      // Irregular capture timing: 30..70 ms between frames, with a pause.
      var pts = 0;
      var jitter = 7;
      const n = 150;
      var bits = 0;
      for (var i = 0; i < n; i++) {
        jitter = (jitter * 1103515245 + 12345) & 0x7fffffff;
        pts += i == 80 ? 900000 : 30000 + (jitter >> 8) % 40001;
        final au = enc.encode(src.frame(i, pts), forceIdr: i == 120);
        bits += au.data.length * 8;
        stream.add(au.data);
        appendFrame(rec, enc.reconstruction());
      }
      final dec = ffmpegDecode(stream.toBytes(), tmp, name.replaceAll(' ', '_'));
      expect(dec.exitCode, 0, reason: dec.stderr);
      expect(dec.stderr, isEmpty);
      expect(dec.frameCount(w, h), n);
      expect(firstDifference(dec.yuv, rec.toBytes()), -1);
      expect(enc.vbvViolations, 0);
      expect(enc.vbvPeak, lessThanOrEqualTo(enc.config.vbvBits));
      // Never more than one nominal frame budget per frame on average.
      expect(bits / n, lessThanOrEqualTo(br / fps));
      // ignore: avoid_print
      print('$name: ${(bits / n * fps / 1000).toStringAsFixed(1)} kb/s at '
          'nominal fps, vbv peak ${enc.vbvPeak.round()}/${enc.config.vbvBits}');
    }, skip: skip, timeout: const Timeout(Duration(minutes: 10)));
  }
}
