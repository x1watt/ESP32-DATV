// Shared helpers for audio codec tests (dev time only, uses dart:io and
// the system ffmpeg when available).

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

const String sintelPath = '../media/sintel_trailer.mp4';

bool? _ffmpeg;

bool hasFfmpeg() {
  if (_ffmpeg != null) return _ffmpeg!;
  try {
    final a = Process.runSync('ffmpeg', ['-version']);
    final b = Process.runSync('ffprobe', ['-version']);
    _ffmpeg = a.exitCode == 0 && b.exitCode == 0;
  } catch (_) {
    _ffmpeg = false;
  }
  return _ffmpeg!;
}

Directory tempDir(String name) {
  final base = Platform.environment['AUDIO_TEST_TMP'];
  final d = base != null
      ? Directory('$base/$name')
      : Directory.systemTemp.createTempSync('esp32datv_$name');
  d.createSync(recursive: true);
  return d;
}

/// Runs ffmpeg; returns stdout bytes, throws with stderr on failure.
Uint8List ffmpeg(List<String> args) {
  final r = Process.runSync('ffmpeg', ['-hide_banner', '-nostdin', ...args],
      stdoutEncoding: null, stderrEncoding: systemEncoding);
  if (r.exitCode != 0) {
    throw StateError('ffmpeg ${args.join(' ')} failed: ${r.stderr}');
  }
  return Uint8List.fromList(r.stdout as List<int>);
}

Int16List bytesToS16(Uint8List b) =>
    Int16List.view(Uint8List.fromList(b).buffer, 0, b.length ~/ 2);

/// Extracts PCM from a media file as interleaved s16le.
Int16List extractPcm(String path, int rate, int channels, {double? ss, double? t}) {
  final out = ffmpeg([
    '-v', 'error',
    if (ss != null) ...['-ss', '$ss'],
    '-i', path,
    if (t != null) ...['-t', '$t'],
    '-vn', '-ac', '$channels', '-ar', '$rate', '-f', 's16le', '-',
  ]);
  return bytesToS16(out);
}

/// Best lag (b delayed relative to a) by cross-correlation on channel 0.
int bestLag(Int16List a, Int16List b, int channels, int maxLag) {
  final n = math.min(a.length ~/ channels, b.length ~/ channels) - maxLag;
  var best = 0;
  var bestV = -1e300;
  for (var lag = 0; lag <= maxLag; lag++) {
    var s = 0.0;
    for (var i = 0; i < n; i += 2) {
      s += a[i * channels] * b[(i + lag) * channels].toDouble();
    }
    if (s > bestV) {
      bestV = s;
      best = lag;
    }
  }
  return best;
}

class Cmp {
  Cmp(this.snrDb, this.corr, this.maxDiff, this.n);
  final double snrDb;
  final double corr;
  final int maxDiff;
  final int n;
  @override
  String toString() =>
      'SNR ${snrDb.toStringAsFixed(2)} dB, corr ${corr.toStringAsFixed(4)}, maxdiff $maxDiff, n $n';
}

/// Compares ref against test delayed by [lag] frames, skipping [skip]
/// frames at the start and the last [tail] frames.
Cmp compare(Int16List ref, Int16List test, int channels,
    {int lag = 0, int skip = 0, int tail = 0}) {
  final n = math.min(ref.length ~/ channels, test.length ~/ channels - lag) - tail;
  var se = 0.0, sr = 0.0, st = 0.0, srt = 0.0;
  var md = 0;
  var cnt = 0;
  for (var i = skip; i < n; i++) {
    for (var c = 0; c < channels; c++) {
      final r = ref[i * channels + c].toDouble();
      final t = test[(i + lag) * channels + c].toDouble();
      final d = r - t;
      se += d * d;
      sr += r * r;
      st += t * t;
      srt += r * t;
      final ad = d.abs().toInt();
      if (ad > md) md = ad;
      cnt++;
    }
  }
  final snr = se == 0 ? 200.0 : 10 * math.log(sr / se) / math.ln10;
  final corr = (sr == 0 || st == 0) ? 0.0 : srt / math.sqrt(sr * st);
  return Cmp(snr, corr, md, cnt);
}

/// Logarithmic sine sweep, amplitude [amp] of full scale.
Int16List sineSweep(int rate, int channels, double seconds, double f0, double f1,
    {double amp = 0.5}) {
  final n = (rate * seconds).round();
  final out = Int16List(n * channels);
  final k = math.log(f1 / f0);
  for (var i = 0; i < n; i++) {
    final t = i / rate;
    final phase = 2 * math.pi * f0 * seconds / k * (math.exp(t / seconds * k) - 1);
    final v = (amp * 32767 * math.sin(phase)).round();
    for (var c = 0; c < channels; c++) {
      out[i * channels + c] = c == 0 ? v : (v * 0.7).round();
    }
  }
  return out;
}

/// Speech-like noise: pinkish noise band-limited to roughly 100..4000 Hz
/// with a 4 Hz syllabic envelope and pauses.
Int16List speechNoise(int rate, int channels, double seconds, {int seed = 1}) {
  final rnd = math.Random(seed);
  final n = (rate * seconds).round();
  final out = Int16List(n * channels);
  var b0 = 0.0, b1 = 0.0, b2 = 0.0, lp = 0.0, hp = 0.0, prev = 0.0;
  final aLp = 1 - math.exp(-2 * math.pi * 4000 / rate);
  final aHp = math.exp(-2 * math.pi * 100 / rate);
  for (var i = 0; i < n; i++) {
    final w = rnd.nextDouble() * 2 - 1;
    b0 = 0.99765 * b0 + w * 0.0990460;
    b1 = 0.96300 * b1 + w * 0.2965164;
    b2 = 0.57000 * b2 + w * 1.0526913;
    final pink = (b0 + b1 + b2 + w * 0.1848) * 0.2;
    lp += aLp * (pink - lp);
    hp = aHp * (hp + lp - prev);
    prev = lp;
    final t = i / rate;
    final env = math.max(0.0, math.sin(2 * math.pi * 4 * t)) *
        (math.sin(2 * math.pi * 0.3 * t) > -0.3 ? 1.0 : 0.05);
    final v = (hp * env * 1.5 * 32767).round().clamp(-32768, 32767);
    for (var c = 0; c < channels; c++) {
      out[i * channels + c] = v;
    }
  }
  return out;
}

Uint8List concat(List<Uint8List> parts) {
  final b = BytesBuilder(copy: false);
  for (final p in parts) {
    b.add(p);
  }
  return b.takeBytes();
}
