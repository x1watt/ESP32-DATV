/// Serial transport for Windows: a COM port through kernel32, and port enumeration
/// through setupapi (VID/PID from the hardware ID). dart:ffi only.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../core/esp/transport.dart';

final DynamicLibrary _k32 = DynamicLibrary.open('kernel32.dll');

final int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int) _createFile = _k32.lookupFunction<
    IntPtr Function(Pointer<Utf16>, Uint32, Uint32, Pointer<Void>, Uint32, Uint32, IntPtr),
    int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int)>('CreateFileW');
final int Function(int) _closeHandle = _k32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
final int Function(int, Pointer<Uint8>) _getCommState =
    _k32.lookupFunction<Int32 Function(IntPtr, Pointer<Uint8>), int Function(int, Pointer<Uint8>)>('GetCommState');
final int Function(int, Pointer<Uint8>) _setCommState =
    _k32.lookupFunction<Int32 Function(IntPtr, Pointer<Uint8>), int Function(int, Pointer<Uint8>)>('SetCommState');
final int Function(int, Pointer<Uint32>) _setCommTimeouts =
    _k32.lookupFunction<Int32 Function(IntPtr, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>('SetCommTimeouts');
final int Function(int, int) _escapeCommFunction =
    _k32.lookupFunction<Int32 Function(IntPtr, Uint32), int Function(int, int)>('EscapeCommFunction');
final int Function(int, int) _purgeComm = _k32.lookupFunction<Int32 Function(IntPtr, Uint32), int Function(int, int)>('PurgeComm');
final int Function(int, int, int) _setupComm =
    _k32.lookupFunction<Int32 Function(IntPtr, Uint32, Uint32), int Function(int, int, int)>('SetupComm');
final int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>) _readFile = _k32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>),
    int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)>('ReadFile');
final int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>) _writeFile = _k32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>),
    int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)>('WriteFile');
final int Function() _getLastError = _k32.lookupFunction<Uint32 Function(), int Function()>('GetLastError');

const int _genericRead = 0x80000000, _genericWrite = 0x40000000, _openExisting = 3;
const int _invalidHandle = -1;
const int _setRts = 3, _clrRts = 4, _setDtr = 5, _clrDtr = 6;
const int _purgeRxClear = 0x0008;
const int _maxDword = 0xFFFFFFFF;

class WindowsSerialTransport implements ByteTransport {
  WindowsSerialTransport._(this._h, this.name);

