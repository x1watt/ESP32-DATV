/// Windows screen capture with GDI (BitBlt into a top-down 32-bit DIB section), dart:ffi
/// only. The grab loop is synchronous (no await), so the isolate stays on one OS thread,
/// which GetDC/ReleaseDC require.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'isolate_capture.dart';
import 'media_source.dart';
import 'pixel_pack.dart';

typedef _MonitorEnumN = Int32 Function(IntPtr, IntPtr, Pointer<Int32>, IntPtr);

class _Gdi {
  final DynamicLibrary user32 = DynamicLibrary.open('user32.dll');
  final DynamicLibrary gdi32 = DynamicLibrary.open('gdi32.dll');

  late final int Function(int) getDC = user32.lookupFunction<IntPtr Function(IntPtr), int Function(int)>('GetDC');
  late final int Function(int, int) releaseDC = user32
      .lookupFunction<Int32 Function(IntPtr, IntPtr), int Function(int, int)>('ReleaseDC');
  late final int Function(int) getSystemMetrics = user32.lookupFunction<Int32 Function(Int32), int Function(int)>(
    'GetSystemMetrics',
  );
  late final int Function(int, Pointer<Void>, Pointer<NativeFunction<_MonitorEnumN>>, int) enumDisplayMonitors = user32
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<Void>, Pointer<NativeFunction<_MonitorEnumN>>, IntPtr),
        int Function(int, Pointer<Void>, Pointer<NativeFunction<_MonitorEnumN>>, int)
      >('EnumDisplayMonitors');
  late final int Function(int, Pointer<Uint8>) getMonitorInfo = user32
      .lookupFunction<Int32 Function(IntPtr, Pointer<Uint8>), int Function(int, Pointer<Uint8>)>('GetMonitorInfoW');

  late final int Function(int) createCompatibleDC = gdi32.lookupFunction<IntPtr Function(IntPtr), int Function(int)>(
    'CreateCompatibleDC',
  );
  late final int Function(int, Pointer<Uint8>, int, Pointer<Pointer<Uint8>>, int, int) createDIBSection = gdi32
      .lookupFunction<
        IntPtr Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Pointer<Uint8>>, IntPtr, Uint32),
        int Function(int, Pointer<Uint8>, int, Pointer<Pointer<Uint8>>, int, int)
      >('CreateDIBSection');
  late final int Function(int, int) selectObject = gdi32
      .lookupFunction<IntPtr Function(IntPtr, IntPtr), int Function(int, int)>('SelectObject');
  late final int Function(int, int, int, int, int, int, int, int, int) bitBlt = gdi32
      .lookupFunction<
        Int32 Function(IntPtr, Int32, Int32, Int32, Int32, IntPtr, Int32, Int32, Uint32),
        int Function(int, int, int, int, int, int, int, int, int)
      >('BitBlt');
  late final int Function(int) deleteObject = gdi32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
    'DeleteObject',
  );
  late final int Function(int) deleteDC = gdi32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('DeleteDC');
  late final int Function() gdiFlush = gdi32.lookupFunction<Int32 Function(), int Function()>('GdiFlush');
}

const int _smXVirtual = 76, _smYVirtual = 77, _smCxVirtual = 78, _smCyVirtual = 79;
const int _srcCopy = 0x00CC0020, _captureBlt = 0x40000000;

/// Lists the virtual desktop plus each monitor. Ids are "x,y,w,h" in desktop coordinates.
Future<List<CaptureDevice>> listGdiScreens() => Isolate.run(_listSync);

