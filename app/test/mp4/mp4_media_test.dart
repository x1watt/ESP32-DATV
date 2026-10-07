import 'dart:io';

import 'package:esp32_datv/core/codec/mp4/mp4.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mp4_test_util.dart';

const String kSintel =
    '../media/sintel_trailer.mp4';

/// Compares the sample table of [trackId] with ffprobe packets of [stream].
Future<void> compareWithProbe(
  Mp4File f,
  String path,
  int trackId,
  String stream, {
  bool checkPos = true,
}) async {
  final probe = ffprobePackets(path, stream);
  final t = f.track(trackId);
  final table = f.sampleTable(trackId);
  expect(table.length, probe.length, reason: 'packet count $stream');
  for (var i = 0; i < table.length; i++) {
    final s = table[i];
    final p = probe[i];
    expect(s.size, p.size, reason: '$stream #$i size');
    expect(s.isSync, p.key, reason: '$stream #$i key');
    if (checkPos && p.pos >= 0) {
      expect(s.offset, p.pos, reason: '$stream #$i pos');
    }
    if (p.ptsTime != null) {
      expect(
        (t.ptsUsOf(s) - p.ptsTime! * 1e6).abs(),
        lessThanOrEqualTo(1.5),
        reason: '$stream #$i pts ${t.ptsUsOf(s)} vs ${p.ptsTime}',
      );
    }
    if (p.dtsTime != null) {
      expect(
        (t.dtsUsOf(s) - p.dtsTime! * 1e6).abs(),
        lessThanOrEqualTo(1.5),
        reason: '$stream #$i dts ${t.dtsUsOf(s)} vs ${p.dtsTime}',
      );
    }
  }
}

Future<void> checkStreams(Mp4File f, FileByteSource src) async {
  final v = f.firstVideoTrack!;
  final a = f.firstAudioTrack!;
  // samples() must deliver exactly the bytes at the table offsets.
  final vs = await f.samples(v.id).toList();
  expect(vs.length, v.sampleCount);
  for (final i in [0, 1, vs.length ~/ 2, vs.length - 1]) {
    final direct = await src.read(vs[i].offset, vs[i].size);
    expect(vs[i].data, direct);
    expect(vs[i].data.length, vs[i].size);
  }
  final nals = splitLengthPrefixedNals(vs.first.data, v.avc!.nalLengthSize);
  expect(nals.any((n) => (n[0] & 0x1F) == 5), isTrue, reason: 'IDR in first');

  final all = await f.interleaved().toList();
  expect(all.length, v.sampleCount + a.sampleCount);
  final seen = <int, int>{v.id: 0, a.id: 0};
  for (var i = 0; i < all.length; i++) {
    final s = all[i];
    expect(s.index, seen[s.trackId], reason: 'per track order');
    seen[s.trackId] = s.index + 1;
    expect(s.data.length, s.size);
    if (i > 0) {
      expect(s.dtsUs, greaterThanOrEqualTo(all[i - 1].dtsUs));
    }
  }
  expect(seen[v.id], v.sampleCount);
  expect(seen[a.id], a.sampleCount);
}

void main() {
  final haveMedia = File(kSintel).existsSync();
  final haveProbe = toolExists('ffprobe');
  final haveFfmpeg = toolExists('ffmpeg');

  group('sintel_trailer.mp4', () {
    late FileByteSource src;
    late Mp4File f;
    setUpAll(() async {
      if (!haveMedia) return;
      src = FileByteSource(kSintel);
      f = await Mp4File.open(src);
    });
    tearDownAll(() {
      if (haveMedia) src.close();
    });

    test('tracks', () {
      final v = f.firstVideoTrack!;
      expect(v.sampleEntry, 'avc1');
      expect(v.codec, startsWith('avc1.64'));
      expect(v.width, 854);
      expect(v.height, 480);
      expect(v.supported, isTrue);
      final avc = v.avc!;
      expect(avc.profileIdc, 100);
      expect(avc.nalLengthSize, 4);
      expect(avc.sps.length, 1);
      expect(avc.pps.length, 1);
      expect(avc.sps.first[0] & 0x1F, 7);
      expect(avc.pps.first[0] & 0x1F, 8);
      expect(v.sampleCount, 1253);
      expect(v.frameRate, closeTo(24, 0.01));
      expect(v.avgBitrate, greaterThan(0));

      final a = f.firstAudioTrack!;
      expect(a.sampleEntry, 'mp4a');
      expect(a.codec, 'mp4a.40.2');
      expect(a.sampleRate, 48000);
      expect(a.channels, 2);
      expect(a.audioObjectType, 2);
      expect(a.supported, isTrue);
      expect(a.sampleCount, 2435);
    }, skip: !haveMedia);

    test('matches ffprobe', () async {
      await compareWithProbe(f, kSintel, f.firstVideoTrack!.id, 'v');
      await compareWithProbe(f, kSintel, f.firstAudioTrack!.id, 'a');
    }, skip: !haveMedia || !haveProbe);

    test('streams', () async {
      await checkStreams(f, src);
      // Reads are batched: far fewer reads than samples.
      final c = CountingSource(src);
      final f2 = await Mp4File.open(c);
      c.reads = 0;
      await f2.interleaved().drain<void>();
      expect(c.reads, lessThan(f2.firstVideoTrack!.sampleCount));
    }, skip: !haveMedia);

    test('seek', () {
      final v = f.firstVideoTrack!;
      final t = f.sampleTable(v.id);
      final i = f.syncSampleAtOrBefore(v.id, 30000000);
      expect(t[i].isSync, isTrue);
      expect(v.ptsUsOf(t[i]), lessThanOrEqualTo(30000000));
      final next = t.skip(i + 1).where((s) => s.isSync);
      if (next.isNotEmpty) {
        expect(v.ptsUsOf(next.first), greaterThan(30000000));
      }
    }, skip: !haveMedia);
  });

  group('ffmpeg remux', () {
    late Directory tmp;
    setUpAll(() async {
      tmp = await Directory.systemTemp.createTemp('mp4_demux_test');
    });
    tearDownAll(() async {
      await tmp.delete(recursive: true);
    });

    final variants = <String, List<String>>{
      'frag_keyframe+empty_moov': ['-movflags', 'frag_keyframe+empty_moov'],
      'frag default_base_moof': [
        '-movflags',
        'frag_keyframe+empty_moov+default_base_moof',
      ],
      'faststart': ['-movflags', '+faststart'],
    };
    variants.forEach((name, flags) {
      test(name, () async {
        final out =
            '${tmp.path}/${name.replaceAll(RegExp(r'[^a-z_]'), '_')}.mp4';
        final r = Process.runSync('ffmpeg', [
          '-v', 'error', '-y', '-i', kSintel, '-t', '12', '-c', 'copy', //
          ...flags, out,
        ]);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        final src = FileByteSource(out);
        try {
          final f = await Mp4File.open(src);
          final frag = name.startsWith('frag');
          expect(f.isFragmented, frag);
          expect(f.firstVideoTrack!.fragmented, frag);
          expect(f.firstVideoTrack!.width, 854);
          expect(f.firstAudioTrack!.sampleRate, 48000);
          await compareWithProbe(f, out, f.firstVideoTrack!.id, 'v');
          await compareWithProbe(f, out, f.firstAudioTrack!.id, 'a');
          await checkStreams(f, src);
        } finally {
          src.close();
        }
      }, skip: !haveMedia || !haveFfmpeg || !haveProbe);
    });
  });
}
