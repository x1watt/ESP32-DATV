/// Linux screen capture on X11 (dart:ffi on libX11, libXext MIT-SHM and libXrandr).
///
/// Wayland sessions are refused up front (their capture goes through the xdg-desktop-portal
/// and PipeWire, not supported in this version). Pictures are BGRA (32-bit TrueColor root).
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'isolate_capture.dart';
import 'media_source.dart';
import 'pixel_pack.dart';

/// Null when X11 screen capture can work in this session, else the reason it cannot.
String? x11Unsupported() {
  final env = Platform.environment;
  final type = (env['XDG_SESSION_TYPE'] ?? '').toLowerCase();
  if (type == 'wayland' || (env['WAYLAND_DISPLAY'] ?? '').isNotEmpty && (env['DISPLAY'] ?? '').isEmpty) {
    return 'Screen capture needs an X11 session in this version (this is a Wayland session). '
        'Choose "GNOME on Xorg" (or similar) on the login screen.';
  }
  if ((env['DISPLAY'] ?? '').isEmpty) return 'No X11 display (DISPLAY is not set)';
  return null;
}

// ---------------------------------------------------------------- bindings

class _X {
  _X() : x11 = DynamicLibrary.open('libX11.so.6');

  final DynamicLibrary x11;
  late final DynamicLibrary? xext = _tryOpen('libXext.so.6');
  late final DynamicLibrary? xrandr = _tryOpen('libXrandr.so.2');
  final DynamicLibrary libc = DynamicLibrary.open('libc.so.6');

  static DynamicLibrary? _tryOpen(String n) {
    try {
      return DynamicLibrary.open(n);
    } catch (_) {
      return null;
    }
  }

  late final Pointer<Void> Function(Pointer<Utf8>) openDisplay = x11
      .lookupFunction<Pointer<Void> Function(Pointer<Utf8>), Pointer<Void> Function(Pointer<Utf8>)>('XOpenDisplay');
  late final int Function(Pointer<Void>) closeDisplay = x11
      .lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('XCloseDisplay');
  late final int Function(Pointer<Void>) defaultRoot = x11
      .lookupFunction<UnsignedLong Function(Pointer<Void>), int Function(Pointer<Void>)>('XDefaultRootWindow');
  late final int Function(Pointer<Void>, int, Pointer<Uint8>) getWindowAttributes = x11
      .lookupFunction<
        Int32 Function(Pointer<Void>, UnsignedLong, Pointer<Uint8>),
        int Function(Pointer<Void>, int, Pointer<Uint8>)
      >('XGetWindowAttributes');
  late final Pointer<Uint8> Function(Pointer<Void>, int, int, int, int, int, int, int) getImage = x11
      .lookupFunction<
        Pointer<Uint8> Function(Pointer<Void>, UnsignedLong, Int32, Int32, Uint32, Uint32, UnsignedLong, Int32),
        Pointer<Uint8> Function(Pointer<Void>, int, int, int, int, int, int, int)
      >('XGetImage');
  late final int Function(Pointer<Void>, int) sync = x11
      .lookupFunction<Int32 Function(Pointer<Void>, Int32), int Function(Pointer<Void>, int)>('XSync');
  late final int Function(Pointer<Void>) xFree = x11
      .lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('XFree');
  late final Pointer<Utf8> Function(Pointer<Void>, int) getAtomName = x11
      .lookupFunction<Pointer<Utf8> Function(Pointer<Void>, UnsignedLong), Pointer<Utf8> Function(Pointer<Void>, int)>(
        'XGetAtomName',
      );

