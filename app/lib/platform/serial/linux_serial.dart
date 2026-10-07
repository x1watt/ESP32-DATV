/// Serial transport for Linux: a tty (/dev/ttyACM*) through termios, with dart:ffi only.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../core/esp/transport.dart';

final DynamicLibrary _libc = DynamicLibrary.open('libc.so.6');

final int Function(Pointer<Utf8>, int) _open =
    _libc.lookupFunction<Int32 Function(Pointer<Utf8>, Int32), int Function(Pointer<Utf8>, int)>('open');
final int Function(int) _close = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('close');
final int Function(int, Pointer<Uint8>, int) _read =
    _libc.lookupFunction<IntPtr Function(Int32, Pointer<Uint8>, IntPtr), int Function(int, Pointer<Uint8>, int)>('read');
final int Function(int, Pointer<Uint8>, int) _write =
    _libc.lookupFunction<IntPtr Function(Int32, Pointer<Uint8>, IntPtr), int Function(int, Pointer<Uint8>, int)>('write');
final int Function(int, Pointer<Uint8>) _tcgetattr =
    _libc.lookupFunction<Int32 Function(Int32, Pointer<Uint8>), int Function(int, Pointer<Uint8>)>('tcgetattr');
final int Function(int, int, Pointer<Uint8>) _tcsetattr = _libc
    .lookupFunction<Int32 Function(Int32, Int32, Pointer<Uint8>), int Function(int, int, Pointer<Uint8>)>('tcsetattr');
final void Function(Pointer<Uint8>) _cfmakeraw =
    _libc.lookupFunction<Void Function(Pointer<Uint8>), void Function(Pointer<Uint8>)>('cfmakeraw');
final int Function(Pointer<Uint8>, int) _cfsetspeed =
    _libc.lookupFunction<Int32 Function(Pointer<Uint8>, Uint32), int Function(Pointer<Uint8>, int)>('cfsetspeed');
final int Function(int, int) _tcflush = _libc.lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>('tcflush');
final int Function(int, int, Pointer<Int32>) _ioctlInt = _libc.lookupFunction<
    Int32 Function(Int32, UnsignedLong, VarArgs<(Pointer<Int32>,)>), int Function(int, int, Pointer<Int32>)>('ioctl');
final int Function(Pointer<_PollFd>, int, int) _poll = _libc
    .lookupFunction<Int32 Function(Pointer<_PollFd>, Uint64, Int32), int Function(Pointer<_PollFd>, int, int)>('poll');
final Pointer<Int32> Function() _errnoLoc =
    _libc.lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>('__errno_location');

final class _PollFd extends Struct {
  @Int32()
  external int fd;
  @Int16()
  external int events;
  @Int16()
  external int revents;
}

const int _oRdwr = 2, _oNoctty = 0x100, _oNonblock = 0x800;
const int _tcsanow = 0, _tciflush = 0;
const int _tiocmget = 0x5415, _tiocmset = 0x5418;
const int _tiocmDtr = 0x002, _tiocmRts = 0x004;
const int _b115200 = 0x1002;
const int _pollin = 1, _pollout = 4;
const int _eagain = 11, _eintr = 4;

class LinuxSerialTransport implements ByteTransport {
  LinuxSerialTransport._(this._fd, this.path);

  static LinuxSerialTransport open(String path) {
    final p = path.toNativeUtf8();
    final fd = _open(p, _oRdwr | _oNoctty | _oNonblock);
    malloc.free(p);
    if (fd < 0) throw TransportError('Cannot open $path (errno ${_errnoLoc().value}). Is your user in the dialout group?');
    final t = calloc<Uint8>(128);
    try {
      if (_tcgetattr(fd, t) != 0) throw TransportError('$path is not a serial port');
      _cfmakeraw(t);
      _cfsetspeed(t, _b115200);
      // c_cflag (offset 8): CLOCAL | CREAD, so that no carrier is needed
      final cflag = t.cast<Uint32>() + 2;
      cflag.value |= 0x800 | 0x80;
      _tcsetattr(fd, _tcsanow, t);
    } finally {
      calloc.free(t);
    }
    return LinuxSerialTransport._(fd, path);
  }

  final String path;
  int _fd;
  final Pointer<Uint8> _rbuf = malloc<Uint8>(65536);
  Pointer<Uint8> _wbuf = malloc<Uint8>(16384);
  int _wcap = 16384;
  final Pointer<_PollFd> _pfd = calloc<_PollFd>();

  bool _waitFor(int events, int ms) {
    _pfd.ref
      ..fd = _fd
      ..events = events
      ..revents = 0;
    final r = _poll(_pfd, 1, ms);
    if (r < 0) return false;
    if (r > 0 && (_pfd.ref.revents & 0x18) != 0) {
      // POLLHUP / POLLERR: the device went away
      throw TransportError('Device disconnected');
    }
    return r > 0;
  }

