// Validates the pure Dart AAC-LC decoder against FFmpeg's native decoder.
// Requires system ffmpeg at dev time; tests that need it are skipped when
// it is missing. Temporary files go to $AUDIO_TEST_TMP or the system temp.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:esp32_datv/core/codec/audio/aac_decoder.dart';
import 'package:flutter_test/flutter_test.dart';

const _sintel = '../media/sintel_trailer.mp4';

bool _hasFfmpeg() {
  try {
    return Process.runSync('ffmpeg', ['-version']).exitCode == 0;
  } catch (_) {
    return false;
  }
}

late Directory _tmp;

void _ffmpeg(List<String> args) {
  final r = Process.runSync('ffmpeg', ['-v', 'error', '-y', ...args]);
  if (r.exitCode != 0) throw StateError('ffmpeg failed: ${r.stderr}');
}

class _Cmp {
  _Cmp(this.maxDiff, this.snrDb, this.samples, this.stats);
  final int maxDiff;
  final double snrDb;
  final int samples;
  final AacToolStats stats;
  @override
  String toString() =>
      'samples=$samples maxDiff=$maxDiff '
      'snr=${snrDb.toStringAsFixed(1)} dB, tools: $stats';
}

/// Encodes (or copies) to ADTS with ffmpeg, decodes with both decoders and
/// compares the PCM.
_Cmp _roundTrip(String name, List<String> encodeArgs) {
  final aacPath = '${_tmp.path}/$name.aac';
  final refPath = '${_tmp.path}/$name.raw';
  _ffmpeg([...encodeArgs, '-f', 'adts', aacPath]);
  _ffmpeg(['-i', aacPath, '-f', 's16le', refPath]);
  final aac = File(aacPath).readAsBytesSync();
  final refBytes = File(refPath).readAsBytesSync();
  final ref = refBytes.buffer.asInt16List(0, refBytes.length ~/ 2);
  final frames = AdtsFrame.split(aac).toList();
  expect(frames, isNotEmpty);
  final dec = AacDecoder.fromAdts(frames.first);
  final out = BytesBuilder(copy: false);
  for (final f in frames) {
    for (final b in dec.decodeAdtsFrame(f)) {
      expect(b.channels, dec.channels);
      expect(b.sampleRate, dec.sampleRate);
      out.add(
        b.samples.buffer.asUint8List(
          b.samples.offsetInBytes,
          b.samples.lengthInBytes,
        ),
      );
    }
  }
  final ob = out.takeBytes();
  final ours = ob.buffer.asInt16List(ob.offsetInBytes, ob.length ~/ 2);
  expect(ours.length, ref.length, reason: 'sample count must match ffmpeg');
  var maxDiff = 0;
  var se = 0.0, ss = 0.0;
  for (var i = 0; i < ref.length; i++) {
    final d = ours[i] - ref[i];
    if (d.abs() > maxDiff) maxDiff = d.abs();
    se += d * d;
    ss += ref[i] * ref[i].toDouble();
  }
  final snr = se == 0 ? double.infinity : 10 * math.log(ss / se) / math.ln10;
  return _Cmp(maxDiff, snr, ref.length, dec.stats);
}

