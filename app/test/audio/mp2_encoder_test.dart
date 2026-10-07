// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:esp32_datv/core/codec/audio/mp2_encoder.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_util.dart';

class Tier {
  const Tier(this.rate, this.ch, this.kbps, this.minCorrSpeech);
  final int rate;
  final int ch;
  final int kbps;
  final double minCorrSpeech;
  @override
  String toString() => '${rate ~/ 1000}k/${ch}ch/${kbps}kbps';
}

const tiers = [
  Tier(16000, 1, 8, 0.7),
  Tier(16000, 1, 16, 0.8),
  Tier(24000, 1, 32, 0.88),
  Tier(48000, 2, 96, 0.94),
  Tier(48000, 1, 64, 0.94),
  Tier(48000, 2, 128, 0.94),
  Tier(48000, 2, 192, 0.96),
  Tier(44100, 2, 128, 0.94),
  Tier(22050, 1, 32, 0.88),
];

Uint8List encodeAll(Mp2Encoder enc, Int16List pcm) {
  final frames = <Uint8List>[];
  // Feed in odd sized chunks to exercise buffering.
  var pos = 0;
  var chunk = 1000;
  while (pos < pcm.length ~/ enc.channels) {
    final n = (pcm.length ~/ enc.channels - pos).clamp(0, chunk);
    frames.addAll(enc.encode(Int16List.sublistView(pcm, pos * enc.channels, (pos + n) * enc.channels)));
    pos += n;
    chunk = chunk == 1000 ? 333 : 1000;
  }
  frames.addAll(enc.flush());
  return concat(frames);
}

void main() {
  test('frame sizes, durations and validation', () {
    final e = Mp2Encoder(48000, 2, 96);
    expect(e.frameBytes, 288);
    expect(e.frameDurationUs, 24000);
    expect(Mp2Encoder(16000, 1, 8).frameBytes, 72);
    expect(Mp2Encoder(16000, 1, 8).frameDurationUs, 72000);
    expect(Mp2Encoder(24000, 1, 32).frameBytes, 192);
    expect(() => Mp2Encoder(48000, 2, 48), throwsArgumentError);
    expect(() => Mp2Encoder(48000, 1, 256), throwsArgumentError);
    expect(() => Mp2Encoder(16000, 1, 192), throwsArgumentError);
    expect(() => Mp2Encoder(8000, 1, 8), throwsArgumentError);

    // 44.1 kHz padding: average frame length must match the bitrate.
    final p = Mp2Encoder(44100, 2, 128);
    final out = p.encode(Int16List(1152 * 2 * 49));
    final total = out.fold<int>(0, (s, f) => s + f.length);
    final expected = 49 * 1152 * 128000 / 8 / 44100;
    expect((total - expected).abs(), lessThan(1.0));
    expect(out.map((f) => f.length).toSet(), {417, 418});
    for (final f in out) {
      expect(f[0], 0xff);
      expect(f[1] & 0xf0, 0xf0);
    }
  });

  final ff = hasFfmpeg();
  final music = <int, Map<int, Int16List>>{};

  Int16List musicPcm(int rate, int ch) => music.putIfAbsent(rate, () => {}).putIfAbsent(
      ch, () => extractPcm(sintelPath, rate, ch, ss: 20, t: 12));

  for (final tier in tiers) {
    test('mp2 $tier decodes cleanly with ffmpeg', () {
      final dir = tempDir('mp2');
      final signals = <String, Int16List>{
        'sweep': sineSweep(tier.rate, tier.ch, 6, 60, tier.rate * 0.45, amp: 0.5),
        'speech': speechNoise(tier.rate, tier.ch, 6),
        if (File(sintelPath).existsSync()) 'music': musicPcm(tier.rate, tier.ch),
      };
      for (final entry in signals.entries) {
        final enc = Mp2Encoder(tier.rate, tier.ch, tier.kbps);
        final sw = Stopwatch()..start();
        final bits = encodeAll(enc, entry.value);
        sw.stop();
        final f = File('${dir.path}/${tier.rate}_${tier.ch}_${tier.kbps}_${entry.key}.mp2')
          ..writeAsBytesSync(bits);
        // Strict decode: any error aborts with nonzero exit.
        final r = Process.runSync('ffmpeg', [
          '-hide_banner', '-nostdin', '-v', 'error', '-xerror', '-i', f.path,
          '-f', 's16le', '-'
        ], stdoutEncoding: null);
        expect(r.exitCode, 0, reason: r.stderr.toString());
        expect((r.stderr as String).trim(), isEmpty, reason: r.stderr.toString());
        final dec = bytesToS16(Uint8List.fromList(r.stdout as List<int>));
        final lag = bestLag(entry.value, dec, tier.ch, 1500);
        final cmp = compare(entry.value, dec, tier.ch, lag: lag, skip: 2000, tail: 2000);

        // Reference: ffmpeg's own mp2 encoder at the same settings.
        final refMp2 = '${dir.path}/ref_${entry.key}.mp2';
        final rawIn = '${dir.path}/in.raw';
        File(rawIn).writeAsBytesSync(entry.value.buffer.asUint8List(
            entry.value.offsetInBytes, entry.value.lengthInBytes));
        ffmpeg(['-v', 'error', '-y', '-f', 's16le', '-ar', '${tier.rate}', '-ac', '${tier.ch}',
            '-i', rawIn, '-c:a', 'mp2', '-b:a', '${tier.kbps}k', refMp2]);
        final refDec = bytesToS16(ffmpeg(['-v', 'error', '-i', refMp2, '-f', 's16le', '-']));
        final refLag = bestLag(entry.value, refDec, tier.ch, 1500);
        final refCmp = compare(entry.value, refDec, tier.ch, lag: refLag, skip: 2000, tail: 2000);
        final secs = entry.value.length / tier.ch / tier.rate;
        print('MP2 $tier ${entry.key.padRight(6)} lag $lag: $cmp | ffmpeg-mp2: '
            'SNR ${refCmp.snrDb.toStringAsFixed(2)} corr ${refCmp.corr.toStringAsFixed(4)} | '
            'JIT ${(secs / (sw.elapsedMicroseconds / 1e6)).toStringAsFixed(0)}x RT');
        expect(lag, mp2CodecDelaySamples);
        if (entry.key == 'speech') {
          expect(cmp.corr, greaterThan(tier.minCorrSpeech));
        }
        expect(cmp.corr, greaterThan(entry.key == 'music' ? 0.8 : 0.5));
      }

      // ffprobe identification.
      final probe = Process.runSync('ffprobe', [
        '-v', 'error', '-show_streams', '-of', 'json',
        '${dir.path}/${tier.rate}_${tier.ch}_${tier.kbps}_speech.mp2'
      ]);
      final js = jsonDecode(probe.stdout as String) as Map<String, dynamic>;
      final st = (js['streams'] as List).first as Map<String, dynamic>;
      expect(st['codec_name'], 'mp2');
      expect(st['sample_rate'], '${tier.rate}');
      expect(st['channels'], tier.ch);
      expect(st['bit_rate'], '${tier.kbps * 1000}');
    }, skip: ff ? false : 'ffmpeg not installed');
  }
}
