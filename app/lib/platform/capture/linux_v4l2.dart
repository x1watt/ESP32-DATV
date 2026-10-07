/// Linux camera capture through V4L2 (dart:ffi on libc: open/ioctl/mmap/poll).
///
/// Picks YUYV (or UYVY, I420, NV12) at the largest size not wider than maxWidth that still
/// reaches the requested frame rate; cameras that only offer MJPEG are decoded with the
/// small baseline decoder in jpeg_decoder.dart. Struct layouts are those of 64-bit Linux
/// (x86_64, arm64).
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'isolate_capture.dart';
import 'jpeg_decoder.dart';
import 'media_source.dart';
import 'pixel_pack.dart';

// ---------------------------------------------------------------- libc

final DynamicLibrary _libc = DynamicLibrary.open('libc.so.6');

final int Function(Pointer<Utf8>, int) _open = _libc
    .lookupFunction<Int32 Function(Pointer<Utf8>, Int32), int Function(Pointer<Utf8>, int)>('open');
final int Function(int) _close = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('close');
final int Function(int, int, Pointer<Uint8>) _ioctl = _libc
    .lookupFunction<
      Int32 Function(Int32, UnsignedLong, VarArgs<(Pointer<Uint8>,)>),
      int Function(int, int, Pointer<Uint8>)
    >('ioctl');
final Pointer<Uint8> Function(Pointer<Void>, int, int, int, int, int) _mmap = _libc
    .lookupFunction<
      Pointer<Uint8> Function(Pointer<Void>, Size, Int32, Int32, Int32, Int64),
      Pointer<Uint8> Function(Pointer<Void>, int, int, int, int, int)
    >('mmap');
final int Function(Pointer<Uint8>, int) _munmap = _libc
    .lookupFunction<Int32 Function(Pointer<Uint8>, Size), int Function(Pointer<Uint8>, int)>('munmap');
final int Function(Pointer<Int32>, int, int) _poll = _libc
    .lookupFunction<Int32 Function(Pointer<Int32>, Uint64, Int32), int Function(Pointer<Int32>, int, int)>('poll');
final Pointer<Int32> Function() _errnoLoc = _libc.lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
  '__errno_location',
);

int get _errno => _errnoLoc().value;

const int _oRdwr = 2, _oNonblock = 0x800, _oCloexec = 0x80000;
const int _eintr = 4, _eagain = 11, _ebusy = 16, _eacces = 13;

// ---------------------------------------------------------------- V4L2 ABI (64-bit)

int _ioc(int dir, int nr, int size) => (dir << 30) | (size << 16) | (0x56 << 8) | nr;
const int _r = 2, _w = 1, _rw = 3;
final int _querycap = _ioc(_r, 0, 104);
final int _enumFmt = _ioc(_rw, 2, 64);
final int _sFmt = _ioc(_rw, 5, 208);
final int _reqbufs = _ioc(_rw, 8, 20);
final int _querybuf = _ioc(_rw, 9, 88);
final int _qbuf = _ioc(_rw, 15, 88);
final int _dqbuf = _ioc(_rw, 17, 88);
final int _streamon = _ioc(_w, 18, 4);
final int _streamoff = _ioc(_w, 19, 4);
final int _sParm = _ioc(_rw, 22, 204);
final int _enumFramesizes = _ioc(_rw, 74, 44);
final int _enumFrameintervals = _ioc(_rw, 75, 52);

const int _bufTypeCapture = 1, _memoryMmap = 1;
const int _capVideoCapture = 0x1, _capStreaming = 0x04000000, _capDeviceCaps = 0x80000000;

int _fourcc(String s) => s.codeUnitAt(0) | s.codeUnitAt(1) << 8 | s.codeUnitAt(2) << 16 | s.codeUnitAt(3) << 24;
final int _fmtYuyv = _fourcc('YUYV'), _fmtUyvy = _fourcc('UYVY'), _fmtI420 = _fourcc('YU12');
final int _fmtNv12 = _fourcc('NV12'), _fmtMjpeg = _fourcc('MJPG'), _fmtJpeg = _fourcc('JPEG');