void main() {
  final ff = _hasFfmpeg();
  final String? skip = ff ? null : 'system ffmpeg not found';
  final String? skipSintel =
      skip ?? (File(_sintel).existsSync() ? null : 'sintel trailer missing');

  setUpAll(() {
    final env = Platform.environment['AUDIO_TEST_TMP'];
    if (env != null) {
      _tmp = Directory(env)..createSync(recursive: true);
    } else {
      _tmp = Directory.systemTemp.createTempSync('aac_dec_test');
    }
  });
  tearDownAll(() {
    if (Platform.environment['AUDIO_TEST_TMP'] == null) {
      _tmp.deleteSync(recursive: true);
    }
  });

  void check(_Cmp c) {
    // ignore: avoid_print
    print(c);
    expect(c.maxDiff <= 2 || c.snrDb > 90, isTrue, reason: '$c');
  }

  test('sintel trailer AAC track matches ffmpeg', () {
    final c = _roundTrip('sintel', ['-i', _sintel, '-vn', '-c:a', 'copy']);
    check(c);
    expect(c.stats.eightShortWindows, greaterThan(0));
  }, skip: skipSintel);

  test('16 kHz mono', () {
    check(
      _roundTrip('m16', [
        '-f', 'lavfi', '-i', 'sine=f=440:r=16000:d=5', //
        '-ac', '1', '-ar', '16000', '-c:a', 'aac', '-b:a', '24k',
      ]),
    );
  }, skip: skip);

  test('24 kHz mono pink noise (PNS)', () {
    final c = _roundTrip('m24', [
      '-f', 'lavfi', '-i', 'anoisesrc=r=24000:d=5:c=pink:a=0.3', //
      '-ac', '1', '-c:a', 'aac', '-b:a', '32k',
    ]);
    check(c);
    expect(c.stats.pnsBands, greaterThan(0));
  }, skip: skip);

  test('44.1 kHz stereo music with IS/PNS/MS/TNS', () {
    final c = _roundTrip('s44', [
      '-i', _sintel, '-t', '20', '-vn', '-ac', '2', '-ar', '44100', //
      '-c:a', 'aac', '-b:a', '96k', '-aac_is', '1', '-aac_pns', '1',
      '-aac_ms', '1', '-aac_tns', '1',
    ]);
    check(c);
    expect(c.stats.intensityBands, greaterThan(0));
    expect(c.stats.msBands, greaterThan(0));
    expect(c.stats.tnsFilters, greaterThan(0));
  }, skip: skipSintel);

  test('48 kHz stereo clicks (short blocks, escapes)', () {
    final c = _roundTrip('clicks', [
      '-f',
      'lavfi',
      '-i',
      'aevalsrc=exprs=if(lt(mod(t\\,0.25)\\,0.002)\\,0.9*sin(2*PI*3000*t)'
          '\\,0.01*sin(2*PI*200*t))|if(lt(mod(t+0.1\\,0.3)\\,0.003)\\,0.8\\,0)'
          ':s=48000:d=6',
      '-ac',
      '2',
      '-c:a',
      'aac',
      '-b:a',
      '128k',
      '-aac_tns',
      '1',
    ]);
    check(c);
    expect(c.stats.eightShortWindows, greaterThan(10));
    expect(c.stats.escapes, greaterThan(0));
  }, skip: skip);

  test('AudioSpecificConfig parsing', () {
    final lc = AacConfig.parse(Uint8List.fromList([0x11, 0x90]));
    expect(lc.objectType, 2);
    expect(lc.sampleRate, 48000);
    expect(lc.channels, 2);
    expect(lc.sbrSignalled, isFalse);

    // Explicit hierarchical HE-AAC: AOT 5, core 24 kHz stereo, SBR 48 kHz.
    final he = AacConfig.parse(Uint8List.fromList([0x2b, 0x11, 0x88, 0x00]));
    expect(he.objectType, 2);
    expect(he.sampleRate, 24000);
    expect(he.extensionSampleRate, 48000);
    expect(he.sbrSignalled, isTrue);
    final d = AacDecoder.fromAudioSpecificConfig(
      Uint8List.fromList([0x2b, 0x11, 0x88, 0x00]),
    );
    expect(d.sbrSignalled, isTrue);
    expect(d.sampleRate, 24000);

    // Backward compatible sync extension (0x2b7) signalling.
    final bc = AacConfig.parse(
      Uint8List.fromList([0x13, 0x10, 0x56, 0xe5, 0x98]),
    );
    expect(bc.objectType, 2);
    expect(bc.sampleRate, 24000);
    expect(bc.sbrSignalled, isTrue);
    expect(bc.extensionSampleRate, 48000);
  });

  test('ADTS header writer round trips', () {
    for (final sfi in [3, 4, 6, 8]) {
      for (final ch in [1, 2]) {
        final asc = AacConfig.buildAsc(2, sfi, ch);
        final payload = Uint8List(321);
        final hdr = adtsHeader(asc, payload.length);
        expect(hdr.length, 7);
        final f = AdtsFrame.parse(Uint8List.fromList([...hdr, ...payload]))!;
        expect(f.objectType, 2);
        expect(f.samplingIndex, sfi);
        expect(f.channelConfig, ch);
        expect(f.frameLength, 328);
        expect(f.payload.length, 321);
        expect(f.audioSpecificConfig, asc);
      }
    }
    // HE-AAC config is written as implicit (LC core, core rate).
    final h = AdtsFrame.parse(
      Uint8List.fromList([
        ...adtsHeader(Uint8List.fromList([0x2b, 0x11, 0x88, 0x00]), 10),
        ...Uint8List(10),
      ]),
    )!;
    expect(h.objectType, 2);
    expect(h.sampleRate, 24000);
  });

  test('ADTS remux of sintel matches ffmpeg byte stream', () {
    final aacPath = '${_tmp.path}/sintel_copy.aac';
    _ffmpeg(['-i', _sintel, '-vn', '-c:a', 'copy', '-f', 'adts', aacPath]);
    final data = File(aacPath).readAsBytesSync();
    var n = 0;
    for (final f in AdtsFrame.split(data)) {
      final h = adtsHeader(f.audioSpecificConfig, f.payload.length);
      // Bytes 0..5 (except buffer fullness bits) must match.
      final off = f.payload.offsetInBytes - f.headerLength;
      for (var i = 0; i < 5; i++) {
        expect(h[i], data[off + i]);
      }
      expect(h[5] & 0xe0, data[off + 5] & 0xe0);
      n++;
    }
    expect(n, greaterThan(100));
  }, skip: skipSintel);
}
