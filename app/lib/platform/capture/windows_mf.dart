/// Windows camera capture with Media Foundation: MFEnumDeviceSources, an IMFSourceReader on
/// the device in synchronous mode, output converted by the reader to YUY2 (else NV12, else
/// RGB32). COM is called through raw vtable slots with dart:ffi (no package:win32).
///
/// Why not the `camera` plugin: camera 0.12 does not endorse a Windows implementation, and
/// camera_windows (not in pubspec) has no image streaming. Media Foundation is what that
/// plugin uses underneath anyway, and the source reader decodes MJPEG cameras for us.
///
/// Everything COM happens inside one synchronous function per isolate, so all calls are
/// made from the one OS thread that called CoInitializeEx.
library;

import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'isolate_capture.dart';
import 'media_source.dart';
import 'pixel_pack.dart';

// ---------------------------------------------------------------- GUIDs

Pointer<Uint8> _guid(String s, Allocator a) {
  final h = s.replaceAll('-', '');
  final p = a<Uint8>(16);
  final b = ByteData.sublistView(p.asTypedList(16));
  b.setUint32(0, int.parse(h.substring(0, 8), radix: 16), Endian.little);
  b.setUint16(4, int.parse(h.substring(8, 12), radix: 16), Endian.little);
  b.setUint16(6, int.parse(h.substring(12, 16), radix: 16), Endian.little);
  for (var i = 0; i < 8; i++) {
    p[8 + i] = int.parse(h.substring(16 + 2 * i, 18 + 2 * i), radix: 16);
  }
  return p;
}

bool _guidEq(Pointer<Uint8> a, Pointer<Uint8> b) {
  for (var i = 0; i < 16; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

const String _kSourceType = 'c60ac5fe-252a-478f-a0ef-bc8fa5f7cad3'; // MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE
const String _kVidcap = '8ac3587a-4ae7-42d8-99e0-0a6013eef90f'; // ..._SOURCE_TYPE_VIDCAP_GUID
const String _kFriendlyName = '60d0e559-52f8-4fa2-bbce-acdb34a8ec01';
const String _kSymbolicLink = '58f0aad8-22bf-4f8a-bb3d-d2c4978c6e2f';
const String _iidMediaSource = '279a808d-aec7-40c8-9c6b-a6b492c78a66';
const String _kAdvancedVp = '0f81da2c-b537-4672-a8b2-a681b17307a3'; // MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING
const String _kVideoProcessing = 'fb394f3d-ccf1-42ee-bbb3-f9b845d5681d'; // MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING
const String _kMajorType = '48eba18e-f8c9-4687-bf11-0a74c9f96a8f';
const String _kSubtype = 'f7e34c9a-42e8-4714-b74b-cb29d72c35e5';
const String _kFrameSize = '1652c33d-d6b2-4012-b834-72030849a37d';
const String _kFrameRate = 'c459a2e8-3d2c-4e44-b132-fee5156c7bb0';
const String _kDefaultStride = '644b4e48-1e02-4516-b0eb-c01ca9d49ac6';
const String _mediaTypeVideo = '73646976-0000-0010-8000-00aa00389b71';
const String _fmtYuy2 = '32595559-0000-0010-8000-00aa00389b71';
const String _fmtNv12 = '3231564e-0000-0010-8000-00aa00389b71';
const String _fmtRgb32 = '00000016-0000-0010-8000-00aa00389b71';

const int _firstVideoStream = 0xFFFFFFFC;
const int _allStreams = 0xFFFFFFFE;
const int _mfVersion = 0x00020070;

// ---------------------------------------------------------------- COM plumbing

/// Function pointer of vtable slot [i] of COM object [o].
Pointer<NativeFunction<T>> _slot<T extends Function>(Pointer<Void> o, int i) =>
    Pointer<NativeFunction<T>>.fromAddress(o.cast<Pointer<IntPtr>>().value[i]);

void _release(Pointer<Void> o) {
  if (o == nullptr) return;
  _slot<Uint32 Function(Pointer<Void>)>(o, 2).asFunction<int Function(Pointer<Void>)>()(o);
}

int _getU32(Pointer<Void> a, Pointer<Uint8> key, Pointer<Uint32> out) =>
    _slot<Int32 Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint32>)>(
      a,
      7,
    ).asFunction<int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint32>)>()(a, key, out);
int _getU64(Pointer<Void> a, Pointer<Uint8> key, Pointer<Uint64> out) =>
    _slot<Int32 Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint64>)>(
      a,
      8,
    ).asFunction<int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint64>)>()(a, key, out);
