// Dev tool: compare two raw I420 files frame by frame.
// dart run tool/h264enc/cmp.dart <w> <h> <a.yuv> <b.yuv>

import 'dart:io';
import 'dart:math' as math;

void main(List<String> args) {
  final w = int.parse(args[0]), h = int.parse(args[1]);
  final a = File(args[2]).readAsBytesSync();
  final b = File(args[3]).readAsBytesSync();
  final fs = w * h * 3 ~/ 2;
  final na = a.length ~/ fs, nb = b.length ~/ fs;
  stdout.writeln('frames a=$na b=$nb');
  final n = math.min(na, nb);
  var firstMismatch = -1;
  var sumPsnr = 0.0;
  for (var f = 0; f < n; f++) {
    var se = 0;
    var diff = 0;
    var firstPos = -1;
    for (var i = 0; i < fs; i++) {
      final d = a[f * fs + i] - b[f * fs + i];
      if (d != 0) {
        diff++;
        if (firstPos < 0) firstPos = i;
      }
      if (i < w * h) se += d * d;
    }
    final mse = se / (w * h);
    final psnr = mse == 0 ? 99.0 : 10 * math.log(255 * 255 / mse) / math.ln10;
    sumPsnr += psnr;
    if (diff != 0 && firstMismatch < 0) {
      firstMismatch = f;
      final plane = firstPos < w * h ? 'Y' : 'C';
      final p = firstPos < w * h ? firstPos : firstPos - w * h;
      stdout.writeln('first mismatch frame $f plane $plane pos $p '
          '(x=${p % w}, y=${p ~/ w}) count=$diff');
    }
  }
  stdout.writeln('avg Y PSNR ${(sumPsnr / n).toStringAsFixed(2)} dB, '
      'identical=${firstMismatch < 0}');
}
