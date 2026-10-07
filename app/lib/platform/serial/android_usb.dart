/// Serial transport for Android: CDC-ACM over usbdevfs ioctls on the file descriptor of a
/// UsbDeviceConnection (opened and claimed by the Kotlin side, see MainActivity.kt).
/// A helper isolate keeps a bulk IN transfer pending so reads never block the caller.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../core/esp/transport.dart';

final DynamicLibrary _libc = DynamicLibrary.open('libc.so');
final int Function(int, int, Pointer<Uint8>) _ioctl = _libc.lookupFunction<
    Int32 Function(Int32, Int32, VarArgs<(Pointer<Uint8>,)>), int Function(int, int, Pointer<Uint8>)>('ioctl');
final Pointer<Int32> Function() _errno =
    _libc.lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>('__errno');

int _iowr(int nr, int size) => ((3 << 30) | (size << 16) | (0x55 << 8) | nr).toSigned(32);

final int _ptr = sizeOf<IntPtr>();
final int _xferSize = _ptr == 8 ? 24 : 16;
final int _usbdevfsControl = _iowr(0, _xferSize);
final int _usbdevfsBulk = _iowr(2, _xferSize);
const int _etimedout = 110;

/// One bulk transfer; returns bytes moved, 0 on timeout, throws on errors.
int _bulk(int fd, int ep, Pointer<Uint8> data, int len, int timeoutMs, Pointer<Uint8> x) {
  final bd = x.asTypedList(_xferSize);
  bd.fillRange(0, _xferSize, 0);
  final v = ByteData.sublistView(bd);
  v.setUint32(0, ep, Endian.host);
  v.setUint32(4, len, Endian.host);
  v.setUint32(8, timeoutMs, Endian.host);
  if (_ptr == 8) {
    v.setUint64(16, data.address, Endian.host);
  } else {
    v.setUint32(12, data.address, Endian.host);
  }
  final r = _ioctl(fd, _usbdevfsBulk, x);
  if (r < 0) {
    final e = _errno().value;
    if (e == _etimedout) return 0;
    throw TransportError('USB transfer error (errno $e)');
  }
  return r;
}

int _control(int fd, int reqType, int req, int value, int index, Pointer<Uint8> x) {
  final bd = x.asTypedList(_xferSize)..fillRange(0, _xferSize, 0);
  final v = ByteData.sublistView(bd);
  v.setUint8(0, reqType);
  v.setUint8(1, req);
  v.setUint16(2, value, Endian.host);
  v.setUint16(4, index, Endian.host);
  v.setUint16(6, 0, Endian.host);
  v.setUint32(8, 1000, Endian.host);
  return _ioctl(fd, _usbdevfsControl, x);
}

class _ReaderArgs {
  _ReaderArgs(this.fd, this.ep, this.out);
  final int fd, ep;
  final SendPort out;
}

void _readerMain(_ReaderArgs a) {
  final ctl = ReceivePort();
  a.out.send(ctl.sendPort);
  var stop = false;
  ctl.listen((_) => stop = true);
  final buf = malloc<Uint8>(16384);
  final x = calloc<Uint8>(32);
  Future<void> loop() async {
    while (!stop) {
      try {
        final n = _bulk(a.fd, a.ep, buf, 16384, 20, x);
        if (n > 0) {
          a.out.send(TransferableTypedData.fromList([Uint8List.fromList(buf.asTypedList(n))]));
        }
      } on TransportError catch (e) {
        a.out.send(e.message);
        break;
      }
      await Future<void>.delayed(Duration.zero); // see the stop message
    }
    malloc.free(buf);
    calloc.free(x);
    ctl.close();
    Isolate.exit();
  }

  loop();
}

class AndroidUsbTransport implements ByteTransport {
  AndroidUsbTransport._(this.fd, this.epIn, this.epOut, this.iface);

  static Future<AndroidUsbTransport> open(
      {required int fd, required int epIn, required int epOut, required int iface, int maxPacket = 64}) async {
    final t = AndroidUsbTransport._(fd, epIn, epOut, iface);
    final rp = ReceivePort();
    final first = Completer<SendPort>();
    rp.listen((m) {
      if (m is SendPort) {
        first.complete(m);
      } else if (m is TransferableTypedData) {
        t._q.add(m.materialize().asUint8List());
        t._wake();
      } else if (m is String) {
        t._error = m;
        t._wake();
      }
    });
    t._rp = rp;
    t._reader = await Isolate.spawn(_readerMain, _ReaderArgs(fd, epIn, rp.sendPort));
    t._readerCtl = await first.future;
    return t;
  }

  final int fd, epIn, epOut, iface;
  ReceivePort? _rp;
  Isolate? _reader;
  SendPort? _readerCtl;
  final Queue<Uint8List> _q = Queue<Uint8List>();
  Completer<void>? _waiter;
  String? _error;
  bool _dtr = false, _rts = false;
  Pointer<Uint8> _wbuf = malloc<Uint8>(16384);
  int _wcap = 16384;
  final Pointer<Uint8> _x = calloc<Uint8>(32);

  void _wake() {
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  Uint8List _drain() {
    if (_q.isEmpty) return Uint8List(0);
    if (_q.length == 1) return _q.removeFirst();
    final b = BytesBuilder(copy: false);
    while (_q.isNotEmpty) {
      b.add(_q.removeFirst());
    }
    return b.takeBytes();
  }

  @override
  Future<Uint8List> read({Duration timeout = Duration.zero}) async {
    if (_error != null) throw TransportError(_error!);
    if (_q.isEmpty && timeout > Duration.zero) {
      final w = _waiter = Completer<void>();
      await w.future.timeout(timeout, onTimeout: () {});
    }
    return _drain();
  }

  @override
  Future<void> write(Uint8List data, {Duration timeout = const Duration(seconds: 2)}) async {
    if (_error != null) throw TransportError(_error!);
    if (data.length > _wcap) {
      malloc.free(_wbuf);
      _wcap = data.length;
      _wbuf = malloc<Uint8>(_wcap);
    }
    _wbuf.asTypedList(data.length).setAll(0, data);
    var off = 0;
    final sw = Stopwatch()..start();
    while (off < data.length) {
      final left = timeout.inMilliseconds - sw.elapsedMilliseconds;
      if (left <= 0) throw TransportError('Write timeout');
      off += _bulk(fd, epOut, _wbuf + off, data.length - off, left, _x);
    }
  }

  @override
  Future<void> setSignals({bool? dtr, bool? rts}) async {
    if (dtr != null) _dtr = dtr;
    if (rts != null) _rts = rts;
    // CDC SET_CONTROL_LINE_STATE: bit 0 DTR, bit 1 RTS
    _control(fd, 0x21, 0x22, (_dtr ? 1 : 0) | (_rts ? 2 : 0), iface, _x);
  }

  @override
  Future<void> flushInput() async {
    await Future<void>.delayed(const Duration(milliseconds: 30));
    _q.clear();
  }

  @override
  Future<void> close() async {
    _readerCtl?.send('stop');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    _reader?.kill();
    _rp?.close();
    malloc.free(_wbuf);
    calloc.free(_x);
  }
}