  // MIT-SHM
  late final int Function(Pointer<Void>) shmQuery = xext!
      .lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('XShmQueryExtension');
  late final Pointer<Uint8> Function(Pointer<Void>, Pointer<Void>, int, int, Pointer<Uint8>, Pointer<Uint8>, int, int)
  shmCreateImage = xext!
      .lookupFunction<
        Pointer<Uint8> Function(
          Pointer<Void>,
          Pointer<Void>,
          Uint32,
          Int32,
          Pointer<Uint8>,
          Pointer<Uint8>,
          Uint32,
          Uint32,
        ),
        Pointer<Uint8> Function(Pointer<Void>, Pointer<Void>, int, int, Pointer<Uint8>, Pointer<Uint8>, int, int)
      >('XShmCreateImage');
  late final int Function(Pointer<Void>, Pointer<Uint8>) shmAttach = xext!
      .lookupFunction<Int32 Function(Pointer<Void>, Pointer<Uint8>), int Function(Pointer<Void>, Pointer<Uint8>)>(
        'XShmAttach',
      );
  late final int Function(Pointer<Void>, Pointer<Uint8>) shmDetach = xext!
      .lookupFunction<Int32 Function(Pointer<Void>, Pointer<Uint8>), int Function(Pointer<Void>, Pointer<Uint8>)>(
        'XShmDetach',
      );
  late final int Function(Pointer<Void>, int, Pointer<Uint8>, int, int, int) shmGetImage = xext!
      .lookupFunction<
        Int32 Function(Pointer<Void>, UnsignedLong, Pointer<Uint8>, Int32, Int32, UnsignedLong),
        int Function(Pointer<Void>, int, Pointer<Uint8>, int, int, int)
      >('XShmGetImage');

  // XRandR
  late final Pointer<Uint8> Function(Pointer<Void>, int, int, Pointer<Int32>) getMonitors = xrandr!
      .lookupFunction<
        Pointer<Uint8> Function(Pointer<Void>, UnsignedLong, Int32, Pointer<Int32>),
        Pointer<Uint8> Function(Pointer<Void>, int, int, Pointer<Int32>)
      >('XRRGetMonitors');
  late final void Function(Pointer<Uint8>) freeMonitors = xrandr!
      .lookupFunction<Void Function(Pointer<Uint8>), void Function(Pointer<Uint8>)>('XRRFreeMonitors');

  // SysV shared memory
  late final int Function(int, int, int) shmget = libc
      .lookupFunction<Int32 Function(Int32, Size, Int32), int Function(int, int, int)>('shmget');
  late final Pointer<Uint8> Function(int, Pointer<Void>, int) shmat = libc
      .lookupFunction<
        Pointer<Uint8> Function(Int32, Pointer<Void>, Int32),
        Pointer<Uint8> Function(int, Pointer<Void>, int)
      >('shmat');
  late final int Function(Pointer<Uint8>) shmdt = libc
      .lookupFunction<Int32 Function(Pointer<Uint8>), int Function(Pointer<Uint8>)>('shmdt');
  late final int Function(int, int, Pointer<Void>) shmctl = libc
      .lookupFunction<Int32 Function(Int32, Int32, Pointer<Void>), int Function(int, int, Pointer<Void>)>('shmctl');
}

// XImage field offsets (64-bit)
const int _imgData = 16, _imgDepth = 40, _imgBpl = 44, _imgBpp = 48, _imgDestroy = 96;
const int _zPixmap = 2;
const int _allPlanes = -1; // ~0UL

void _destroyImage(Pointer<Uint8> img) {
  final fn = Pointer<NativeFunction<Int32 Function(Pointer<Uint8>)>>.fromAddress(
    (img + _imgDestroy).cast<IntPtr>().value,
  );
  fn.asFunction<int Function(Pointer<Uint8>)>()(img);
}

// ---------------------------------------------------------------- enumeration

/// Lists the whole desktop plus one entry per XRandR monitor. Ids are "x,y,w,h".
Future<List<CaptureDevice>> listX11Screens() async {
  final why = x11Unsupported();
  if (why != null) return const [];
  return Isolate.run(_listSync);
}