  void _check() {
    if (_fd < 0) throw TransportError('Port closed');
  }

  @override
  Future<Uint8List> read({Duration timeout = Duration.zero}) async {
    _check();
    var n = _read(_fd, _rbuf, 65536);
    if (n < 0 && timeout > Duration.zero) {
      final e = _errnoLoc().value;
      if (e != _eagain && e != _eintr) throw TransportError('Read error (errno $e)');
      if (_waitFor(_pollin, timeout.inMilliseconds.clamp(1, 1 << 30))) n = _read(_fd, _rbuf, 65536);
    }
    if (n <= 0) {
      if (n < 0) {
        final e = _errnoLoc().value;
        if (e != _eagain && e != _eintr) throw TransportError('Read error (errno $e)');
      }
      return Uint8List(0);
    }
    return Uint8List.fromList(_rbuf.asTypedList(n));
  }

  @override
  Future<void> write(Uint8List data, {Duration timeout = const Duration(seconds: 2)}) async {
    _check();
    if (data.length > _wcap) {
      malloc.free(_wbuf);
      _wcap = data.length;
      _wbuf = malloc<Uint8>(_wcap);
    }
    _wbuf.asTypedList(data.length).setAll(0, data);
    var off = 0;
    final sw = Stopwatch()..start();
    while (off < data.length) {
      final n = _write(_fd, _wbuf + off, data.length - off);
      if (n > 0) {
        off += n;
        continue;
      }
      final e = _errnoLoc().value;
      if (n < 0 && e != _eagain && e != _eintr) throw TransportError('Write error (errno $e)');
      final left = timeout.inMilliseconds - sw.elapsedMilliseconds;
      if (left <= 0) throw TransportError('Write timeout');
      _waitFor(_pollout, left.clamp(1, 50));
    }
  }

  @override
  Future<void> setSignals({bool? dtr, bool? rts}) async {
    _check();
    final p = calloc<Int32>();
    try {
      _ioctlInt(_fd, _tiocmget, p);
      var v = p.value;
      if (dtr != null) v = dtr ? v | _tiocmDtr : v & ~_tiocmDtr;
      if (rts != null) v = rts ? v | _tiocmRts : v & ~_tiocmRts;
      p.value = v;
      _ioctlInt(_fd, _tiocmset, p);
    } finally {
      calloc.free(p);
    }
  }

  @override
  Future<void> flushInput() async {
    _check();
    _tcflush(_fd, _tciflush);
    while (_read(_fd, _rbuf, 65536) > 0) {}
  }

  @override
  Future<void> close() async {
    if (_fd >= 0) {
      _close(_fd);
      _fd = -1;
      malloc.free(_rbuf);
      malloc.free(_wbuf);
      calloc.free(_pfd);
    }
  }
}

String? _readSys(String path) {
  try {
    return File(path).readAsStringSync().trim();
  } on FileSystemException {
    return null;
  }
}

/// USB serial ports (ttyACM / ttyUSB) with their USB identifiers.
List<PortInfo> listLinuxPorts() {
  final out = <PortInfo>[];
  final dir = Directory('/sys/class/tty');
  if (!dir.existsSync()) return out;
  final byId = <String, String>{};
  final idDir = Directory('/dev/serial/by-id');
  if (idDir.existsSync()) {
    for (final l in idDir.listSync()) {
      try {
        byId[File(l.path).resolveSymbolicLinksSync()] = l.path;
      } on FileSystemException {
        // dangling link
      }
    }
  }
  for (final e in dir.listSync()) {
    final name = e.path.split('/').last;
    if (!name.startsWith('ttyACM') && !name.startsWith('ttyUSB')) continue;
    // device -> interface dir; its parent is the USB device with idVendor etc.
    String? usbDir;
    try {
      var d = Directory('${e.path}/device').resolveSymbolicLinksSync();
      for (var i = 0; i < 4 && usbDir == null; i++) {
        if (File('$d/idVendor').existsSync()) usbDir = d;
        d = Directory(d).parent.path;
      }
    } on FileSystemException {
      continue;
    }
    final dev = '/dev/$name';
    final vid = usbDir == null ? null : int.tryParse(_readSys('$usbDir/idVendor') ?? '', radix: 16);
    final pid = usbDir == null ? null : int.tryParse(_readSys('$usbDir/idProduct') ?? '', radix: 16);
    out.add(PortInfo(
      id: byId[dev] ?? dev,
      name: dev,
      vid: vid,
      pid: pid,
      serial: usbDir == null ? null : _readSys('$usbDir/serial'),
      product: usbDir == null ? null : _readSys('$usbDir/product'),
      manufacturer: usbDir == null ? null : _readSys('$usbDir/manufacturer'),
    ));
  }
  out.sort((a, b) => a.name.compareTo(b.name));
  return out;
}
