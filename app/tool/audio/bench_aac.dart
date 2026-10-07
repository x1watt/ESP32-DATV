// Dev-only AOT benchmark for the AAC-LC decoder.
//
//   ffmpeg -i ../media/sintel_trailer.mp4 -vn -c:a copy -f adts /tmp/x.aac
//   dart compile exe tool/audio/bench_aac.dart -o <scratch>/bench_aac
//   <scratch>/bench_aac /tmp/x.aac [iterations]
import 'dart:io';

import 'package:esp32_datv/core/codec/audio/aac_decoder.dart';

void main(List<String> args) {
  final data = File(args[0]).readAsBytesSync();
  final iters = args.length > 1 ? int.parse(args[1]) : 5;
  final frames = AdtsFrame.split(data).toList();
  final rate = frames.first.sampleRate;
  final audioSec = frames.length * 1024 / rate;
  var best = double.infinity;
  for (var it = 0; it < iters; it++) {
    final dec = AacDecoder.fromAdts(frames.first);
    final sw = Stopwatch()..start();
    var n = 0;
    for (final f in frames) {
      for (final b in dec.decodeAdtsFrame(f)) {
        n += b.frames;
      }
    }
    sw.stop();
    final s = sw.elapsedMicroseconds / 1e6;
    if (s < best) best = s;
    stdout.writeln(
      'iter $it: $n samples/ch in ${(s * 1000).toStringAsFixed(1)} ms',
    );
  }
  stdout.writeln(
    'AAC decode: ${frames.length} frames, '
    '${audioSec.toStringAsFixed(1)} s audio @ $rate Hz, best '
    '${(best * 1000).toStringAsFixed(1)} ms = '
    '${(audioSec / best).toStringAsFixed(0)}x realtime',
  );
}
