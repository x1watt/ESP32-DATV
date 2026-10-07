import 'dart:convert';
import 'dart:typed_data';

import 'package:esp32_datv/platform/capture/jpeg_decoder.dart';
import 'package:flutter_test/flutter_test.dart';

import 'jpeg_fixtures.dart';

const int w = 48, h = 32;

(int, int, int) rgbAt(int x, int y) {
  final r = (x * 255) ~/ (w - 1), g = (y * 255) ~/ (h - 1);
  final b = ((x ~/ 8 + y ~/ 8) % 2 == 1) ? ((x + y) * 4) % 256 : 40;
  return (r, g, b);
}

double yOf(int x, int y) {
  final (r, g, b) = rgbAt(x, y);
  return 0.299 * r + 0.587 * g + 0.114 * b;
}

double cbOf(int x, int y) {
  final (r, g, b) = rgbAt(x, y);
  return 128 - 0.168736 * r - 0.331264 * g + 0.5 * b;
}

double crOf(int x, int y) {
  final (r, g, b) = rgbAt(x, y);
  return 128 + 0.5 * r - 0.418688 * g - 0.081312 * b;
}

/// Mean absolute error of the decoded I420 planes against the source picture.
(double, double) errors(JpegPicture p, {bool gray = false}) {
  var ey = 0.0, ec = 0.0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      ey += (p.data[y * w + x] - yOf(x, y)).abs();
    }
  }
  final cw = w ~/ 2, ch = h ~/ 2;
  for (var y = 0; y < ch; y++) {
    for (var x = 0; x < cw; x++) {
      double avg(double Function(int, int) f) =>
          (f(2 * x, 2 * y) + f(2 * x + 1, 2 * y) + f(2 * x, 2 * y + 1) + f(2 * x + 1, 2 * y + 1)) / 4;
      final u = p.data[w * h + y * cw + x], v = p.data[w * h + cw * ch + y * cw + x];
      if (gray) {
        ec += (u - 128).abs() + (v - 128).abs();
      } else {
        ec += (u - avg(cbOf)).abs() + (v - avg(crOf)).abs();
      }
    }
  }
  return (ey / (w * h), ec / (2 * cw * ch));
}

/// Removes every DHT segment, as many MJPEG cameras do.
Uint8List stripDht(Uint8List j) {
  final out = BytesBuilder();
  var p = 2;
  out.add(j.sublist(0, 2));
  while (p < j.length) {
    final m = j[p + 1];
    if (m == 0xDA) {
      out.add(j.sublist(p));
      break;
    }
    final len = j[p + 2] << 8 | j[p + 3];
    if (m != 0xC4) out.add(j.sublist(p, p + 2 + len));
    p += 2 + len;
  }
  return out.toBytes();
}

void main() {
  test('standard tables have their T.81 sizes', () {
    expect(jpegStandardTableSizes, [162, 162, 12]);
  });

  for (final (name, b64) in [('4:2:2', j422), ('4:2:0 with restart markers', j420), ('4:4:4 optimized', j444)]) {
    test('decodes $name', () {
      final p = JpegDecoder().decodeI420(base64.decode(b64));
      expect(p, isNotNull);
      expect((p!.width, p.height), (w, h));
      expect(p.data.length, w * h * 3 ~/ 2);
      final (ey, ec) = errors(p);
      expect(ey, lessThan(2.5), reason: 'luma error');
      expect(ec, lessThan(4.0), reason: 'chroma error');
    });
  }

  test('decodes grayscale with neutral chroma', () {
    final p = JpegDecoder().decodeI420(base64.decode(jgray))!;
    final (ey, ec) = errors(p, gray: true);
    expect(ey, lessThan(2.5));
    expect(ec, 0);
  });

  test('frames without DHT use the standard tables', () {
    final j = stripDht(base64.decode(j422));
    expect(j.length, lessThan(base64.decode(j422).length));
    final p = JpegDecoder().decodeI420(j)!;
    final (ey, _) = errors(p);
    expect(ey, lessThan(2.5));
  });

  test('broken data returns null instead of throwing', () {
    final j = base64.decode(j422);
    expect(JpegDecoder().decodeI420(Uint8List.sublistView(j, 0, 300)), anyOf(isNull, isA<JpegPicture>()));
    expect(JpegDecoder().decodeI420(Uint8List.fromList([1, 2, 3])), isNull);
    // the decoder stays usable after a failure
    final d = JpegDecoder()..decodeI420(Uint8List.sublistView(j, 0, 700));
    expect(d.decodeI420(j), isNotNull);
  });
}