int _getGuid(Pointer<Void> a, Pointer<Uint8> key, Pointer<Uint8> out) =>
    _slot<Int32 Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>)>(
      a,
      10,
    ).asFunction<int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>)>()(a, key, out);
int _getAllocString(Pointer<Void> a, Pointer<Uint8> key, Pointer<Pointer<Utf16>> out, Pointer<Uint32> len) =>
    _slot<Int32 Function(Pointer<Void>, Pointer<Uint8>, Pointer<Pointer<Utf16>>, Pointer<Uint32>)>(
      a,
      13,
    ).asFunction<int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Pointer<Utf16>>, Pointer<Uint32>)>()(
      a,
      key,
      out,
      len,
    );
int _setU32(Pointer<Void> a, Pointer<Uint8> key, int v) => _slot<Int32 Function(Pointer<Void>, Pointer<Uint8>, Uint32)>(
  a,
  21,
).asFunction<int Function(Pointer<Void>, Pointer<Uint8>, int)>()(a, key, v);
int _setGuid(Pointer<Void> a, Pointer<Uint8> key, Pointer<Uint8> v) =>
    _slot<Int32 Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>)>(
      a,
      24,
    ).asFunction<int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>)>()(a, key, v);

class _Mf {
  final DynamicLibrary ole32 = DynamicLibrary.open('ole32.dll');
  final DynamicLibrary mfplat = DynamicLibrary.open('mfplat.dll');
  final DynamicLibrary mf = DynamicLibrary.open('mf.dll');
  final DynamicLibrary mfreadwrite = DynamicLibrary.open('mfreadwrite.dll');

  late final int Function(Pointer<Void>, int) coInitializeEx = ole32
      .lookupFunction<Int32 Function(Pointer<Void>, Uint32), int Function(Pointer<Void>, int)>('CoInitializeEx');
  late final void Function() coUninitialize = ole32.lookupFunction<Void Function(), void Function()>('CoUninitialize');
  late final void Function(Pointer<Void>) coTaskMemFree = ole32
      .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('CoTaskMemFree');
  late final int Function(int, int) mfStartup = mfplat
      .lookupFunction<Int32 Function(Uint32, Uint32), int Function(int, int)>('MFStartup');
  late final int Function() mfShutdown = mfplat.lookupFunction<Int32 Function(), int Function()>('MFShutdown');
  late final int Function(Pointer<Pointer<Void>>, int) createAttributes = mfplat
      .lookupFunction<Int32 Function(Pointer<Pointer<Void>>, Uint32), int Function(Pointer<Pointer<Void>>, int)>(
        'MFCreateAttributes',
      );
  late final int Function(Pointer<Pointer<Void>>) createMediaType = mfplat
      .lookupFunction<Int32 Function(Pointer<Pointer<Void>>), int Function(Pointer<Pointer<Void>>)>(
        'MFCreateMediaType',
      );
  late final int Function(Pointer<Void>, Pointer<Pointer<Pointer<Void>>>, Pointer<Uint32>) enumDeviceSources = mf
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Pointer<Pointer<Void>>>, Pointer<Uint32>),
        int Function(Pointer<Void>, Pointer<Pointer<Pointer<Void>>>, Pointer<Uint32>)
      >('MFEnumDeviceSources');
  late final int Function(Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>) createSourceReader = mfreadwrite
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>),
        int Function(Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>)
      >('MFCreateSourceReaderFromMediaSource');

  bool _comInit = false, _mfInit = false;

  /// CoInitializeEx (MTA) + MFStartup. Returns an error text or null.
  String? startup() {
    final hr = coInitializeEx(nullptr, 0);
    _comInit = hr >= 0; // S_OK / S_FALSE; RPC_E_CHANGED_MODE leaves COM usable as it is
    final r = mfStartup(_mfVersion, 0);
    if (r < 0) {
      return 'Media Foundation is not available (MFStartup ${_hr(r)}). '
          'Windows N editions need the Media Feature Pack.';
    }
    _mfInit = true;
    return null;
  }

  void shutdown() {
    if (_mfInit) mfShutdown();
    if (_comInit) coUninitialize();
  }

  /// Enumerates video capture devices. Caller releases each activate and frees the array.
  (Pointer<Pointer<Void>>, int) enumerate(Arena a) {
    final attrs = a<Pointer<Void>>();
    if (createAttributes(attrs, 1) < 0) return (nullptr, 0);
    _setGuid(attrs.value, _guid(_kSourceType, a), _guid(_kVidcap, a));
    final arr = a<Pointer<Pointer<Void>>>();
    final n = a<Uint32>();
    final hr = enumDeviceSources(attrs.value, arr, n);
    _release(attrs.value);
    if (hr < 0) return (nullptr, 0);
    return (arr.value, n.value);
  }

  String string(Pointer<Void> act, String key, Arena a) {
    final s = a<Pointer<Utf16>>();
    final len = a<Uint32>();
    if (_getAllocString(act, _guid(key, a), s, len) < 0 || s.value == nullptr) return '';
    final out = s.value.toDartString(length: len.value);
    coTaskMemFree(s.value.cast());
    return out;
  }
}