  static WindowsSerialTransport open(String com) {
    final path = (com.startsWith(r'\\.\') ? com : '\\\\.\\$com').toNativeUtf16();
    final h = _createFile(path, _genericRead | _genericWrite, 0, nullptr, _openExisting, 0, 0);
    malloc.free(path);
    if (h == _invalidHandle || h == 0) throw TransportError('Cannot open $com (error ${_getLastError()})');
    _setupComm(h, 65536, 65536);
    final dcb = calloc<Uint8>(28);
    try {
      dcb.cast<Uint32>().value = 28;
      _getCommState(h, dcb);
      final d = dcb.asTypedList(28);
      final bd = ByteData.sublistView(d);
      bd.setUint32(4, 115200, Endian.little);
      bd.setUint32(8, 0x1, Endian.little); // fBinary; DTR/RTS control disabled (set by EscapeCommFunction)
      d[18] = 8; // ByteSize
      d[19] = 0; // no parity
      d[20] = 0; // one stop bit
      if (_setCommState(h, dcb) == 0) {
        _closeHandle(h);
        throw TransportError('$com: SetCommState failed (error ${_getLastError()})');
      }
    } finally {
      calloc.free(dcb);
    }
    final t = WindowsSerialTransport._(h, com);
    t._setTimeouts(0);
    return t;
  }

  final String name;
  int _h;
  int _readTimeoutMs = -1;
  final Pointer<Uint8> _rbuf = malloc<Uint8>(65536);
  Pointer<Uint8> _wbuf = malloc<Uint8>(16384);
  int _wcap = 16384;
  final Pointer<Uint32> _n = calloc<Uint32>();
  final Pointer<Uint32> _to = calloc<Uint32>(5);

  void _setTimeouts(int readMs) {
    if (readMs == _readTimeoutMs) return;
    _readTimeoutMs = readMs;
    final t = _to.asTypedList(5);
    if (readMs == 0) {
      t[0] = _maxDword; // return at once with what is there
      t[1] = 0;
      t[2] = 0;
    } else {
      t[0] = _maxDword; // return at once if bytes are there, else wait for the first byte
      t[1] = _maxDword;
      t[2] = readMs;
    }
    t[3] = 0;
    t[4] = 2000;
    _setCommTimeouts(_h, _to);
  }

  void _check() {
    if (_h == 0) throw TransportError('Port closed');
  }

  @override
  Future<Uint8List> read({Duration timeout = Duration.zero}) async {
    _check();
    _setTimeouts(timeout.inMilliseconds);
    if (_readFile(_h, _rbuf, 65536, _n, nullptr) == 0) {
      throw TransportError('Read error ${_getLastError()} (device disconnected?)');
    }
    final n = _n.value;
    return n == 0 ? Uint8List(0) : Uint8List.fromList(_rbuf.asTypedList(n));
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
      if (_writeFile(_h, _wbuf + off, data.length - off, _n, nullptr) == 0) {
        throw TransportError('Write error ${_getLastError()}');
      }
      off += _n.value;
      if (_n.value == 0 && sw.elapsed > timeout) throw TransportError('Write timeout');
    }
  }

  @override
  Future<void> setSignals({bool? dtr, bool? rts}) async {
    _check();
    if (dtr != null) _escapeCommFunction(_h, dtr ? _setDtr : _clrDtr);
    if (rts != null) _escapeCommFunction(_h, rts ? _setRts : _clrRts);
  }

  @override
  Future<void> flushInput() async {
    _check();
    _purgeComm(_h, _purgeRxClear);
  }

  @override
  Future<void> close() async {
    if (_h != 0) {
      _closeHandle(_h);
      _h = 0;
      malloc.free(_rbuf);
      malloc.free(_wbuf);
      calloc.free(_n);
      calloc.free(_to);
    }
  }
}

// ---------------------------------------------------------------- enumeration (setupapi)
final DynamicLibrary _setupapi = DynamicLibrary.open('setupapi.dll');
final DynamicLibrary _advapi = DynamicLibrary.open('advapi32.dll');

final int Function(Pointer<Uint8>, Pointer<Utf16>, int, int) _getClassDevs = _setupapi.lookupFunction<
    IntPtr Function(Pointer<Uint8>, Pointer<Utf16>, IntPtr, Uint32), int Function(Pointer<Uint8>, Pointer<Utf16>, int, int)>(
    'SetupDiGetClassDevsW');
final int Function(int, int, Pointer<Uint8>) _enumDeviceInfo = _setupapi.lookupFunction<
    Int32 Function(IntPtr, Uint32, Pointer<Uint8>), int Function(int, int, Pointer<Uint8>)>('SetupDiEnumDeviceInfo');
final int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Uint8>, int, Pointer<Uint32>) _getRegProp =
    _setupapi.lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Uint8>, Uint32, Pointer<Uint32>),
        int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Uint8>, int, Pointer<Uint32>)>(
        'SetupDiGetDeviceRegistryPropertyW');
final int Function(int, Pointer<Uint8>, int, int, int, int) _openDevRegKey = _setupapi.lookupFunction<
    IntPtr Function(IntPtr, Pointer<Uint8>, Uint32, Uint32, Uint32, Uint32),
    int Function(int, Pointer<Uint8>, int, int, int, int)>('SetupDiOpenDevRegKey');
final int Function(int) _destroyList =
    _setupapi.lookupFunction<Int32 Function(IntPtr), int Function(int)>('SetupDiDestroyDeviceInfoList');
