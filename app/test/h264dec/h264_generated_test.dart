// Bit-exactness tests against system ffmpeg on streams generated at test
// time with libx264. Skipped when ffmpeg/libx264 or the source clip is
// missing.
import 'dart:io';

import 'package:esp32_datv/core/codec/h264dec/h264dec.dart';
import 'package:flutter_test/flutter_test.dart';

import 'h264_test_util.dart';

class _Case {
  const _Case(this.name, this.args, {this.scale = '160:96'});
  final String name;
  final List<String> args;
  final String scale;
}

const _cases = <_Case>[
  _Case('baseline_cavlc_poc2', ['-profile:v', 'baseline', '-x264-params', 'keyint=20:ref=3']),
  _Case('baseline_multislice', ['-profile:v', 'baseline', '-x264-params', 'slices=3:ref=2']),
  _Case('main_cabac_bframes_weighted', [
    '-profile:v',
    'main',
    '-x264-params',
    'bframes=3:b-pyramid=none:weightb=1:weightp=2:ref=3',
  ]),
  _Case('main_cavlc_bframes', [
    '-profile:v',
    'main',
    '-x264-params',
    'cabac=0:bframes=2:weightb=1:weightp=1:ref=2',
  ]),
  _Case('high_8x8_cqm_jvt', [
    '-profile:v',
    'high',
    '-x264-params',
    '8x8dct=1:cqm=jvt:bframes=3:ref=4',
  ]),
  _Case('high_cavlc_8x8_cqm', [
    '-profile:v',
    'high',
    '-x264-params',
    'cabac=0:8x8dct=1:cqm=jvt:bframes=2',
  ]),
  _Case('high_multislice', ['-profile:v', 'high', '-x264-params', 'slices=4:bframes=2:ref=2']),
  _Case('odd_size_crop_202x118', [
    '-profile:v',
    'high',
    '-x264-params',
    'bframes=3:ref=3',
  ], scale: '202:118'),
  _Case('bpyramid_spatial', [
    '-profile:v',
    'high',
    '-x264-params',
    'bframes=5:b-pyramid=normal:direct=spatial:ref=5:weightb=1',
  ]),
  _Case('bpyramid_temporal', [
    '-profile:v',
    'high',
    '-x264-params',
    'bframes=4:b-pyramid=normal:direct=temporal:ref=4',
  ]),
  _Case('constrained_intra', [
    '-profile:v',
    'main',
    '-x264-params',
    'constrained-intra=1:bframes=2',
  ]),
  _Case('deblock_offsets', ['-profile:v', 'high', '-x264-params', 'deblock=-3,3:bframes=2']),
  _Case('no_deblock', ['-profile:v', 'high', '-x264-params', 'no-deblock=1:bframes=2']),
  _Case('qp_low', ['-profile:v', 'high', '-qp', '4', '-x264-params', 'bframes=2']),
  _Case('qp_51', ['-profile:v', 'high', '-qp', '51', '-x264-params', 'bframes=2']),
  _Case('intra_refresh', [
    '-profile:v',
    'main',
    '-x264-params',
    'intra-refresh=1:keyint=12:bframes=0',
  ]),
  _Case('chroma_qp_offset', [
    '-profile:v',
    'high',
    '-x264-params',
    'chroma-qp-offset=-6:bframes=2:8x8dct=1',
  ]),
];

void main() {
  final enabled = ffmpegWithX264() && File(kSintel).existsSync();
  late Directory dir;

  setUpAll(() {
    if (enabled) dir = Directory.systemTemp.createTempSync('h264dec_gen_');
  });
  tearDownAll(() {
    if (enabled) dir.deleteSync(recursive: true);
  });

  for (final c in _cases) {
    test('bit-exact vs ffmpeg: ${c.name}', () async {
      final path = generateStream(dir, c.name, c.args, scale: c.scale)!;
      final ref = await decodeAndCompare(path);
      expect(ref.frames, greaterThan(10));
      expect(ref.mismatches, 0, reason: ref.firstMismatch);
    }, skip: enabled ? false : 'ffmpeg with libx264 or source clip not available');
  }

  test('interlaced stream reports UnsupportedError', () async {
    final path = generateStream(
      dir,
      'interlaced',
      ['-profile:v', 'high', '-x264-params', 'tff=1'],
      scale: '160:96',
      seconds: 0.5,
    )!;
    final bytes = File(path).readAsBytesSync();
    expect(() {
      final d = H264Decoder();
      for (final nal in H264Decoder.splitAnnexB(bytes)) {
        d.decodeNals([nal]);
      }
      d.flush();
    }, throwsA(isA<UnsupportedError>()));
  }, skip: enabled ? false : 'ffmpeg with libx264 or source clip not available');
}