List<CaptureDevice> _listSync() {
  final x = _X();
  final dpy = x.openDisplay(nullptr);
  if (dpy == nullptr) return const [];
  final out = <CaptureDevice>[];
  final attr = calloc<Uint8>(136);
  final n = calloc<Int32>();
  try {
    final root = x.defaultRoot(dpy);
    x.getWindowAttributes(dpy, root, attr);
    final bd = ByteData.sublistView(attr.asTypedList(136));
    final w = bd.getInt32(8, Endian.host), h = bd.getInt32(12, Endian.host);
    final mons = <CaptureDevice>[];
    if (x.xrandr != null) {
      final m = x.getMonitors(dpy, root, 1, n);
      if (m != nullptr) {
        for (var i = 0; i < n.value; i++) {
          final mb = ByteData.sublistView((m + i * 56).asTypedList(56));
          final atom = mb.getUint64(0, Endian.host);
          final primary = mb.getInt32(8, Endian.host) != 0;
          final mx = mb.getInt32(20, Endian.host), my = mb.getInt32(24, Endian.host);
          final mw = mb.getInt32(28, Endian.host), mh = mb.getInt32(32, Endian.host);
          var name = 'Monitor ${i + 1}';
          if (atom != 0) {
            final s = x.getAtomName(dpy, atom);
            if (s != nullptr) {
              name = s.toDartString();
              x.xFree(s.cast());
            }
          }
          mons.add(CaptureDevice('$mx,$my,$mw,$mh', '$name ${mw}x$mh${primary ? ' (primary)' : ''}'));
        }
        x.freeMonitors(m);
      }
    }
    if (mons.length != 1) out.add(CaptureDevice('0,0,$w,$h', 'Whole desktop ${w}x$h'));
    out.addAll(mons);
  } finally {
    calloc.free(attr);
    calloc.free(n);
    x.closeDisplay(dpy);
  }
  return out;
}

// ---------------------------------------------------------------- source

MediaSource x11ScreenSource(CaptureDevice d, {int fps = 15, int maxWidth = 1920}) =>
    IsolateCaptureSource(d.name, x11CaptureMain, {'rect': d.id, 'fps': fps, 'maxWidth': maxWidth});

