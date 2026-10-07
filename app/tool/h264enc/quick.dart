// Dev tool: encode synthetic or raw YUV input and write the stream plus the
// encoder reconstruction for comparison with an external decoder.
//
// dart run tool/h264enc/quick.dart <w> <h> <fps> <bitrate> <frames> <out.264>
//     [recon.yuv] [input.yuv] [fast|medium]

import 'dart:io';
import 'dart:typed_data';

import 'package:esp32_datv/core/codec/frame.dart';
import 'package:esp32_datv/core/codec/h264enc/h264_encoder.dart';

import '../../test/h264enc/synth_source.dart';

void main(List<String> args) {
  final w = int.parse(args[0]), h = int.parse(args[1]);
  final fps = int.parse(args[2]), br = int.parse(args[3]);
  final frames = int.parse(args[4]);
  final out = File(args[5]).openSync(mode: FileMode.write);
  final recon = args.length > 6 && args[6] != '-'
      ? File(args[6]).openSync(mode: FileMode.write)
      : null;
  final srcOut = recon != null
      ? File('${args[6]}.src').openSync(mode: FileMode.write)
      : null;
  RandomAccessFile? input;
  if (args.length > 7 && args[7] != '-') {
    input = File(args[7]).openSync();
  }
  final preset = args.length > 8 && args[8] == 'fast'
      ? H264Preset.fast
      : H264Preset.medium;
  final enc = H264Encoder(H264EncoderConfig(
      width: w, height: h, fps: fps, bitrate: br, preset: preset));
  final synth = SynthSource(w, h);
  var total = 0;
  final sw = Stopwatch()..start();
  var encUs = 0;
  final sizes = <int>[];
  for (var i = 0; i < frames; i++) {
    I420Frame f;
    if (input != null) {
      final buf = input.readSync(w * h * 3 ~/ 2);
      if (buf.length < w * h * 3 ~/ 2) break;
      f = I420Frame(
          w,
          h,
          Uint8List.sublistView(buf, 0, w * h),
          Uint8List.sublistView(buf, w * h, w * h * 5 ~/ 4),
          Uint8List.sublistView(buf, w * h * 5 ~/ 4),
          ptsUs: i * 1000000 ~/ fps);
    } else {
      f = synth.frame(i, fps: fps);
    }
    final t0 = sw.elapsedMicroseconds;
    final af = enc.encode(f);
    encUs += sw.elapsedMicroseconds - t0;
    out.writeFromSync(af.data);
    total += af.data.length;
    sizes.add(af.data.length);
    if (srcOut != null) {
      srcOut.writeFromSync(f.y);
      srcOut.writeFromSync(f.u);
      srcOut.writeFromSync(f.v);
    }
    if (recon != null) {
      final r = enc.reconstruction();
      recon.writeFromSync(r.y);
      recon.writeFromSync(r.u);
      recon.writeFromSync(r.v);
    }
    if (i < 3 || i % 50 == 0 || Platform.environment["V"] != null) {
      stderr.writeln('frame $i key=${af.keyframe} qp=${af.qp} '
          'bytes=${af.data.length} fill=${enc.vbvFill.round()}');
    }
  }
  out.closeSync();
  recon?.closeSync();
  srcOut?.closeSync();
  final n = sizes.length;
  final kbps = total * 8 * fps / n / 1000;
  stderr.writeln('frames=$n kbps=${kbps.toStringAsFixed(1)} '
      'target=${br / 1000} encFps=${(n * 1e6 / encUs).toStringAsFixed(1)} '
      'peak=${enc.vbvPeak.round()}/${enc.config.vbvBits} '
      'viol=${enc.vbvViolations} level=${enc.levelIdc}');
}