final int Function(int, Pointer<Utf16>, Pointer<Void>, Pointer<Uint32>, Pointer<Uint8>, Pointer<Uint32>) _regQueryValue =
    _advapi.lookupFunction<
        Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Void>, Pointer<Uint32>, Pointer<Uint8>, Pointer<Uint32>),
        int Function(int, Pointer<Utf16>, Pointer<Void>, Pointer<Uint32>, Pointer<Uint8>, Pointer<Uint32>)>(
        'RegQueryValueExW');
final int Function(int) _regCloseKey = _advapi.lookupFunction<Int32 Function(IntPtr), int Function(int)>('RegCloseKey');

const int _digcfPresent = 0x2;
const int _spdrpHardwareId = 0x1, _spdrpFriendlyName = 0xC, _spdrpMfg = 0xB;
const int _dicsFlagGlobal = 1, _diregDev = 1, _keyRead = 0x20019;

/// {4D36E978-E325-11CE-BFC1-08002BE10318}: the Ports (COM and LPT) class.
const List<int> _guidDevclassPorts = [
  0x78, 0xE9, 0x36, 0x4D, 0x25, 0xE3, 0xCE, 0x11, 0xBF, 0xC1, 0x08, 0x00, 0x2B, 0xE1, 0x03, 0x18, //
];

String _wstr(Pointer<Uint8> p, int bytes) {
  final u = p.cast<Uint16>().asTypedList(bytes ~/ 2);
  var end = u.indexOf(0);
  if (end < 0) end = u.length;
  return String.fromCharCodes(u.sublist(0, end));
}

/// COM ports with USB identifiers where available.
List<PortInfo> listWindowsPorts() {
  final out = <PortInfo>[];
  final guid = calloc<Uint8>(16);
  guid.asTypedList(16).setAll(0, _guidDevclassPorts);
  final set = _getClassDevs(guid, nullptr, 0, _digcfPresent);
  if (set == -1 || set == 0) {
    calloc.free(guid);
    return out;
  }
  final info = calloc<Uint8>(32);
  final buf = calloc<Uint8>(1024);
  final size = calloc<Uint32>();
  final type = calloc<Uint32>();
  final valName = 'PortName'.toNativeUtf16();
  try {
    for (var i = 0;; i++) {
      info.cast<Uint32>().value = sizeOf<IntPtr>() == 8 ? 32 : 28;
      if (_enumDeviceInfo(set, i, info) == 0) break;
      String prop(int which) =>
          _getRegProp(set, info, which, type, buf, 1024, size) != 0 ? _wstr(buf, size.value) : '';
      final hwid = prop(_spdrpHardwareId);
      final friendly = prop(_spdrpFriendlyName);
      final mfg = prop(_spdrpMfg);
      final key = _openDevRegKey(set, info, _dicsFlagGlobal, 0, _diregDev, _keyRead);
      if (key == -1 || key == 0) continue;
      size.value = 1024;
      final ok = _regQueryValue(key, valName, nullptr, type, buf, size) == 0;
      _regCloseKey(key);
      if (!ok) continue;
      final com = _wstr(buf, size.value);
      if (!com.startsWith('COM')) continue;
      final vid = RegExp(r'VID_([0-9A-Fa-f]{4})').firstMatch(hwid);
      final pid = RegExp(r'PID_([0-9A-Fa-f]{4})').firstMatch(hwid);
      out.add(PortInfo(
        id: com,
        name: com,
        vid: vid == null ? null : int.parse(vid[1]!, radix: 16),
        pid: pid == null ? null : int.parse(pid[1]!, radix: 16),
        product: friendly.isEmpty ? null : friendly,
        manufacturer: mfg.isEmpty ? null : mfg,
      ));
    }
  } finally {
    _destroyList(set);
    calloc.free(guid);
    calloc.free(info);
    calloc.free(buf);
    calloc.free(size);
    calloc.free(type);
    malloc.free(valName);
  }
  out.sort((a, b) => (int.tryParse(a.name.substring(3)) ?? 0).compareTo(int.tryParse(b.name.substring(3)) ?? 0));
  return out;
}
