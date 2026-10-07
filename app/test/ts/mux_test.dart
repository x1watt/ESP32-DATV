import 'dart:io';
import 'dart:typed_data';

import 'package:esp32_datv/core/ts/crc32.dart';
import 'package:esp32_datv/core/ts/mux.dart';
import 'package:esp32_datv/core/ts/ts_rate.dart';
import 'package:test/test.dart';

/// Splits an Annex B stream with AUDs into access units.
List<Uint8List> splitAus(Uint8List s) {
  final starts = <int>[];
  for (var i = 0; i + 4 < s.length; i++) {
    if (s[i] == 0 && s[i + 1] == 0 && s[i + 2] == 0 && s[i + 3] == 1 && (s[i + 4] & 0x1F) == 9) starts.add(i);
  }
  starts.add(s.length);
  return [for (var i = 0; i + 1 < starts.length; i++) Uint8List.sublistView(s, starts[i], starts[i + 1])];
}

/// Splits MP2 frames (MPEG-1 layer II, 48 kHz, fixed bitrate) by sync words.
List<Uint8List> splitMp2(Uint8List s) {
  final out = <Uint8List>[];
  var i = 0;
  const br = [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384];
  while (i + 4 <= s.length) {
    if (s[i] != 0xFF || (s[i + 1] & 0xF0) != 0xF0) {
      i++;
      continue;
    }
    final kbps = br[s[i + 2] >> 4];
    final len = 144000 * kbps ~/ 48000 + ((s[i + 2] >> 1) & 1);
    out.add(Uint8List.sublistView(s, i, (i + len).clamp(0, s.length)));
    i += len;
  }
  return out;
}

void main() {
  test('CRC-32/MPEG-2 check value', () {
    expect(crc32Mpeg(Uint8List.fromList('123456789'.codeUnits)), 0x0376E6E7);
  });

  final hasFfmpeg = Process.runSync('which', ['ffmpeg']).exitCode == 0;
  test('muxed TS decodes cleanly with ffmpeg (dev-only check)', () {
    final dir = Directory.systemTemp.createTempSync('mux');
    Process.runSync('ffmpeg', [
      '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=15', '-t', '4',
      '-c:v', 'libx264', '-profile:v', 'baseline', '-b:v', '200k', '-x264-params', 'aud=1',
      '-bsf:v', 'h264_mp4toannexb', '-f', 'h264', '${dir.path}/v.h264',
    ]);
    Process.runSync('ffmpeg', [
      '-v', 'error', '-f', 'lavfi', '-i', 'sine=frequency=800:sample_rate=48000', '-t', '4',
      '-c:a', 'mp2', '-b:a', '96k', '-ac', '1', '-f', 'mp2', '${dir.path}/a.mp2',
    ]);
    final aus = splitAus(File('${dir.path}/v.h264').readAsBytesSync());
    final afr = splitMp2(File('${dir.path}/a.mp2').readAsBytesSync());
    expect(aus.length, 60);
    final mux = TsMuxer(muxRate: 500000, audio: StreamKind.mp2);
    final out = BytesBuilder();
    var vi = 0, ai = 0;
    const fd = 1000000 ~/ 15;
    const ad = 1152 * 1000000 ~/ 48000;
    // feed at real time relative to the mux clock, 0.5 s ahead
    while (out.length < 500000 / 8 * 6) {
      final t = mux.clockSeconds * 1e6 + 500000;
      while (vi < aus.length && vi * fd < t) {
        mux.addVideo(aus[vi], ptsUs: vi * fd, key: vi == 0);
        vi++;
      }
      while (ai < afr.length && ai * ad < t) {
        mux.addAudio(afr[ai], ptsUs: ai * ad);
        ai++;
      }
      out.add(mux.take(7));
    }
    File('${dir.path}/o.ts').writeAsBytesSync(out.takeBytes());
    // the rate measured from the PCRs equals the mux rate
    expect(measureTsRate(File('${dir.path}/o.ts').readAsBytesSync()), closeTo(500000, 2000));
    final r = Process.runSync('ffmpeg', ['-v', 'error', '-i', '${dir.path}/o.ts', '-f', 'null', '-']);
    expect(r.stderr.toString().trim(), '');
    final p = Process.runSync('ffprobe', [
      '-v', 'error', '-show_entries', 'stream=codec_name:program=program_id', '-show_entries', 'format=bit_rate',
      '-of', 'compact', '${dir.path}/o.ts',
    ]);
    // ignore: avoid_print
    print(p.stdout);
    expect(p.stdout.toString(), contains('codec_name=h264'));
    expect(p.stdout.toString(), contains('codec_name=mp2'));
    expect(mux.stats.latePackets, 0);
    final n = Process.runSync('ffprobe', ['-v', 'error', '-count_frames', '-select_streams', 'v', '-show_entries',
      'stream=nb_read_frames', '-of', 'csv=p=0', '${dir.path}/o.ts']);
    expect(n.stdout.toString().trim().split(RegExp(r'\s+')).last, '60');
    dir.deleteSync(recursive: true);
  }, skip: hasFfmpeg ? false : 'ffmpeg not installed');
}
