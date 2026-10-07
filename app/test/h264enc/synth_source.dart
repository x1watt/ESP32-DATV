// Deterministic synthetic test video: moving gradient, moving box with a
// texture, and a band of text-like noise that scrolls.

import 'dart:typed_data';

import 'package:esp32_datv/core/codec/frame.dart';

class SynthSource {
  SynthSource(this.width, this.height) {
    var s = 12345;
    _noise = Uint8List(width * height);
    for (var i = 0; i < _noise.length; i++) {
      s = (s * 1103515245 + 12345) & 0x7fffffff;
      _noise[i] = (s >> 16) & 0xff;
    }
  }

  final int width, height;
  late final Uint8List _noise;

  I420Frame frame(int n, {int fps = 25}) {
    final f = I420Frame.alloc(width, height, ptsUs: n * 1000000 ~/ fps);
    final w = width, h = height;
    final boxW = w ~/ 5, boxH = h ~/ 4;
    final bx = ((n * 3) % (w - boxW));
    final by = (h ~/ 3 + ((n ~/ 2) % (h ~/ 3)));
    final textTop = h * 3 ~/ 4, textBot = textTop + h ~/ 8;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var v = ((x + n * 2) * 255 ~/ (w * 2) + y * 128 ~/ h) & 0xff;
        if (x >= bx && x < bx + boxW && y >= by && y < by + boxH) {
          final cx = (x - bx) >> 2, cy = (y - by) >> 2;
          v = ((cx + cy) & 1) == 0 ? 220 : 40;
        }
        if (y >= textTop && y < textBot) {
          // Sparse glyph like blobs scrolling left.
          final sx = (x + n * 4) % w;
          final nv = _noise[((y - textTop) >> 1) * w + (sx >> 1)];
          if (nv > 190) v = 235;
          if (nv < 30) v = 16;
        }
        f.y[y * w + x] = v;
      }
    }
    final cw = w >> 1, ch = h >> 1;
    for (var y = 0; y < ch; y++) {
      for (var x = 0; x < cw; x++) {
        f.u[y * cw + x] = (128 + ((x - n) % 64) - 32) & 0xff;
        f.v[y * cw + x] = (128 + ((y * 2 + n) % 48) - 24) & 0xff;
      }
    }
    return f;
  }
}
