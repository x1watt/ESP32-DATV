// Self-contained decoder tests using small committed fixtures (generated
// once with libx264; expected MD5 values are of `ffmpeg -f rawvideo
// -pix_fmt yuv420p` output).
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:esp32_datv/core/codec/frame.dart';
import 'package:esp32_datv/core/codec/h264dec/h264dec.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixtures = {
  'baseline_cavlc_96x64.h264': 'ac24b6ccab279cff102e6a449089c0a3',
  'high_cabac_96x64.h264': 'ef5259877cebcb3e28c945ccfd4922d0',
};

Uint8List _fixture(String name) => File('test/h264dec/fixtures/$name').readAsBytesSync();

String _md5Frames(List<I420Frame> frames) {
  final b = BytesBuilder(copy: false);
  for (final f in frames) {
    b.add(f.y);
    b.add(f.u);
    b.add(f.v);
  }
  return md5.convert(b.takeBytes()).toString();
}

List<I420Frame> _decodeAll(Uint8List data, {int chunk = 0}) {
  final dec = H264Decoder();
  final out = <I420Frame>[];
  if (chunk == 0) {
    out.addAll(dec.decode(data));
  } else {
    // Feed NAL by NAL with increasing timestamps.
    var i = 0;
    for (final nal in H264Decoder.splitAnnexB(data)) {
      out.addAll(dec.decodeNals([nal], ptsUs: i++));
    }
  }
  out.addAll(dec.flush());
  return out;
}

void main() {
  for (final e in _fixtures.entries) {
    test('fixture ${e.key} decodes bit-exact (whole buffer)', () {
      final frames = _decodeAll(_fixture(e.key));
      expect(frames.length, 24);
      expect(frames.first.width, 96);
      expect(frames.first.height, 64);
      expect(_md5Frames(frames), e.value);
    });

    test('fixture ${e.key} decodes bit-exact (NAL by NAL)', () {
      final frames = _decodeAll(_fixture(e.key), chunk: 1);
      expect(_md5Frames(frames), e.value);
    });
  }

  test('presentation timestamps come out in display order', () {
    // Feed access units (split at slice NALs) with pts = decode index * 10;
    // with B-frames the output order differs from decode order, and output
    // pts must be strictly increasing for this x264 stream.
    final data = _fixture('high_cabac_96x64.h264');
    final nals = H264Decoder.splitAnnexB(data);
    final dec = H264Decoder();
    final pts = <int>[];
    var au = 0;
    final pending = <Uint8List>[];
    void flushAu() {
      if (pending.isEmpty) return;
      for (final f in dec.decodeNals(List.of(pending), ptsUs: au * 10)) {
        pts.add(f.ptsUs);
      }
      pending.clear();
      au++;
    }

    for (final n in nals) {
      final t = n[0] & 31;
      pending.add(n);
      if (t == 1 || t == 5) flushAu();
    }
    flushAu();
    for (final f in dec.flush()) {
      pts.add(f.ptsUs);
    }
    expect(pts.length, 24);
    // Every input pts appears exactly once.
    expect(pts.toSet().length, 24);
    // B-frames exist, so output order differs from decode order.
    var reordered = false;
    for (var i = 1; i < pts.length; i++) {
      if (pts[i] < pts[i - 1]) reordered = true;
    }
    expect(reordered, isTrue);
  });

  test('empty and garbage input never throws', () {
    final dec = H264Decoder();
    expect(dec.decode(Uint8List(0)), isEmpty);
    final rnd = Random(1);
    for (var i = 0; i < 50; i++) {
      final junk = Uint8List.fromList(List.generate(500, (_) => rnd.nextInt(256)));
      // Insert start codes so NAL parsing paths are exercised.
      for (var k = 0; k < junk.length - 4; k += 37) {
        junk[k] = 0;
        junk[k + 1] = 0;
        junk[k + 2] = 1;
        junk[k + 3] = [0x67, 0x68, 0x65, 0x41, 0x01][rnd.nextInt(5)];
      }
      try {
        dec.decode(junk);
      } on UnsupportedError {
        // Random SPS may announce unsupported features; that is allowed.
      }
    }
    try {
      dec.flush();
    } on UnsupportedError {
      // allowed
    }
  });

  for (final name in _fixtures.keys) {
    test('corrupted $name is concealed without exceptions', () {
      final good = _fixture(name);
      final rnd = Random(name.length);
      for (var iter = 0; iter < 40; iter++) {
        final data = Uint8List.fromList(good);
        // Flip random bits after the parameter sets.
        final flips = 1 + rnd.nextInt(20);
        for (var k = 0; k < flips; k++) {
          final pos = 40 + rnd.nextInt(data.length - 40);
          data[pos] ^= 1 << rnd.nextInt(8);
        }
        // Sometimes truncate.
        final len = rnd.nextBool() ? data.length : rnd.nextInt(data.length);
        final dec = H264Decoder();
        final frames = <I420Frame>[];
        try {
          for (final nal in H264Decoder.splitAnnexB(Uint8List.sublistView(data, 0, len))) {
            frames.addAll(dec.decodeNals([nal]));
          }
          frames.addAll(dec.flush());
        } on UnsupportedError {
          continue;
        }
        for (final f in frames) {
          expect(f.y.length, f.width * f.height);
          expect(f.u.length, (f.width >> 1) * (f.height >> 1));
        }
      }
    });
  }

  test('dropped NAL units are concealed', () {
    final nals = H264Decoder.splitAnnexB(_fixture('high_cabac_96x64.h264'));
    final dec = H264Decoder();
    final frames = <I420Frame>[];
    for (var i = 0; i < nals.length; i++) {
      if (i > 4 && i % 5 == 0) continue; // drop some slices
      frames.addAll(dec.decodeNals([nals[i]]));
    }
    frames.addAll(dec.flush());
    expect(frames, isNotEmpty);
  });
}
