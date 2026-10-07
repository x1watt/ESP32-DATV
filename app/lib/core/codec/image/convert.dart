/// Picture conversion and scaling to I420 (BT.601 limited range), plus a test pattern.
library;

import 'dart:typed_data';

import '../frame.dart';

/// Output size for a source picture at a given width, height rounded to even
/// (like `scale=w:-2`). Never upscales beyond the source width.
(int, int) fitSize(int srcW, int srcH, int maxWidth) {
  var w = maxWidth < srcW ? maxWidth : srcW;
  w &= ~1;
  if (w < 16) w = 16;
  var h = (srcH * w / srcW).round();
  h = (h + 1) & ~1;
  if (h < 16) h = 16;
  return (w, h);
}

/// Pixel layouts accepted by [packedToI420].
enum PackedFormat { rgba, bgra, yuyv, uyvy }

/// Scales a packed picture (RGBA, BGRA, YUYV or UYVY) to an I420 frame of outW x outH.
/// Uses box filtering when shrinking (each output pixel averages its source area,
/// sampled on a 2x2 grid) and nearest sampling when growing.
I420Frame packedToI420(Uint8List src, int srcW, int srcH, int stride, PackedFormat fmt, int outW, int outH,
    {int ptsUs = 0}) {
  final f = I420Frame.alloc(outW, outH, ptsUs: ptsUs);
  final yP = f.y, uP = f.u, vP = f.v;
  final cw = outW >> 1;
  // source coordinates of output sample centres, in 16.16 fixed point
  final sx = Int32List(outW * 2), sy = Int32List(outH * 2);
  for (var x = 0; x < outW; x++) {
    final a = (x * srcW) / outW, b = ((x + 1) * srcW) / outW;
    sx[2 * x] = (a + (b - a) * 0.25).floor().clamp(0, srcW - 1);
    sx[2 * x + 1] = (a + (b - a) * 0.75).floor().clamp(0, srcW - 1);
  }
  for (var y = 0; y < outH; y++) {
    final a = (y * srcH) / outH, b = ((y + 1) * srcH) / outH;
    sy[2 * y] = (a + (b - a) * 0.25).floor().clamp(0, srcH - 1);
    sy[2 * y + 1] = (a + (b - a) * 0.75).floor().clamp(0, srcH - 1);
  }
  final isRgb = fmt == PackedFormat.rgba || fmt == PackedFormat.bgra;
  final rOff = fmt == PackedFormat.bgra ? 2 : 0, bOff = fmt == PackedFormat.bgra ? 0 : 2;
  // per output pixel: Y; chroma accumulated per 2x2 block
  final uAcc = Int32List(cw), vAcc = Int32List(cw);
  for (var y = 0; y < outH; y++) {
    final r0 = sy[2 * y] * stride, r1 = sy[2 * y + 1] * stride;
    if ((y & 1) == 0) {
      uAcc.fillRange(0, cw, 0);
      vAcc.fillRange(0, cw, 0);
    }
    final yRow = y * outW;
    for (var x = 0; x < outW; x++) {
      var ys = 0, us = 0, vs = 0;
      for (var k = 0; k < 4; k++) {
        final row = (k & 2) == 0 ? r0 : r1;
        final px = sx[2 * x + (k & 1)];
        if (isRgb) {
          final o = row + px * 4;
          final r = src[o + rOff], g = src[o + 1], b = src[o + bOff];
          ys += (66 * r + 129 * g + 25 * b + 128) >> 8;
          us += (-38 * r - 74 * g + 112 * b + 128) >> 8;
          vs += (112 * r - 94 * g - 18 * b + 128) >> 8;
        } else {
          final o = row + (px & ~1) * 2;
          if (fmt == PackedFormat.yuyv) {
            ys += src[o + (px & 1) * 2] - 16;
            us += src[o + 1] - 128;
            vs += src[o + 3] - 128;
          } else {
            ys += src[o + 1 + (px & 1) * 2] - 16;
            us += src[o] - 128;
            vs += src[o + 2] - 128;
          }
        }
      }
      yP[yRow + x] = ((ys + 2) >> 2) + 16;
      uAcc[x >> 1] += us;
      vAcc[x >> 1] += vs;
    }
    if ((y & 1) == 1) {
      final cRow = (y >> 1) * cw;
      for (var x = 0; x < cw; x++) {
        uP[cRow + x] = (((uAcc[x] + 8) >> 4) + 128).clamp(16, 240);
        vP[cRow + x] = (((vAcc[x] + 8) >> 4) + 128).clamp(16, 240);
      }
    }
  }
  return f;
}

