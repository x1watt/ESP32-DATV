// Dev tool: lists mismatching macroblocks of frame N against ffmpeg output.
// Usage: dart run tool/h264dec/mbdiff.dart <file.h264> [frame]
// (set SliceDecoder.debugLog / H264Decoder.debugLog for per-MB traces)
import 'dart:io';
import 'dart:typed_data';

import 'package:esp32_datv/core/codec/frame.dart';
import 'package:esp32_datv/core/codec/h264dec/h264dec.dart';

void main(List<String> args) {
  final path = args[0];
  final want = args.length > 1 ? int.parse(args[1]) : 0;
  final bytes = File(path).readAsBytesSync();
  final dec = H264Decoder();
  final frames = <I420Frame>[];
  for (final n in H264Decoder.splitAnnexB(bytes)) {
    final got = dec.decodeNals([n]);
    frames.addAll(got);
    if (frames.length > want) break;
  }
  frames.addAll(dec.flush());
  final f = frames[want];
  final res = Process.runSync('ffmpeg', [
    '-v',
    'error',
    '-i',
    path,
    '-f',
    'rawvideo',
    '-pix_fmt',
    'yuv420p',
    '-fps_mode',
    'passthrough',
    '-frames:v',
    '${want + 1}',
    '-',
  ], stdoutEncoding: null);
  final all = res.stdout as List<int>;
  final fs = f.width * f.height * 3 ~/ 2;
  final r = Uint8List.fromList(all.sublist(want * fs, (want + 1) * fs));
  final w = f.width, h = f.height;
  final mbw = (w + 15) ~/ 16, mbh = (h + 15) ~/ 16;
  var shown = 0;
  for (var my = 0; my < mbh; my++) {
    for (var mx = 0; mx < mbw; mx++) {
      var bad = 0;
      var firstX = -1, firstY = -1;
      for (var y = my * 16; y < my * 16 + 16 && y < h; y++) {
        for (var x = mx * 16; x < mx * 16 + 16 && x < w; x++) {
          if (f.y[y * w + x] != r[y * w + x]) {
            bad++;
            if (firstX < 0) {
              firstX = x - mx * 16;
              firstY = y - my * 16;
            }
          }
        }
      }
      var cbad = 0;
      final cw = w >> 1;
      for (var y = my * 8; y < my * 8 + 8 && y < h >> 1; y++) {
        for (var x = mx * 8; x < mx * 8 + 8 && x < cw; x++) {
          if (f.u[y * cw + x] != r[w * h + y * cw + x]) cbad++;
          if (f.v[y * cw + x] != r[w * h * 5 ~/ 4 + y * cw + x]) cbad++;
        }
      }
      if ((bad > 0 || cbad > 0) && shown < 12) {
        shown++;
        stdout.writeln(
          'mb ($mx,$my) addr ${my * mbw + mx}: luma bad $bad first ($firstX,$firstY), chroma bad $cbad',
        );
        if (shown == 1) {
          for (var y = 0; y < 16; y++) {
            final sb = StringBuffer();
            for (var x = 0; x < 16; x++) {
              final i = (my * 16 + y) * w + mx * 16 + x;
              sb.write('${f.y[i] - r[i]}'.padLeft(4));
            }
            stdout.writeln(sb);
          }
        }
      }
    }
  }
}
