/// Pure pixel helpers used by the capture sources (no FFI, no Flutter; unit tested).
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// Copies [rows] rows of [rowBytes] bytes from [src] (rows [stride] bytes apart, first row
/// at [offset]) into a tightly packed buffer. The last row of [src] may lack its padding.
Uint8List packRows(Uint8List src, int rowBytes, int stride, int rows, {int offset = 0}) {
  final out = Uint8List(rowBytes * rows);
  if (stride == rowBytes && offset == 0 && src.length >= out.length) {
    out.setRange(0, out.length, src);
    return out;
  }
  for (var r = 0; r < rows; r++) {
    final s = offset + r * stride;
    out.setRange(r * rowBytes, r * rowBytes + rowBytes, src, s);
  }
  return out;
}

/// Same as [packRows] but walks the source bottom-up (DIB/MF RGB32 with negative stride).
Uint8List packRowsFlipped(Uint8List src, int rowBytes, int stride, int rows) {
  final out = Uint8List(rowBytes * rows);
  for (var r = 0; r < rows; r++) {
    final s = (rows - 1 - r) * stride;
    out.setRange(r * rowBytes, r * rowBytes + rowBytes, src, s);
  }
  return out;
}

/// Packs an Android YUV_420_888 image (three planes with their own row and pixel strides)
/// into tightly packed I420: Y (w*h), then U, then V ((w+1)/2 * (h+1)/2 each).
/// [uvPixelStride] is 1 for planar (I420/YV12 layouts) or 2 for semi-planar (NV12/NV21).
Uint8List yuv420ToI420({
  required int width,
  required int height,
  required Uint8List y,
  required int yRowStride,
  required Uint8List u,
  required Uint8List v,
  required int uvRowStride,
  required int uvPixelStride,
  int yPixelStride = 1,
}) {
  final cw = (width + 1) >> 1, ch = (height + 1) >> 1;
  final ySize = width * height, cSize = cw * ch;
  final out = Uint8List(ySize + 2 * cSize);
  if (yPixelStride == 1) {
    for (var r = 0; r < height; r++) {
      out.setRange(r * width, r * width + width, y, r * yRowStride);
    }
  } else {
    for (var r = 0; r < height; r++) {
      var s = r * yRowStride, d = r * width;
      for (var c = 0; c < width; c++, s += yPixelStride) {
        out[d++] = y[s];
      }
    }
  }
  _plane(u, out, ySize, cw, ch, uvRowStride, uvPixelStride);
  _plane(v, out, ySize + cSize, cw, ch, uvRowStride, uvPixelStride);
  return out;
}

void _plane(Uint8List src, Uint8List out, int dst, int cw, int ch, int rowStride, int pixelStride) {
  if (pixelStride == 1) {
    for (var r = 0; r < ch; r++) {
      out.setRange(dst + r * cw, dst + r * cw + cw, src, r * rowStride);
    }
    return;
  }
  for (var r = 0; r < ch; r++) {
    var s = r * rowStride, d = dst + r * cw;
    // the last pixel of the last row may sit right at the end of a short buffer
    for (var c = 0; c < cw; c++, s += pixelStride) {
      out[d++] = s < src.length ? src[s] : 128;
    }
  }
}

/// NV12 (Y plane, then interleaved UV) with row stride [stride] to tightly packed I420.
/// [uvOffset] is where the UV plane starts (usually stride * height).
Uint8List nv12ToI420(Uint8List src, int width, int height, int stride, {int? uvOffset}) {
  final uvo = uvOffset ?? stride * height;
  return yuv420ToI420(
    width: width,
    height: height,
    y: src,
    yRowStride: stride,
    u: Uint8List.sublistView(src, uvo),
    v: Uint8List.sublistView(src, uvo + 1),
    uvRowStride: stride,
    uvPixelStride: 2,
  );
}

/// Halves a 32-bit-per-pixel picture (any channel order) with a 2x2 box filter.
/// Returns the packed result (stride = (width ~/ 2) * 4).
Uint8List halve32(Uint8List src, int width, int height, int stride) {
  final ow = width >> 1, oh = height >> 1;
  final out = Uint8List(ow * oh * 4);
  var d = 0;
  for (var r = 0; r < oh; r++) {
    final a = 2 * r * stride, b = a + stride;
    for (var c = 0; c < ow; c++) {
      final i = a + c * 8, j = b + c * 8;
      out[d] = (src[i] + src[i + 4] + src[j] + src[j + 4] + 2) >> 2;
      out[d + 1] = (src[i + 1] + src[i + 5] + src[j + 1] + src[j + 5] + 2) >> 2;
      out[d + 2] = (src[i + 2] + src[i + 6] + src[j + 2] + src[j + 6] + 2) >> 2;
      out[d + 3] = 255;
      d += 4;
    }
  }
  return out;
}

/// Picks the largest even size not wider than [maxWidth] keeping the aspect ratio.
(int, int) fitWidth(int width, int height, int maxWidth) {
  if (width <= maxWidth) return (width & ~1, height & ~1);
  final h = (height * maxWidth / width).round();
  return (maxWidth & ~1, math.max(2, h & ~1));
}

/// Peak level of a PCM block in dBFS (-inf for silence returns -120).
double peakDbfs(Int16List pcm) {
  var peak = 0;
  for (final s in pcm) {
    final a = s < 0 ? -s : s;
    if (a > peak) peak = a;
  }
  if (peak == 0) return -120;
  return 20 * math.log(peak / 32768) / math.ln10;
}

/// RMS level of a PCM block in dBFS.
double rmsDbfs(Int16List pcm) {
  if (pcm.isEmpty) return -120;
  var sum = 0.0;
  for (final s in pcm) {
    sum += s * s;
  }
  final rms = math.sqrt(sum / pcm.length);
  if (rms < 1e-3) return -120;
  return 20 * math.log(rms / 32768) / math.ln10;
}

/// Reassembles an arbitrary byte stream of little-endian 16-bit PCM into blocks of
/// [blockFrames] frames (interleaved, [channels] samples per frame).
class PcmBlocker {
  PcmBlocker(this.blockFrames, this.channels) : _buf = Uint8List(blockFrames * channels * 2);
  final int blockFrames, channels;
  final Uint8List _buf;
  int _fill = 0;

  /// Feeds bytes; calls [onBlock] for each completed block (a fresh list each time).
  void add(Uint8List bytes, void Function(Int16List block) onBlock) {
    var i = 0;
    while (i < bytes.length) {
      final n = math.min(_buf.length - _fill, bytes.length - i);
      _buf.setRange(_fill, _fill + n, bytes, i);
      _fill += n;
      i += n;
      if (_fill == _buf.length) {
        final out = Int16List(_buf.length >> 1);
        final bd = ByteData.sublistView(_buf);
        for (var k = 0; k < out.length; k++) {
          out[k] = bd.getInt16(k * 2, Endian.little);
        }
        _fill = 0;
        onBlock(out);
      }
    }
  }
}
