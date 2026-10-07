import 'dart:typed_data';

import 'package:esp32_datv/platform/capture/pixel_pack.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds YUV_420_888 planes the way Android cameras deliver them: row padding, chroma
/// either planar (pixel stride 1) or interleaved (pixel stride 2, V right after U), and the
/// last row of each plane missing its padding.
({Uint8List y, Uint8List u, Uint8List v, int yRow, int uvRow}) makePlanes(int w, int h, int pixelStride) {
  final cw = (w + 1) ~/ 2, ch = (h + 1) ~/ 2;
  final yRow = w + 16;
  final y = Uint8List(yRow * (h - 1) + w);
  for (var r = 0; r < h; r++) {
    for (var c = 0; c < w; c++) {
      y[r * yRow + c] = (r * 7 + c) & 255;
    }
    for (var c = w; c < yRow && r < h - 1; c++) {
      y[r * yRow + c] = 0xEE; // padding garbage
    }
  }
  int uAt(int r, int c) => (100 + r * 3 + c) & 255;
  int vAt(int r, int c) => (200 - r - c * 2) & 255;
  if (pixelStride == 1) {
    final uvRow = cw + 8;
    final u = Uint8List(uvRow * (ch - 1) + cw), v = Uint8List(uvRow * (ch - 1) + cw);
    for (var r = 0; r < ch; r++) {
      for (var c = 0; c < cw; c++) {
        u[r * uvRow + c] = uAt(r, c);
        v[r * uvRow + c] = vAt(r, c);
      }
    }
    return (y: y, u: u, v: v, yRow: yRow, uvRow: uvRow);
  }
  // NV21-like: one buffer V U V U ..., u starts one byte later; both views end early
  final uvRow = cw * 2 + 32;
  final vu = Uint8List(uvRow * (ch - 1) + cw * 2);
  for (var r = 0; r < ch; r++) {
    for (var c = 0; c < cw; c++) {
      vu[r * uvRow + 2 * c] = vAt(r, c);
      vu[r * uvRow + 2 * c + 1] = uAt(r, c);
    }
  }
  final v = Uint8List.sublistView(vu, 0, vu.length - 1); // Android's V plane lacks the last U
  final u = Uint8List.sublistView(vu, 1);
  return (y: y, u: u, v: v, yRow: yRow, uvRow: uvRow);
}

void checkI420(Uint8List out, int w, int h) {
  final cw = (w + 1) ~/ 2, ch = (h + 1) ~/ 2;
  expect(out.length, w * h + 2 * cw * ch);
  for (var r = 0; r < h; r++) {
    for (var c = 0; c < w; c++) {
      expect(out[r * w + c], (r * 7 + c) & 255, reason: 'Y at $r,$c');
    }
  }
  for (var r = 0; r < ch; r++) {
    for (var c = 0; c < cw; c++) {
      expect(out[w * h + r * cw + c], (100 + r * 3 + c) & 255, reason: 'U at $r,$c');
      expect(out[w * h + cw * ch + r * cw + c], (200 - r - c * 2) & 255, reason: 'V at $r,$c');
    }
  }
}

void main() {
  group('yuv420ToI420', () {
    for (final ps in [1, 2]) {
      for (final (w, h) in [(64, 48), (30, 18), (31, 17)]) {
        test('pixel stride $ps, ${w}x$h', () {
          final p = makePlanes(w, h, ps);
          final out = yuv420ToI420(
            width: w,
            height: h,
            y: p.y,
            yRowStride: p.yRow,
            u: p.u,
            v: p.v,
            uvRowStride: p.uvRow,
            uvPixelStride: ps,
          );
          checkI420(out, w, h);
        });
      }
    }
  });

  test('nv12ToI420 splits the interleaved plane', () {
    const w = 8, h = 4, stride = 12;
    final src = Uint8List(stride * h * 3 ~/ 2);
    for (var i = 0; i < stride * h; i++) {
      src[i] = i & 255;
    }
    for (var r = 0; r < h ~/ 2; r++) {
      for (var c = 0; c < w ~/ 2; c++) {
        src[stride * h + r * stride + 2 * c] = 10 + r * 4 + c; // U
        src[stride * h + r * stride + 2 * c + 1] = 50 + r * 4 + c; // V
      }
    }
    final out = nv12ToI420(src, w, h, stride);
    expect(out.sublist(0, w), List.generate(w, (i) => i));
    expect(out.sublist(w, 2 * w), List.generate(w, (i) => stride + i));
    expect(out.sublist(w * h, w * h + 8), [10, 11, 12, 13, 14, 15, 16, 17]);
    expect(out.sublist(w * h + 8), [50, 51, 52, 53, 54, 55, 56, 57]);
  });

  test('packRows drops padding and tolerates a short last row', () {
    final src = Uint8List.fromList([1, 2, 3, 0, 0, 4, 5, 6, 0, 0, 7, 8, 9]);
    expect(packRows(src, 3, 5, 3), [1, 2, 3, 4, 5, 6, 7, 8, 9]);
    expect(packRowsFlipped(src, 3, 5, 3), [7, 8, 9, 4, 5, 6, 1, 2, 3]);
    expect(packRows(Uint8List.fromList([1, 2, 3, 4]), 2, 2, 2), [1, 2, 3, 4]);
  });

  test('halve32 averages 2x2 blocks with a row stride', () {
    // 4x2 BGRA picture, stride 20 (4 bytes padding)
    final src = Uint8List(40);
    for (var x = 0; x < 4; x++) {
      for (var k = 0; k < 3; k++) {
        src[x * 4 + k] = x * 10 + k;
        src[20 + x * 4 + k] = x * 10 + k + 20;
      }
    }
    final out = halve32(src, 4, 2, 20);
    expect(out, [15, 16, 17, 255, 35, 36, 37, 255]);
  });

  test('fitWidth keeps the aspect ratio and even sizes', () {
    expect(fitWidth(1920, 1080, 960), (960, 540));
    expect(fitWidth(1281, 721, 2000), (1280, 720));
    expect(fitWidth(1000, 333, 500), (500, 166));
  });

  test('PcmBlocker rebuilds 20 ms blocks from odd chunks', () {
    final b = PcmBlocker(4, 2); // 4 frames stereo = 16 bytes
    final blocks = <Int16List>[];
    final bytes = Uint8List(40);
    final bd = ByteData.sublistView(bytes);
    for (var i = 0; i < 20; i++) {
      bd.setInt16(i * 2, i - 10, Endian.little);
    }
    b.add(Uint8List.sublistView(bytes, 0, 5), blocks.add);
    b.add(Uint8List.sublistView(bytes, 5, 33), blocks.add);
    b.add(Uint8List.sublistView(bytes, 33), blocks.add);
    expect(blocks.length, 2);
    expect(blocks[0], List.generate(8, (i) => i - 10));
    expect(blocks[1], List.generate(8, (i) => i - 2));
  });

  test('level meters', () {
    expect(peakDbfs(Int16List(10)), -120);
    expect(peakDbfs(Int16List.fromList([0, -16384, 100])), closeTo(-6.02, 0.01));
    expect(rmsDbfs(Int16List.fromList([16384, -16384])), closeTo(-6.02, 0.01));
  });
}
