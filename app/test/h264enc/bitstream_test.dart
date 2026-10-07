import 'dart:typed_data';

import 'package:esp32_datv/core/codec/frame.dart';
import 'package:esp32_datv/core/codec/h264enc/h264_encoder.dart';
import 'package:esp32_datv/core/codec/h264enc/src/bit_writer.dart';
import 'package:esp32_datv/core/codec/h264enc/src/tables.dart';
import 'package:test/test.dart';

import 'test_util.dart';

/// True when no code in the table is a prefix of another.
bool _prefixFree(List<int> lens, List<int> codes) {
  final items = <String>[];
  for (var i = 0; i < lens.length; i++) {
    if (lens[i] == 0) continue;
    items.add(codes[i].toRadixString(2).padLeft(lens[i], '0'));
  }
  for (var i = 0; i < items.length; i++) {
    for (var j = 0; j < items.length; j++) {
      if (i != j && items[j].startsWith(items[i])) return false;
    }
  }
  return true;
}

void main() {
  test('CAVLC tables are prefix free', () {
    for (var t = 0; t < coeffTokenLen.length; t++) {
      expect(_prefixFree(coeffTokenLen[t], coeffTokenCode[t]), isTrue,
          reason: 'coeff_token table $t');
    }
    for (var t = 0; t < totalZerosLen.length; t++) {
      expect(_prefixFree(totalZerosLen[t], totalZerosCode[t]), isTrue,
          reason: 'total_zeros $t');
    }
    for (var t = 0; t < totalZerosDcLen.length; t++) {
      expect(_prefixFree(totalZerosDcLen[t], totalZerosDcCode[t]), isTrue);
    }
    for (var t = 0; t < runBeforeLen.length; t++) {
      expect(_prefixFree(runBeforeLen[t], runBeforeCode[t]), isTrue);
    }
  });

  test('cbp mapping tables are permutations', () {
    expect(cbpToCodeIntra.toSet().length, 48);
    expect(cbpToCodeInter.toSet().length, 48);
    expect(cbpToCodeInter[0], 0);
    expect(cbpToCodeIntra[47], 0);
  });

  test('Exp-Golomb coding', () {
    final b = BitWriter();
    b.ue(0); // 1
    b.ue(1); // 010
    b.ue(4); // 00101
    b.se(-2); // ue(4) = 00101
    b.se(3); // ue(5) = 00110
    b.trailing();
    // 1 010 00101 00101 00110 1 + pad
    final bits = <int>[];
    for (var i = 0; i < b.lengthBytes; i++) {
      for (var k = 7; k >= 0; k--) {
        bits.add((b.buffer[i] >> k) & 1);
      }
    }
    expect(bits.take(20).join(), '10100010100101001101');
  });

  test('emulation prevention', () {
    final b = BitWriter();
    for (final v in [0, 0, 1, 0, 0, 0, 0, 0, 3, 0x80]) {
      b.bits(8, v);
    }
    final s = ByteSink();
    s.nal(3, 1, b);
    final out = s.toBytes();
    expect(out.sublist(0, 5), [0, 0, 0, 1, 0x61]);
    expect(out.sublist(5), [0, 0, 3, 1, 0, 0, 3, 0, 0, 3, 0, 3, 0x80]);
  });

  test('access unit structure and GOP', () {
    final cfg = H264EncoderConfig(
        width: 96, height: 64, fps: 10, bitrate: 100000, gopFrames: 5);
    final enc = H264Encoder(cfg);
    final f = I420Frame.alloc(96, 64);
    for (var i = 0; i < f.y.length; i++) {
      f.y[i] = i & 0xff;
    }
    final keys = <bool>[];
    for (var i = 0; i < 12; i++) {
      f.ptsUs = i * 100000;
      final au = enc.encode(f, forceIdr: i == 7);
      keys.add(au.keyframe);
      expect(au.ptsUs, i * 100000);
      final types = nalTypes(au.data);
      expect(types.first, 9, reason: 'AUD first');
      expect(au.data.sublist(0, 4), [0, 0, 0, 1]);
      if (au.keyframe) {
        expect(types, [9, 7, 8, 5]);
      } else {
        expect(types, [9, 1]);
      }
    }
    expect(keys, [
      true, false, false, false, false, true, false, true, //
      false, false, false, false,
    ]);
  });

  test('rejects mismatched frame size', () {
    final enc = H264Encoder(
        H264EncoderConfig(width: 32, height: 32, fps: 10, bitrate: 50000));
    expect(() => enc.encode(I420Frame.alloc(64, 32)), throwsArgumentError);
    expect(
        () => H264EncoderConfig(width: 33, height: 32, fps: 10, bitrate: 1),
        throwsArgumentError);
  });

  test('levels', () {
    int level(int w, int h, int fps, int br) =>
        H264Encoder(H264EncoderConfig(width: w, height: h, fps: fps, bitrate: br))
            .levelIdc;
    expect(level(160, 90, 10, 40000), 10);
    expect(level(640, 360, 25, 1000000), 30);
    expect(level(854, 480, 25, 2000000), 30);
    expect(level(1280, 720, 25, 2000000), 31);
  });

  test('uint8 planes survive extreme content', () {
    // Alternating extremes stress clipping and large coefficients.
    final enc = H264Encoder(H264EncoderConfig(
        width: 48, height: 48, fps: 10, bitrate: 2000000, qpMin: 0, qpMax: 51));
    final f = I420Frame.alloc(48, 48);
    for (var i = 0; i < f.y.length; i++) {
      f.y[i] = ((i ~/ 48 + i) & 1) == 0 ? 0 : 255;
    }
    final out = enc.encode(f);
    expect(out.data.length, greaterThan(20));
    expect(Uint8List.fromList(out.data), isNotEmpty);
  });
}