/// Isolate entry point of the X11 screen grabber.
void x11CaptureMain(CaptureIsolateArgs args) {
  final ctx = CaptureIsolateContext(args);
  final why = x11Unsupported();
  if (why != null) {
    ctx.fail(why);
    return;
  }
  final fps = (ctx.cfg['fps'] as int).clamp(1, 60);
  final maxWidth = ctx.cfg['maxWidth'] as int;
  final x = _X();
  final dpy = x.openDisplay(nullptr);
  if (dpy == nullptr) {
    ctx.fail('Cannot open the X11 display ${Platform.environment['DISPLAY']}');
    return;
  }
  final attr = calloc<Uint8>(136);
  final shminfo = calloc<Uint8>(32);
  Pointer<Uint8> img = nullptr;
  var shmAddr = nullptr.cast<Uint8>();
  var attached = false;
  try {
    final root = x.defaultRoot(dpy);
    x.getWindowAttributes(dpy, root, attr);
    final ab = ByteData.sublistView(attr.asTypedList(136));
    final rw = ab.getInt32(8, Endian.host), rh = ab.getInt32(12, Endian.host);
    final depth = ab.getInt32(20, Endian.host);
    final visual = Pointer<Void>.fromAddress(ab.getInt64(24, Endian.host));
    // requested rectangle, clipped to the root window, even size
    final r = (ctx.cfg['rect'] as String).split(',').map(int.parse).toList();
    final x0 = r[0].clamp(0, rw - 2), y0 = r[1].clamp(0, rh - 2);
    final w = (r[2].clamp(2, rw - x0)) & ~1, h = (r[3].clamp(2, rh - y0)) & ~1;
    if (depth < 24) {
      ctx.fail('X11 root window depth $depth is not supported (need 24 or 32 bit TrueColor)');
      return;
    }
    // MIT-SHM only on a local display (it would raise an X error, fatal under GTK, otherwise)
    final local = (Platform.environment['DISPLAY'] ?? '').startsWith(':');
    if (local && x.xext != null && x.shmQuery(dpy) != 0) {
      img = x.shmCreateImage(dpy, visual, depth, _zPixmap, nullptr, shminfo, w, h);
      if (img != nullptr) {
        final ib = ByteData.sublistView(img.asTypedList(136));
        final size = ib.getInt32(_imgBpl, Endian.host) * h;
        final id = x.shmget(0, size, 512 | 384); // IPC_PRIVATE, IPC_CREAT | 0600
        if (id >= 0) {
          shmAddr = x.shmat(id, nullptr, 0);
          if (shmAddr.address != -1 && shmAddr.address != 0xFFFFFFFFFFFFFFFF) {
            final sb = ByteData.sublistView(shminfo.asTypedList(32));
            sb.setInt32(8, id, Endian.host);
            sb.setInt64(16, shmAddr.address, Endian.host);
            sb.setInt32(24, 0, Endian.host);
            (img + _imgData).cast<IntPtr>().value = shmAddr.address;
            attached = x.shmAttach(dpy, shminfo) != 0;
            x.sync(dpy, 0);
          } else {
            shmAddr = nullptr;
          }
          x.shmctl(id, 0, nullptr); // IPC_RMID: freed once both sides detach
        }
        if (!attached) {
          (img + _imgData).cast<IntPtr>().value = 0;
          _destroyImage(img);
          img = nullptr;
          if (shmAddr != nullptr) x.shmdt(shmAddr);
          shmAddr = nullptr;
        }
      }
    }
    ctx.ready('${w}x$h at $x0,$y0 ${attached ? 'MIT-SHM' : 'XGetImage'}');

    final periodUs = 1000000 ~/ fps;
    var next = ctx.nowUs();
    while (!ctx.stopRequested) {
      final t = ctx.nowUs();
      if (t < next) {
        final ms = ((next - t) ~/ 1000).clamp(1, 50);
        sleep(Duration(milliseconds: ms));
        continue;
      }
      next += periodUs;
      if (next < t) next = t + periodUs; // fell behind: do not burst
      if (ctx.congested) continue;
      Pointer<Uint8> frame;
      if (attached) {
        if (x.shmGetImage(dpy, root, img, x0, y0, _allPlanes) == 0) {
          ctx.ended('XShmGetImage failed');
          return;
        }
        frame = img;
      } else {
        frame = x.getImage(dpy, root, x0, y0, w, h, _allPlanes, _zPixmap);
        if (frame == nullptr) {
          ctx.ended('XGetImage failed');
          return;
        }
      }
      try {
        final fb = ByteData.sublistView(frame.asTypedList(136));
        final bpl = fb.getInt32(_imgBpl, Endian.host);
        final bpp = fb.getInt32(_imgBpp, Endian.host);
        if (bpp != 32) {
          ctx.ended('Unsupported X11 pixel size $bpp bit (depth ${fb.getInt32(_imgDepth, Endian.host)})');
          return;
        }
        final data = Pointer<Uint8>.fromAddress(fb.getInt64(_imgData, Endian.host)).asTypedList(bpl * h);
        if (w >= 2 * maxWidth) {
          ctx.video(RawFormat.bgra, halve32(data, w, h, bpl), w >> 1, h >> 1, (w >> 1) * 4, t);
        } else {
          ctx.video(RawFormat.bgra, data, w, h, bpl, t);
        }
      } finally {
        if (!attached) _destroyImage(frame);
      }
    }
  } catch (e) {
    ctx.fail('Screen capture: $e');
  } finally {
    if (attached) {
      x.shmDetach(dpy, shminfo);
      x.sync(dpy, 0);
    }
    if (img != nullptr) {
      (img + _imgData).cast<IntPtr>().value = 0;
      _destroyImage(img);
    }
    if (shmAddr != nullptr) x.shmdt(shmAddr);
    x.closeDisplay(dpy);
    calloc.free(attr);
    calloc.free(shminfo);
  }
}