void _scalePlane(Uint8List s, int sw, int sh, Uint8List d, int dw, int dh) {
  if (sw == dw && sh == dh) {
    d.setAll(0, s);
    return;
  }
  // bilinear, 16.16 fixed point, sample centres aligned
  final xs = Int32List(dw), xf = Int32List(dw);
  for (var x = 0; x < dw; x++) {
    var p = ((x + 0.5) * sw / dw - 0.5);
    if (p < 0) p = 0;
    final i = p.floor();
    xs[x] = i < sw - 1 ? i : sw - 2 < 0 ? 0 : sw - 2;
    xf[x] = ((p - xs[x]) * 256).round().clamp(0, 256);
  }
  for (var y = 0; y < dh; y++) {
    var p = ((y + 0.5) * sh / dh - 0.5);
    if (p < 0) p = 0;
    var iy = p.floor();
    if (iy > sh - 2) iy = sh - 2 < 0 ? 0 : sh - 2;
    final fy = ((p - iy) * 256).round().clamp(0, 256);
    final r0 = iy * sw, r1 = (iy + 1 < sh ? iy + 1 : iy) * sw;
    final o = y * dw;
    for (var x = 0; x < dw; x++) {
      final i = xs[x], fx = xf[x];
      final i1 = i + 1 < sw ? i + 1 : i;
      final a = s[r0 + i] * (256 - fx) + s[r0 + i1] * fx;
      final b = s[r1 + i] * (256 - fx) + s[r1 + i1] * fx;
      d[o + x] = (a * (256 - fy) + b * fy + 32768) >> 16;
    }
  }
}

/// Bilinear I420 scaling (for decoded frames). Downscaling by more than 2x first halves
/// the picture so that bilinear sampling does not alias badly.
I420Frame scaleI420(I420Frame s, int dw, int dh) {
  var src = s;
  while (src.width >= dw * 2 && src.height >= dh * 2 && src.width >= 4 && src.height >= 4) {
    src = _half(src);
  }
  final d = I420Frame.alloc(dw, dh, ptsUs: s.ptsUs);
  _scalePlane(src.y, src.width, src.height, d.y, dw, dh);
  _scalePlane(src.u, src.width >> 1, src.height >> 1, d.u, dw >> 1, dh >> 1);
  _scalePlane(src.v, src.width >> 1, src.height >> 1, d.v, dw >> 1, dh >> 1);
  return d;
}

I420Frame _half(I420Frame s) {
  final w = (s.width >> 1) & ~1, h = (s.height >> 1) & ~1;
  final d = I420Frame.alloc(w, h, ptsUs: s.ptsUs);
  void plane(Uint8List p, int pw, Uint8List o, int ow, int oh) {
    for (var y = 0; y < oh; y++) {
      final a = 2 * y * pw, b = a + pw;
      for (var x = 0; x < ow; x++) {
        o[y * ow + x] = (p[a + 2 * x] + p[a + 2 * x + 1] + p[b + 2 * x] + p[b + 2 * x + 1] + 2) >> 2;
      }
    }
  }

  plane(s.y, s.width, d.y, w, h);
  plane(s.u, s.width >> 1, d.u, w >> 1, h >> 1);
  plane(s.v, s.width >> 1, d.v, w >> 1, h >> 1);
  return d;
}

// ---------------------------------------------------------------- test pattern
const List<List<int>> _bars = [
  [180, 128, 128], // white 75 %
  [162, 44, 142], // yellow
  [131, 156, 44], // cyan
  [112, 72, 58], // green
  [84, 184, 198], // magenta
  [65, 100, 212], // red
  [35, 212, 114], // blue
];

// 5x7 glyphs for 0-9 and ':'
const List<int> _glyphs = [
  0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E, // 0
  0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E, // 1
  0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F, // 2
  0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E, // 3
  0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02, // 4
  0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E, // 5
  0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E, // 6
  0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08, // 7
  0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E, // 8
  0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C, // 9
  0x00, 0x0C, 0x0C, 0x00, 0x0C, 0x0C, 0x00, // :
];