String _fourccStr(int f) => String.fromCharCodes([f & 255, f >> 8 & 255, f >> 16 & 255, f >> 24 & 255]);

/// Retries an ioctl on EINTR. Returns 0 or -errno.
int _xioctl(int fd, int req, Pointer<Uint8> arg) {
  while (true) {
    final r = _ioctl(fd, req, arg);
    if (r >= 0) return r;
    final e = _errno;
    if (e != _eintr) return -e;
  }
}

String _cstr(Pointer<Uint8> p, int max) {
  final b = p.asTypedList(max);
  var n = b.indexOf(0);
  if (n < 0) n = max;
  return String.fromCharCodes(b.sublist(0, n)).trim();
}

int _openDev(String path) {
  final p = path.toNativeUtf8();
  final fd = _open(p, _oRdwr | _oNonblock | _oCloexec);
  malloc.free(p);
  return fd < 0 ? -_errno : fd;
}

// ---------------------------------------------------------------- enumeration

/// Lists V4L2 capture devices (runs in a helper isolate: open() of a busy device may stall).
Future<List<CaptureDevice>> listV4l2Cameras() => Isolate.run(_listSync);

List<CaptureDevice> _listSync() {
  final out = <CaptureDevice>[];
  final dir = Directory('/dev');
  final nodes = <String>[];
  try {
    for (final e in dir.listSync()) {
      final n = e.path.split('/').last;
      if (RegExp(r'^video\d+$').hasMatch(n)) nodes.add(e.path);
    }
  } catch (_) {
    return out;
  }
  nodes.sort((a, b) => int.parse(a.substring(10)).compareTo(int.parse(b.substring(10))));
  final cap = calloc<Uint8>(104);
  final fd0 = calloc<Uint8>(64);
  try {
    for (final path in nodes) {
      final fd = _openDev(path);
      if (fd < 0) {
        if (-fd == _eacces) out.add(CaptureDevice(path, '$path (no permission, add your user to the video group)'));
        continue;
      }
      try {
        if (_xioctl(fd, _querycap, cap) < 0) continue;
        final bd = ByteData.sublistView(cap.asTypedList(104));
        var caps = bd.getUint32(84, Endian.little);
        if (caps & _capDeviceCaps != 0) caps = bd.getUint32(88, Endian.little);
        if (caps & _capVideoCapture == 0 || caps & _capStreaming == 0) continue;
        // skip nodes that offer no format at all (metadata nodes of UVC cameras)
        final f = fd0.asTypedList(64)..fillRange(0, 64, 0);
        ByteData.sublistView(f).setUint32(4, _bufTypeCapture, Endian.little);
        if (_xioctl(fd, _enumFmt, fd0) < 0) continue;
        final card = _cstr(cap + 16, 32);
        out.add(CaptureDevice(path, '${card.isEmpty ? 'Camera' : card} ($path)'));
      } finally {
        _close(fd);
      }
    }
  } finally {
    calloc.free(cap);
    calloc.free(fd0);
  }
  return out;
}

// ---------------------------------------------------------------- source

/// [forceFourcc] (for example 'MJPG') restricts the choice to one format; for tests.
MediaSource v4l2CameraSource(CaptureDevice d, {int maxWidth = 1280, int fps = 25, String? forceFourcc}) =>
    IsolateCaptureSource(d.name, v4l2CaptureMain, {
      'path': d.id,
      'maxWidth': maxWidth,
      'fps': fps,
      'force': forceFourcc,
    });

class _Mode {
  _Mode(this.fmt, this.w, this.h, this.fps);
  final int fmt, w, h;
  final double fps;
}

