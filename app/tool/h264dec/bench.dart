// Dev benchmark: demuxes an MP4 into memory, then measures pure H.264
// decode throughput of the Dart decoder.
//
//   dart compile exe tool/h264dec/bench.dart -o /tmp/h264bench
//   /tmp/h264bench ../media/sintel_trailer.mp4 [runs]
import 'dart:io';
import 'dart:typed_data';

import 'package:esp32_datv/core/codec/h264dec/h264dec.dart';
import 'package:esp32_datv/core/codec/mp4/mp4.dart';

Future<void> main(List<String> args) async {
  final path = args.isNotEmpty ? args[0] : '../media/sintel_trailer.mp4';
  final runs = args.length > 1 ? int.parse(args[1]) : 3;
  final mp4 = await Mp4File.open(MemoryByteSource(File(path).readAsBytesSync()));
  final track = mp4.firstVideoTrack!;
  final avc = track.avc!;
  final samples = <List<Uint8List>>[];
  final pts = <int>[];
  await for (final s in mp4.samples(track.id)) {
    samples.add(splitLengthPrefixedNals(s.data, avc.nalLengthSize));
    pts.add(s.ptsUs);
  }
  stdout.writeln('$path: ${track.codec} ${track.width}x${track.height}, ${samples.length} samples');
  final results = <double>[];
  for (var run = 0; run < runs; run++) {
    final dec = H264Decoder();
    final sw = Stopwatch()..start();
    var frames = 0;
    frames += dec.decodeNals([...avc.sps, ...avc.pps]).length;
    for (var i = 0; i < samples.length; i++) {
      frames += dec.decodeNals(samples[i], ptsUs: pts[i]).length;
    }
    frames += dec.flush().length;
    sw.stop();
    final fps = frames / (sw.elapsedMicroseconds / 1e6);
    results.add(fps);
    stdout.writeln(
      'run $run: $frames frames in ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(2)} s '
      '= ${fps.toStringAsFixed(1)} fps',
    );
  }
  results.sort();
  stdout.writeln(
    'best ${results.last.toStringAsFixed(1)} fps, median ${results[results.length ~/ 2].toStringAsFixed(1)} fps',
  );
}