List<CaptureDevice> _listSync() {
  final g = _Gdi();
  final mons = <CaptureDevice>[];
  final info = calloc<Uint8>(104);
  // EnumDisplayMonitors calls back synchronously on this thread
  final cb = NativeCallable<_MonitorEnumN>.isolateLocal((int hmon, int hdc, Pointer<Int32> rc, int lp) {
    info.asTypedList(104).fillRange(0, 104, 0);
    info.cast<Uint32>().value = 104;
    var name = 'Monitor ${mons.length + 1}';
    var primary = false;
    if (g.getMonitorInfo(hmon, info) != 0) {
      name = (info + 40).cast<Utf16>().toDartString();
      if (name.startsWith(r'\\.\')) name = name.substring(4);
      primary = (info + 36).cast<Uint32>().value & 1 != 0;
    }
    final l = rc[0], t = rc[1], w = rc[2] - rc[0], h = rc[3] - rc[1];
    mons.add(CaptureDevice('$l,$t,$w,$h', '$name ${w}x$h${primary ? ' (primary)' : ''}'));
    return 1;
  }, exceptionalReturn: 0);
  try {
    g.enumDisplayMonitors(0, nullptr, cb.nativeFunction, 0);
  } finally {
    cb.close();
    calloc.free(info);
  }
  final x = g.getSystemMetrics(_smXVirtual), y = g.getSystemMetrics(_smYVirtual);
  final w = g.getSystemMetrics(_smCxVirtual), h = g.getSystemMetrics(_smCyVirtual);
  return [if (mons.length != 1) CaptureDevice('$x,$y,$w,$h', 'Whole desktop ${w}x$h'), ...mons];
}

MediaSource gdiScreenSource(CaptureDevice d, {int fps = 15, int maxWidth = 1920}) =>
    IsolateCaptureSource(d.name, gdiCaptureMain, {'rect': d.id, 'fps': fps, 'maxWidth': maxWidth});

/// Isolate entry point of the GDI grabber.
void gdiCaptureMain(CaptureIsolateArgs args) {
  final ctx = CaptureIsolateContext(args);
  final fps = (ctx.cfg['fps'] as int).clamp(1, 60);
  final maxWidth = ctx.cfg['maxWidth'] as int;
  final r = (ctx.cfg['rect'] as String).split(',').map(int.parse).toList();
  final x0 = r[0], y0 = r[1], w = r[2] & ~1, h = r[3] & ~1;
  if (w < 2 || h < 2) {
    ctx.fail('Invalid screen area ${ctx.cfg['rect']}');
    return;
  }
  final g = _Gdi();
  final screen = g.getDC(0);
  if (screen == 0) {
    ctx.fail('GetDC failed: no access to the desktop');
    return;
  }
  final mem = g.createCompatibleDC(screen);
  final bmi = calloc<Uint8>(44);
  final bits = calloc<Pointer<Uint8>>();
  var bmp = 0, old = 0;
  try {
    final b = ByteData.sublistView(bmi.asTypedList(44));
    b.setUint32(0, 40, Endian.little); // biSize
    b.setInt32(4, w, Endian.little);
    b.setInt32(8, -h, Endian.little); // negative: top-down rows
    b.setUint16(12, 1, Endian.little); // planes
    b.setUint16(14, 32, Endian.little); // bit count
    b.setUint32(16, 0, Endian.little); // BI_RGB
    bmp = g.createDIBSection(screen, bmi, 0, bits, 0, 0);
    if (mem == 0 || bmp == 0 || bits.value == nullptr) {
      ctx.fail('Cannot create a ${w}x$h capture bitmap');
      return;
    }
    old = g.selectObject(mem, bmp);
    final stride = w * 4;
    final pixels = bits.value.asTypedList(stride * h);
    ctx.ready('${w}x$h at $x0,$y0 GDI');
    final periodUs = 1000000 ~/ fps;
    var next = ctx.nowUs();
    while (!ctx.stopRequested) {
      final t = ctx.nowUs();
      if (t < next) {
        sleep(Duration(milliseconds: ((next - t) ~/ 1000).clamp(1, 50)));
        continue;
      }
      next += periodUs;
      if (next < t) next = t + periodUs;
      if (ctx.congested) continue;
      // fails while the secure desktop (UAC, lock screen) is shown: keep trying
      if (g.bitBlt(mem, 0, 0, w, h, screen, x0, y0, _srcCopy | _captureBlt) == 0) continue;
      g.gdiFlush();
      if (w >= 2 * maxWidth) {
        ctx.video(RawFormat.bgra, halve32(pixels, w, h, stride), w >> 1, h >> 1, (w >> 1) * 4, t);
      } else {
        ctx.video(RawFormat.bgra, pixels, w, h, stride, t);
      }
    }
  } catch (e) {
    ctx.fail('Screen capture: $e');
  } finally {
    if (old != 0) g.selectObject(mem, old);
    if (bmp != 0) g.deleteObject(bmp);
    if (mem != 0) g.deleteDC(mem);
    g.releaseDC(0, screen);
    calloc.free(bmi);
    calloc.free(bits);
  }
}