/// Isolate entry point of the V4L2 camera loop.
void v4l2CaptureMain(CaptureIsolateArgs args) {
  final ctx = CaptureIsolateContext(args);
  final path = ctx.cfg['path'] as String;
  final maxWidth = ctx.cfg['maxWidth'] as int;
  final fps = ctx.cfg['fps'] as int;
  final fd = _openDev(path);
  if (fd < 0) {
    final e = -fd;
    ctx.fail(
      e == _eacces
          ? 'Cannot open $path: permission denied (add your user to the video group)'
          : e == _ebusy
          ? '$path is busy (used by another program)'
          : 'Cannot open $path (errno $e)',
    );
    return;
  }
  final arg = calloc<Uint8>(256);
  final bufs = <Pointer<Uint8>>[];
  final lens = <int>[];
  var streaming = false;
  ByteData bd() => ByteData.sublistView(arg.asTypedList(256));
  void clear() => arg.asTypedList(256).fillRange(0, 256, 0);
  try {
    final force = ctx.cfg['force'] as String?;
    final mode = _chooseMode(fd, arg, maxWidth, fps, force == null ? null : _fourcc(force));
    if (mode == null) {
      ctx.fail('$path offers no usable picture format (need YUYV, UYVY, I420, NV12 or MJPEG)');
      return;
    }
    // S_FMT
    clear();
    var b = bd();
    b.setUint32(0, _bufTypeCapture, Endian.little);
    b.setUint32(8, mode.w, Endian.little);
    b.setUint32(12, mode.h, Endian.little);
    b.setUint32(16, mode.fmt, Endian.little);
    b.setUint32(20, 1, Endian.little); // V4L2_FIELD_NONE
    var r = _xioctl(fd, _sFmt, arg);
    if (r < 0) {
      ctx.fail(-r == _ebusy ? '$path is busy (used by another program)' : 'VIDIOC_S_FMT failed (errno ${-r})');
      return;
    }
    b = bd();
    final w = b.getUint32(8, Endian.little), h = b.getUint32(12, Endian.little);
    final pixfmt = b.getUint32(16, Endian.little);
    var bpl = b.getUint32(24, Endian.little);
    final isJpeg = pixfmt == _fmtMjpeg || pixfmt == _fmtJpeg;
    if (bpl == 0) bpl = pixfmt == _fmtYuyv || pixfmt == _fmtUyvy ? w * 2 : w;
    // frame rate (best effort)
    clear();
    b = bd();
    b.setUint32(0, _bufTypeCapture, Endian.little);
    b.setUint32(12, 1, Endian.little); // timeperframe numerator
    b.setUint32(16, fps, Endian.little); // denominator
    _xioctl(fd, _sParm, arg);
    // buffers
    clear();
    b = bd();
    b.setUint32(0, 4, Endian.little);
    b.setUint32(4, _bufTypeCapture, Endian.little);
    b.setUint32(8, _memoryMmap, Endian.little);
    r = _xioctl(fd, _reqbufs, arg);
    final count = bd().getUint32(0, Endian.little);
    if (r < 0 || count < 2) {
      ctx.fail('VIDIOC_REQBUFS failed (errno ${-r})');
      return;
    }
    for (var i = 0; i < count; i++) {
      clear();
      b = bd();
      b.setUint32(0, i, Endian.little);
      b.setUint32(4, _bufTypeCapture, Endian.little);
      b.setUint32(60, _memoryMmap, Endian.little);
      if (_xioctl(fd, _querybuf, arg) < 0) {
        ctx.fail('VIDIOC_QUERYBUF failed');
        return;
      }
      b = bd();
      final off = b.getUint32(64, Endian.little), len = b.getUint32(72, Endian.little);
      final p = _mmap(nullptr, len, 3, 1, fd, off);
      if (p.address == -1 || p.address == 0xFFFFFFFFFFFFFFFF) {
        ctx.fail('mmap failed (errno $_errno)');
        return;
      }
      bufs.add(p);
      lens.add(len);
      if (_xioctl(fd, _qbuf, arg) < 0) {
        ctx.fail('VIDIOC_QBUF failed');
        return;
      }
    }
    final type = calloc<Uint8>(4);
    type.cast<Uint32>().value = _bufTypeCapture;
    r = _xioctl(fd, _streamon, type);
    calloc.free(type);
    if (r < 0) {
      ctx.fail('VIDIOC_STREAMON failed (errno ${-r})');
      return;
    }
    streaming = true;
    ctx.ready('${_fourccStr(pixfmt)} ${w}x$h @ ${mode.fps.toStringAsFixed(1)} fps');

    final pfd = calloc<Int32>(2);
    final jpeg = isJpeg ? JpegDecoder() : null;
    final minGapUs = 1000000 ~/ fps - 3000;
    var lastUs = -1 << 40;
    var failures = 0;
    try {
      while (!ctx.stopRequested) {
        pfd[0] = fd;
        pfd[1] = 1; // POLLIN
        final pr = _poll(pfd, 1, 200);
        if (pr < 0) {
          if (_errno == _eintr) continue;
          ctx.ended('poll failed (errno $_errno)');
          return;
        }
        if (pr == 0) {
          if (++failures > 25) {
            ctx.ended('$path delivers no frames');
            return;
          }
          continue;
        }
        if ((pfd[1] >> 16) & 0x18 != 0) {
          ctx.ended('$path disconnected');
          return;
        }
        clear();
        b = bd();
        b.setUint32(4, _bufTypeCapture, Endian.little);
        b.setUint32(60, _memoryMmap, Endian.little);
        r = _xioctl(fd, _dqbuf, arg);
        if (r < 0) {
          if (-r == _eagain) continue;
          ctx.ended('$path: VIDIOC_DQBUF failed (errno ${-r}), camera unplugged?');
          return;
        }
        failures = 0;
        final t = ctx.nowUs();
        b = bd();
        final idx = b.getUint32(0, Endian.little);
        final used = b.getUint32(8, Endian.little);
        final flags = b.getUint32(12, Endian.little);
        final ok = flags & 0x40 == 0 && used > 0; // V4L2_BUF_FLAG_ERROR
        if (ok && t - lastUs >= minGapUs && !ctx.congested) {
          lastUs = t;
          final view = bufs[idx].asTypedList(used < lens[idx] ? used : lens[idx]);
          if (jpeg != null) {
            final pic = jpeg.decodeI420(view);
            if (pic != null) ctx.video(RawFormat.i420, pic.data, pic.width, pic.height, pic.width, t);
          } else if (pixfmt == _fmtYuyv || pixfmt == _fmtUyvy) {
            if (used >= bpl * h) {
              ctx.video(pixfmt == _fmtYuyv ? RawFormat.yuyv : RawFormat.uyvy, view, w, h, bpl, t);
            }
          } else if (pixfmt == _fmtNv12) {
            if (used >= bpl * h * 3 ~/ 2) ctx.video(RawFormat.i420, nv12ToI420(view, w, h, bpl), w, h, w, t);
          } else if (pixfmt == _fmtI420) {
            if (used >= w * h * 3 ~/ 2) ctx.video(RawFormat.i420, view, w, h, w, t);
          }
        }
        // hand the buffer back (arg still holds index/type/memory)
        if (_xioctl(fd, _qbuf, arg) < 0) {
          ctx.ended('$path: VIDIOC_QBUF failed');
          return;
        }
      }
    } finally {
      calloc.free(pfd);
    }
  } catch (e) {
    ctx.fail('$path: $e');
  } finally {
    if (streaming) {
      final type = calloc<Uint8>(4);
      type.cast<Uint32>().value = _bufTypeCapture;
      _xioctl(fd, _streamoff, type);
      calloc.free(type);
    }
    for (var i = 0; i < bufs.length; i++) {
      _munmap(bufs[i], lens[i]);
    }
    _close(fd);
    calloc.free(arg);
  }
}