String _hr(int hr) => '0x${(hr & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0')}';

// ---------------------------------------------------------------- enumeration

/// Lists cameras. Ids are the device symbolic links.
Future<List<CaptureDevice>> listMfCameras() => Isolate.run(() {
  final m = _Mf();
  final out = <CaptureDevice>[];
  if (m.startup() != null) {
    m.shutdown();
    return out;
  }
  using((a) {
    final (arr, n) = m.enumerate(a);
    for (var i = 0; i < n; i++) {
      final act = arr[i];
      final name = m.string(act, _kFriendlyName, a);
      final link = m.string(act, _kSymbolicLink, a);
      out.add(CaptureDevice(link.isEmpty ? '#$i' : link, name.isEmpty ? 'Camera ${i + 1}' : name));
      _release(act);
    }
    if (arr != nullptr) m.coTaskMemFree(arr.cast());
  });
  m.shutdown();
  return out;
});

// ---------------------------------------------------------------- source

MediaSource mfCameraSource(CaptureDevice d, {int maxWidth = 1280, int fps = 25}) =>
    IsolateCaptureSource(d.name, mfCaptureMain, {'id': d.id, 'maxWidth': maxWidth, 'fps': fps});

/// Isolate entry point of the Media Foundation camera loop.
void mfCaptureMain(CaptureIsolateArgs args) {
  final ctx = CaptureIsolateContext(args);
  final id = ctx.cfg['id'] as String;
  final maxWidth = ctx.cfg['maxWidth'] as int, fps = ctx.cfg['fps'] as int;
  final m = _Mf();
  final err = m.startup();
  if (err != null) {
    ctx.fail(err);
    m.shutdown();
    return;
  }
  final a = Arena();
  Pointer<Void> activate = nullptr, source = nullptr, reader = nullptr;
  try {
    // find the device
    final (arr, n) = m.enumerate(a);
    for (var i = 0; i < n; i++) {
      final act = arr[i];
      if (activate == nullptr && (m.string(act, _kSymbolicLink, a) == id || id == '#$i')) {
        activate = act;
      } else {
        _release(act);
      }
    }
    if (arr != nullptr) m.coTaskMemFree(arr.cast());
    if (activate == nullptr) {
      ctx.fail('Camera not found (unplugged?)');
      return;
    }
    final pSource = a<Pointer<Void>>();
    var hr =
        _slot<Int32 Function(Pointer<Void>, Pointer<Uint8>, Pointer<Pointer<Void>>)>(
          activate,
          33,
        ).asFunction<int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Pointer<Void>>)>()(
          activate,
          _guid(_iidMediaSource, a),
          pSource,
        );
    if (hr < 0) {
      ctx.fail(
        hr & 0xFFFFFFFF == 0x80070005
            ? 'Camera access denied. Check Settings > Privacy > Camera ("Let desktop apps access your camera").'
            : 'Cannot open the camera (${_hr(hr)}); is it used by another program?',
      );
      return;
    }
    source = pSource.value;
    // reader with converters (decodes MJPEG, converts to YUY2/NV12/RGB32)
    final rattrs = a<Pointer<Void>>();
    m.createAttributes(rattrs, 1);
    if (_setU32(rattrs.value, _guid(_kAdvancedVp, a), 1) < 0) {
      _setU32(rattrs.value, _guid(_kVideoProcessing, a), 1);
    }
    final pReader = a<Pointer<Void>>();
    hr = m.createSourceReader(source, rattrs.value, pReader);
    _release(rattrs.value);
    if (hr < 0) {
      // Windows 7 has no advanced processing: retry with the basic one
      final r2 = a<Pointer<Void>>();
      m.createAttributes(r2, 1);
      _setU32(r2.value, _guid(_kVideoProcessing, a), 1);
      hr = m.createSourceReader(source, r2.value, pReader);
      _release(r2.value);
    }
    if (hr < 0) {
      ctx.fail('MFCreateSourceReaderFromMediaSource failed (${_hr(hr)})');
      return;
    }
    reader = pReader.value;
    final selectStreamF = _slot<Int32 Function(Pointer<Void>, Uint32, Int32)>(
      reader,
      4,
    ).asFunction<int Function(Pointer<Void>, int, int)>();
    final getNativeF = _slot<Int32 Function(Pointer<Void>, Uint32, Uint32, Pointer<Pointer<Void>>)>(
      reader,
      5,
    ).asFunction<int Function(Pointer<Void>, int, int, Pointer<Pointer<Void>>)>();
    final getCurrentF = _slot<Int32 Function(Pointer<Void>, Uint32, Pointer<Pointer<Void>>)>(
      reader,
      6,
    ).asFunction<int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)>();
    final setCurrentF = _slot<Int32 Function(Pointer<Void>, Uint32, Pointer<Uint32>, Pointer<Void>)>(
      reader,
      7,
    ).asFunction<int Function(Pointer<Void>, int, Pointer<Uint32>, Pointer<Void>)>();
    final readSampleF =
        _slot<
              Int32 Function(
                Pointer<Void>,
                Uint32,
                Uint32,
                Pointer<Uint32>,
                Pointer<Uint32>,
                Pointer<Int64>,
                Pointer<Pointer<Void>>,
              )
            >(reader, 9)
            .asFunction<
              int Function(
                Pointer<Void>,
                int,
                int,
                Pointer<Uint32>,
                Pointer<Uint32>,
                Pointer<Int64>,
                Pointer<Pointer<Void>>,
              )
            >();
    final rd = reader;
    int selectStream(int stream, int on) => selectStreamF(rd, stream, on);
    int getNative(int stream, int i, Pointer<Pointer<Void>> t) => getNativeF(rd, stream, i, t);
    int getCurrent(int stream, Pointer<Pointer<Void>> t) => getCurrentF(rd, stream, t);
    int setCurrent(int stream, Pointer<Uint32> reserved, Pointer<Void> t) => setCurrentF(rd, stream, reserved, t);
    int readSample(
      int stream,
      int flags,
      Pointer<Uint32> actual,
      Pointer<Uint32> streamFlags,
      Pointer<Int64> ts,
      Pointer<Pointer<Void>> sample,
    ) => readSampleF(rd, stream, flags, actual, streamFlags, ts, sample);
    selectStream(_allStreams, 0);
    selectStream(_firstVideoStream, 1);

    final kSize = _guid(_kFrameSize, a), kRate = _guid(_kFrameRate, a), kSub = _guid(_kSubtype, a);
    final u64 = a<Uint64>(), u32 = a<Uint32>();
    final pType = a<Pointer<Void>>();

    // pick the native mode: frame rate up to the request first, then size up to maxWidth
    var bestIdx = -1;
    var bestScore = -1.0;
    for (var i = 0; i < 512; i++) {
      if (getNative(_firstVideoStream, i, pType) < 0) break;
      final t = pType.value;
      var w = 0, h = 0;
      var rate = 0.0;
      if (_getU64(t, kSize, u64) >= 0) {
        w = u64.value >> 32;
        h = u64.value & 0xFFFFFFFF;
      }
      if (_getU64(t, kRate, u64) >= 0) {
        final num = u64.value >> 32, den = u64.value & 0xFFFFFFFF;
        if (den > 0) rate = num / den;
      }
      _release(t);
      if (w == 0 || w > maxWidth) continue;
      final f = rate < fps ? rate : fps.toDouble();
      final score = f * 1e7 + w * h;
      if (score > bestScore) {
        bestScore = score;
        bestIdx = i;
      }
    }
    if (bestIdx >= 0 && getNative(_firstVideoStream, bestIdx, pType) >= 0) {
      setCurrent(_firstVideoStream, nullptr, pType.value);
      _release(pType.value);
    }

    // ask the reader for an uncompressed output it can convert to
    String? subtype;
    for (final s in [_fmtYuy2, _fmtNv12, _fmtRgb32]) {
      final pt = a<Pointer<Void>>();
      if (m.createMediaType(pt) < 0) break;
      _setGuid(pt.value, _guid(_kMajorType, a), _guid(_mediaTypeVideo, a));
      _setGuid(pt.value, kSub, _guid(s, a));
      final ok = setCurrent(_firstVideoStream, nullptr, pt.value) >= 0;
      _release(pt.value);
      if (ok) {
        subtype = s;
        break;
      }
    }
    if (subtype == null) {
      ctx.fail('The camera offers no format Media Foundation can convert to YUY2, NV12 or RGB32');
      return;
    }
    // what we really get
    if (getCurrent(_firstVideoStream, pType) < 0) {
      ctx.fail('Cannot read the camera format');
      return;
    }
    final cur = pType.value;
    var w = 0, h = 0, stride = 0;
    if (_getU64(cur, kSize, u64) >= 0) {
      w = u64.value >> 32;
      h = u64.value & 0xFFFFFFFF;
    }
    final gotSub = a<Uint8>(16);
    if (_getGuid(cur, kSub, gotSub) >= 0) {
      for (final s in [_fmtYuy2, _fmtNv12, _fmtRgb32]) {
        if (_guidEq(gotSub, _guid(s, a))) subtype = s;
      }
    }
    final isRgb = subtype == _fmtRgb32, isNv12 = subtype == _fmtNv12;
    if (_getU32(cur, _guid(_kDefaultStride, a), u32) >= 0) {
      stride = u32.value.toSigned(32);
    } else {
      // documented defaults: RGB is bottom-up, YUV top-down
      stride = isRgb ? -w * 4 : (isNv12 ? w : w * 2);
    }
    _release(cur);
    if (w == 0 || h == 0) {
      ctx.fail('The camera reports no frame size');
      return;
    }
    ctx.ready(
      '${isRgb
          ? 'RGB32'
          : isNv12
          ? 'NV12'
          : 'YUY2'} ${w}x$h (Media Foundation)',
    );

    final actual = a<Uint32>(), flags = a<Uint32>();
    final ts = a<Int64>();
    final pSample = a<Pointer<Void>>(), pBuf = a<Pointer<Void>>();
    final pData = a<Pointer<Uint8>>();
    final maxLen = a<Uint32>(), curLen = a<Uint32>();
    final minGapUs = 1000000 ~/ fps - 3000;
    var lastUs = -1 << 40;
    final absStride = stride.abs();
    while (!ctx.stopRequested) {
      pSample.value = nullptr;
      hr = readSample(_firstVideoStream, 0, actual, flags, ts, pSample);
      if (hr < 0) {
        ctx.ended('Camera stopped (${_hr(hr)}), unplugged?');
        return;
      }
      if (flags.value & 0x3 != 0) {
        // MF_SOURCE_READERF_ERROR / ENDOFSTREAM
        if (pSample.value != nullptr) _release(pSample.value);
        ctx.ended('Camera stream ended');
        return;
      }
      final sample = pSample.value;
      if (sample == nullptr) continue; // stream tick or format change notice
      final t = ctx.nowUs();
      try {
        if (t - lastUs < minGapUs || ctx.congested) continue;
        lastUs = t;
        if (_slot<Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>)>(
              sample,
              41,
            ).asFunction<int Function(Pointer<Void>, Pointer<Pointer<Void>>)>()(sample, pBuf) <
            0) {
          continue;
        }
        final buf = pBuf.value;
        final lock = _slot<Int32 Function(Pointer<Void>, Pointer<Pointer<Uint8>>, Pointer<Uint32>, Pointer<Uint32>)>(
          buf,
          3,
        ).asFunction<int Function(Pointer<Void>, Pointer<Pointer<Uint8>>, Pointer<Uint32>, Pointer<Uint32>)>();
        final unlock = _slot<Int32 Function(Pointer<Void>)>(buf, 4).asFunction<int Function(Pointer<Void>)>();
        if (lock(buf, pData, maxLen, curLen) >= 0) {
          try {
            final len = curLen.value;
            final view = pData.value.asTypedList(len);
            if (isRgb) {
              if (len >= absStride * h) {
                final px = stride < 0 ? packRowsFlipped(view, w * 4, absStride, h) : view;
                ctx.video(RawFormat.bgra, px, w, h, stride < 0 ? w * 4 : absStride, t);
              }
            } else if (isNv12) {
              if (len >= absStride * h * 3 ~/ 2) {
                ctx.video(RawFormat.i420, nv12ToI420(view, w, h, absStride), w, h, w, t);
              }
            } else if (len >= absStride * h) {
              ctx.video(RawFormat.yuyv, view, w, h, absStride, t);
            }
          } finally {
            unlock(buf);
          }
        }
        _release(buf);
      } finally {
        _release(sample);
      }
    }
  } catch (e) {
    ctx.fail('Camera: $e');
  } finally {
    _release(reader);
    if (source != nullptr) {
      _slot<Int32 Function(Pointer<Void>)>(source, 12).asFunction<int Function(Pointer<Void>)>()(source);
      _release(source);
    }
    if (activate != nullptr) {
      _slot<Int32 Function(Pointer<Void>)>(activate, 34).asFunction<int Function(Pointer<Void>)>()(activate);
      _release(activate);
    }
    a.releaseAll();
    m.shutdown();
  }
}