void _drawText(I420Frame f, String s, int x0, int y0, int scale, int luma) {
  var x = x0;
  for (final ch in s.codeUnits) {
    final g = ch == 58 ? 10 : ch - 48;
    if (g >= 0 && g <= 10) {
      for (var r = 0; r < 7; r++) {
        final bits = _glyphs[g * 7 + r];
        for (var c = 0; c < 5; c++) {
          if ((bits >> (4 - c)) & 1 == 0) continue;
          for (var dy = 0; dy < scale; dy++) {
            for (var dx = 0; dx < scale; dx++) {
              final px = x + c * scale + dx, py = y0 + r * scale + dy;
              if (px >= 0 && py >= 0 && px < f.width && py < f.height) f.y[py * f.width + px] = luma;
            }
          }
        }
      }
    }
    x += 6 * scale;
  }
}

/// Colour bars, a moving box and the elapsed time (mm:ss:ff), like a broadcast test card.
I420Frame testPattern(int w, int h, int frameNo, int fps, {int ptsUs = 0}) {
  final f = I420Frame.alloc(w, h, ptsUs: ptsUs);
  final cw = w >> 1, ch = h >> 1;
  final barH = h * 2 ~/ 3;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final List<int> c;
      if (y < barH) {
        c = _bars[x * 7 ~/ w];
      } else {
        final g = 16 + (x * 219 ~/ w);
        c = [g, 128, 128];
      }
      f.y[y * w + x] = c[0];
      if ((x & 1) == 0 && (y & 1) == 0) {
        f.u[(y >> 1) * cw + (x >> 1)] = c[1];
        f.v[(y >> 1) * cw + (x >> 1)] = c[2];
      }
    }
  }
  // moving box
  final bs = h ~/ 6 & ~1;
  final span = w - bs;
  final pos = span <= 0 ? 0 : ((frameNo * 4) % (2 * span));
  final bx = (pos < span ? pos : 2 * span - pos) & ~1;
  final by = (barH - bs) ~/ 2 & ~1;
  for (var y = by; y < by + bs; y++) {
    for (var x = bx; x < bx + bs && x < w; x++) {
      f.y[y * w + x] = 235;
      f.u[(y >> 1) * cw + (x >> 1)] = 128;
      f.v[(y >> 1) * cw + (x >> 1)] = 128;
    }
  }
  final secs = frameNo ~/ fps, ff = frameNo % fps;
  String two(int n) => n.toString().padLeft(2, '0');
  final text = '${two(secs ~/ 60 % 60)}:${two(secs % 60)}:${two(ff)}';
  final scale = (h ~/ 60).clamp(1, 8);
  final tw = text.length * 6 * scale;
  final ty = barH + (h - barH - 7 * scale) ~/ 2;
  // dark box behind the text
  for (var y = ty - scale; y < ty + 8 * scale && y < h; y++) {
    for (var x = (w - tw) ~/ 2 - scale; x < (w + tw) ~/ 2 + scale && x < w; x++) {
      if (x >= 0 && y >= 0) f.y[y * w + x] = 16;
    }
  }
  _drawText(f, text, (w - tw) ~/ 2, ty, scale, 235);
  assert(ch > 0);
  return f;
}

/// I420 to RGBA (for previews), at most [maxWidth] wide (nearest sampling).
(Uint8List, int, int) i420ToRgbaPreview(I420Frame f, int maxWidth) {
  final step = (f.width + maxWidth - 1) ~/ maxWidth;
  final w = f.width ~/ step, h = f.height ~/ step;
  final out = Uint8List(w * h * 4);
  final cw = f.width >> 1;
  var o = 0;
  for (var y = 0; y < h; y++) {
    final sy = y * step;
    for (var x = 0; x < w; x++) {
      final sx = x * step;
      final yy = (f.y[sy * f.width + sx] - 16) * 298;
      final ci = (sy >> 1) * cw + (sx >> 1);
      final u = f.u[ci] - 128, v = f.v[ci] - 128;
      out[o] = ((yy + 409 * v + 128) >> 8).clamp(0, 255);
      out[o + 1] = ((yy - 100 * u - 208 * v + 128) >> 8).clamp(0, 255);
      out[o + 2] = ((yy + 516 * u + 128) >> 8).clamp(0, 255);
      out[o + 3] = 255;
      o += 4;
    }
  }
  return (out, w, h);
}
