// Helpers for the H.264 encoder tests. The system ffmpeg is only used as an
// independent reference decoder; tests skip when it is not installed.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:esp32_datv/core/codec/frame.dart';

bool? _ffmpeg;

bool ffmpegAvailable() {
  if (_ffmpeg != null) return _ffmpeg!;
  try {
    final r = Process.runSync('ffmpeg', ['-hide_banner', '-version']);
    _ffmpeg = r.exitCode == 0;
  } catch (_) {
    _ffmpeg = false;
  }
  return _ffmpeg!;
}

class DecodeResult {
  DecodeResult(this.exitCode, this.stderr, this.yuv);
  final int exitCode;
  final String stderr;
  final Uint8List yuv;

  int frameCount(int w, int h) => yuv.length ~/ (w * h * 3 ~/ 2);
}

/// Decodes an Annex B stream with ffmpeg, failing on any decoder error.
DecodeResult ffmpegDecode(Uint8List stream, Directory tmp, String name) {
  final f = File('${tmp.path}/$name.264')..writeAsBytesSync(stream);
  final r = Process.runSync(
    'ffmpeg',
    [
      '-hide_banner', '-nostdin', '-v', 'error', '-xerror', //
      '-err_detect', 'explode',
      '-i', f.path, '-fps_mode', 'passthrough',
      '-f', 'rawvideo', '-pix_fmt', 'yuv420p', '-',
    ],
    stdoutEncoding: null,
  );
  return DecodeResult(
      r.exitCode, (r.stderr as String).trim(), Uint8List.fromList(r.stdout as List<int>));
}

/// ffprobe stream description (codec profile, level, size), or null.
Map<String, String>? ffprobeInfo(Directory tmp, String name) {
  try {
    final r = Process.runSync('ffprobe', [
      '-v', 'error', '-select_streams', 'v:0', //
      '-show_entries', 'stream=profile,level,width,height,pix_fmt',
      '-of', 'default=noprint_wrappers=1',
      '${tmp.path}/$name.264',
    ]);
    if (r.exitCode != 0) return null;
    final m = <String, String>{};
    for (final line in (r.stdout as String).split('\n')) {
      final i = line.indexOf('=');
      if (i > 0) m[line.substring(0, i)] = line.substring(i + 1).trim();
    }
    return m;
  } catch (_) {
    return null;
  }
}

/// Raw I420 bytes of a frame.
void appendFrame(BytesBuilder b, I420Frame f) {
  b.add(f.y);
  b.add(f.u);
  b.add(f.v);
}

/// Luma PSNR between two I420 frames stored at frame index [i] of buffers.
double psnrY(Uint8List a, Uint8List b, int w, int h, int i) {
  final fs = w * h * 3 ~/ 2;
  final oa = i * fs, ob = i * fs;
  var se = 0;
  for (var k = 0; k < w * h; k++) {
    final d = a[oa + k] - b[ob + k];
    se += d * d;
  }
  if (se == 0) return 99.0;
  final mse = se / (w * h);
  return 10 * math.log(255 * 255 / mse) / math.ln10;
}

/// Average luma PSNR over all frames, plus the minimum.
(double avg, double min) psnrStats(Uint8List a, Uint8List b, int w, int h) {
  final n = math.min(a.length, b.length) ~/ (w * h * 3 ~/ 2);
  var sum = 0.0, mn = 99.0;
  for (var i = 0; i < n; i++) {
    final p = psnrY(a, b, w, h, i);
    sum += p;
    if (p < mn) mn = p;
  }
  return (sum / n, mn);
}

/// Index of the first differing byte, or -1.
int firstDifference(Uint8List a, Uint8List b) {
  final n = math.min(a.length, b.length);
  for (var i = 0; i < n; i++) {
    if (a[i] != b[i]) return i;
  }
  return a.length == b.length ? -1 : n;
}

/// Decodes the media file into raw I420 at the given size (dev only).
Uint8List? ffmpegLoadVideo(String path, int w, int h, int frames,
    {double startSeconds = 0}) {
  if (!File(path).existsSync()) return null;
  final r = Process.runSync(
    'ffmpeg',
    [
      '-hide_banner', '-nostdin', '-v', 'error', //
      if (startSeconds > 0) ...['-ss', '$startSeconds'],
      '-i', path,
      '-frames:v', '$frames', '-vf', 'scale=$w:$h',
      '-f', 'rawvideo', '-pix_fmt', 'yuv420p', '-',
    ],
    stdoutEncoding: null,
  );
  if (r.exitCode != 0) return null;
  return Uint8List.fromList(r.stdout as List<int>);
}

/// Splits Annex B data into NAL unit types in order.
List<int> nalTypes(Uint8List d) {
  final out = <int>[];
  for (var i = 0; i + 3 < d.length; i++) {
    if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1) {
      out.add(d[i + 3] & 0x1f);
      i += 3;
    }
  }
  return out;
}