/// Enumerates formats, sizes and intervals; picks the best mode for [maxWidth] and [fps].
_Mode? _chooseMode(int fd, Pointer<Uint8> arg, int maxWidth, int fps, int? only) {
  ByteData bd() => ByteData.sublistView(arg.asTypedList(256));
  void clear() => arg.asTypedList(256).fillRange(0, 256, 0);
  final formats = <int>[];
  for (var i = 0; i < 64; i++) {
    clear();
    final b = bd();
    b.setUint32(0, i, Endian.little);
    b.setUint32(4, _bufTypeCapture, Endian.little);
    if (_xioctl(fd, _enumFmt, arg) < 0) break;
    formats.add(bd().getUint32(44, Endian.little));
  }
  final pref = only != null ? [only] : [_fmtYuyv, _fmtUyvy, _fmtI420, _fmtNv12, _fmtMjpeg, _fmtJpeg];
  _Mode? bestRaw, bestJpeg;
  double score(_Mode m) {
    final f = m.fps < fps ? m.fps : fps.toDouble();
    // frame rate dominates, then size, then format preference
    return f * 1e7 + m.w * m.h - pref.indexOf(m.fmt) * 1000;
  }

  for (final fmt in pref) {
    if (!formats.contains(fmt)) continue;
    final jpeg = fmt == _fmtMjpeg || fmt == _fmtJpeg;
    final sizes = <(int, int)>[];
    for (var i = 0; i < 128; i++) {
      clear();
      final b = bd();
      b.setUint32(0, i, Endian.little);
      b.setUint32(4, fmt, Endian.little);
      if (_xioctl(fd, _enumFramesizes, arg) < 0) break;
      final r = bd();
      final type = r.getUint32(8, Endian.little);
      if (type == 1) {
        sizes.add((r.getUint32(12, Endian.little), r.getUint32(16, Endian.little)));
      } else {
        // stepwise/continuous: take the largest allowed width not above maxWidth, 4:3 or 16:9
        final maxW = r.getUint32(16, Endian.little), maxH = r.getUint32(28, Endian.little);
        final (fw, fh) = fitWidth(maxW, maxH, maxWidth);
        sizes.add((fw, fh));
        break;
      }
    }
    if (sizes.isEmpty) sizes.add((640, 480));
    for (final (w, h) in sizes) {
      if (w > maxWidth) continue;
      var bestFps = 0.0;
      for (var i = 0; i < 64; i++) {
        clear();
        final b = bd();
        b.setUint32(0, i, Endian.little);
        b.setUint32(4, fmt, Endian.little);
        b.setUint32(8, w, Endian.little);
        b.setUint32(12, h, Endian.little);
        if (_xioctl(fd, _enumFrameintervals, arg) < 0) break;
        final r = bd();
        final type = r.getUint32(16, Endian.little);
        final n = r.getUint32(20, Endian.little), d = r.getUint32(24, Endian.little);
        // discrete: n/d is the interval; stepwise: the first fraction is the minimum interval
        if (n > 0 && d / n > bestFps) bestFps = d / n;
        if (type != 1) break;
      }
      if (bestFps == 0) bestFps = fps.toDouble();
      final m = _Mode(fmt, w, h, bestFps);
      if (jpeg) {
        if (bestJpeg == null || score(m) > score(bestJpeg)) bestJpeg = m;
      } else if (bestRaw == null || score(m) > score(bestRaw)) {
        bestRaw = m;
      }
    }
  }
  // raw formats need no decoding; MJPEG only when raw cannot reach half the frame rate
  final best = bestRaw == null || (bestJpeg != null && bestRaw.fps < fps / 2 && bestJpeg.fps > bestRaw.fps)
      ? bestJpeg
      : bestRaw;
  if (best == null) {
    // nothing at or below maxWidth: take the first known format and let the driver adjust
    for (final fmt in pref) {
      if (formats.contains(fmt)) return _Mode(fmt, maxWidth < 640 ? maxWidth : 640, 480, fps.toDouble());
    }
  }
  return best;
}
