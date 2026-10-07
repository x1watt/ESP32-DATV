/// Linux microphone capture through PulseAudio (also served by PipeWire's pulse server):
/// libpulse-simple for the blocking record loop, libpulse's async API (driven synchronously
/// in a helper isolate) to list the sources. dart:ffi only.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'isolate_capture.dart';
import 'media_source.dart';

const String pulseDefaultId = '';

// ---------------------------------------------------------------- enumeration

/// Lists PulseAudio sources (the default device first). Monitors of outputs are included
/// (they capture what the computer plays) and labelled as such.
Future<List<CaptureDevice>> listPulseSources() async {
  final list = await Isolate.run(_listSync).timeout(const Duration(seconds: 5), onTimeout: () => <List<String>>[]);
  return [const CaptureDevice(pulseDefaultId, 'Default microphone'), for (final s in list) CaptureDevice(s[0], s[1])];
}

typedef _SourceCbN = Void Function(Pointer<Void>, Pointer<Uint8>, Int32, Pointer<Void>);

List<List<String>> _listSync() {
  final DynamicLibrary pa;
  try {
    pa = DynamicLibrary.open('libpulse.so.0');
  } catch (_) {
    return const [];
  }
  final mainloopNew = pa.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>('pa_mainloop_new');
  final mainloopGetApi = pa
      .lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void> Function(Pointer<Void>)>(
        'pa_mainloop_get_api',
      );
  final mainloopIterate = pa
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32, Pointer<Int32>),
        int Function(Pointer<Void>, int, Pointer<Int32>)
      >('pa_mainloop_iterate');
  final mainloopFree = pa.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
    'pa_mainloop_free',
  );
  final contextNew = pa
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>),
        Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>)
      >('pa_context_new');
  final contextConnect = pa
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Utf8>, Int32, Pointer<Void>),
        int Function(Pointer<Void>, Pointer<Utf8>, int, Pointer<Void>)
      >('pa_context_connect');
  final contextGetState = pa.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
    'pa_context_get_state',
  );
  final contextDisconnect = pa.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
    'pa_context_disconnect',
  );
  final contextUnref = pa.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
    'pa_context_unref',
  );
  final getSourceInfoList = pa
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<NativeFunction<_SourceCbN>>, Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>, Pointer<NativeFunction<_SourceCbN>>, Pointer<Void>)
      >('pa_context_get_source_info_list');
  final operationGetState = pa.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
    'pa_operation_get_state',
  );
  final operationUnref = pa.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
    'pa_operation_unref',
  );

  final out = <List<String>>[];
  var done = false;
  // pa_mainloop_iterate runs callbacks synchronously on this thread, so an isolate-local
  // callable is safe here
  final cb = NativeCallable<_SourceCbN>.isolateLocal((Pointer<Void> c, Pointer<Uint8> info, int eol, Pointer<Void> u) {
    if (eol != 0 || info == nullptr) {
      done = true;
      return;
    }
    final name = info.cast<Pointer<Utf8>>().value;
    final desc = (info + 16).cast<Pointer<Utf8>>().value;
    final monitorOf = (info + 308).cast<Uint32>().value;
    final n = name == nullptr ? '' : name.toDartString();
    var d = desc == nullptr ? n : desc.toDartString();
    if (monitorOf != 0xFFFFFFFF && !d.toLowerCase().startsWith('monitor')) d = 'Monitor of $d';
    if (n.isNotEmpty) out.add([n, d]);
  });
  final ml = mainloopNew();
  final appName = 'esp32_datv'.toNativeUtf8();
  final ret = calloc<Int32>();
  final ctx = contextNew(mainloopGetApi(ml), appName);
  try {
    if (ctx == nullptr || contextConnect(ctx, nullptr, 0, nullptr) < 0) return out;
    final sw = Stopwatch()..start();
    // wait for READY (4); FAILED (5) or TERMINATED (6) end it
    while (sw.elapsedMilliseconds < 2000) {
      final st = contextGetState(ctx);
      if (st == 4) break;
      if (st == 5 || st == 6) return out;
      if (mainloopIterate(ml, 0, ret) < 0) return out;
      sleep(const Duration(milliseconds: 2));
    }
    if (contextGetState(ctx) != 4) return out;
    final op = getSourceInfoList(ctx, cb.nativeFunction, nullptr);
    if (op == nullptr) return out;
    while (!done && sw.elapsedMilliseconds < 3000 && operationGetState(op) == 0) {
      if (mainloopIterate(ml, 0, ret) < 0) break;
      if (!done) sleep(const Duration(milliseconds: 2));
    }
    operationUnref(op);
    return out;
  } finally {
    if (ctx != nullptr) {
      contextDisconnect(ctx);
      contextUnref(ctx);
    }
    mainloopFree(ml);
    malloc.free(appName);
    calloc.free(ret);
    cb.close();
  }
}

// ---------------------------------------------------------------- source

MediaSource pulseMicSource(CaptureDevice d, {int sampleRate = 48000, int channels = 1}) =>
    IsolateCaptureSource(d.name, pulseCaptureMain, {'dev': d.id, 'rate': sampleRate, 'ch': channels});

/// Isolate entry point of the PulseAudio record loop (20 ms blocks).
void pulseCaptureMain(CaptureIsolateArgs args) {
  final ctx = CaptureIsolateContext(args);
  final dev = ctx.cfg['dev'] as String;
  final rate = ctx.cfg['rate'] as int, ch = ctx.cfg['ch'] as int;
  final DynamicLibrary lib;
  try {
    lib = DynamicLibrary.open('libpulse-simple.so.0');
  } catch (_) {
    ctx.fail('PulseAudio is not available (libpulse-simple.so.0 not found; install libpulse0 or pipewire-pulse)');
    return;
  }
  final paSimpleNew = lib
      .lookupFunction<
        Pointer<Void> Function(
          Pointer<Utf8>,
          Pointer<Utf8>,
          Int32,
          Pointer<Utf8>,
          Pointer<Utf8>,
          Pointer<Uint8>,
          Pointer<Void>,
          Pointer<Uint32>,
          Pointer<Int32>,
        ),
        Pointer<Void> Function(
          Pointer<Utf8>,
          Pointer<Utf8>,
          int,
          Pointer<Utf8>,
          Pointer<Utf8>,
          Pointer<Uint8>,
          Pointer<Void>,
          Pointer<Uint32>,
          Pointer<Int32>,
        )
      >('pa_simple_new');
  final paSimpleRead = lib
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Uint8>, Size, Pointer<Int32>),
        int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Int32>)
      >('pa_simple_read');
  final paSimpleFree = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('pa_simple_free');
  String strerror(int e) {
    try {
      final f = DynamicLibrary.open('libpulse.so.0')
          .lookupFunction<Pointer<Utf8> Function(Int32), Pointer<Utf8> Function(int)>('pa_strerror');
      return f(e).toDartString();
    } catch (_) {
      return 'error $e';
    }
  }

  final frames = rate ~/ 50; // 20 ms
  final bytes = frames * ch * 2;
  final spec = calloc<Uint8>(12);
  final attr = calloc<Uint32>(5);
  final err = calloc<Int32>();
  final buf = calloc<Uint8>(bytes);
  final name = 'esp32_datv'.toNativeUtf8(), stream = 'DATV microphone'.toNativeUtf8();
  final devName = dev.isEmpty ? nullptr.cast<Utf8>() : dev.toNativeUtf8();
  Pointer<Void> s = nullptr;
  try {
    final sb = ByteData.sublistView(spec.asTypedList(12));
    sb.setUint32(0, 3, Endian.host); // PA_SAMPLE_S16LE
    sb.setUint32(4, rate, Endian.host);
    spec[8] = ch;
    attr[0] = 0xFFFFFFFF; // maxlength: default
    attr[1] = 0xFFFFFFFF;
    attr[2] = 0xFFFFFFFF;
    attr[3] = 0xFFFFFFFF;
    attr[4] = bytes; // fragsize: 20 ms latency
    s = paSimpleNew(nullptr, name, 2, devName, stream, spec, nullptr, attr, err); // PA_STREAM_RECORD
    if (s == nullptr) {
      ctx.fail('Cannot open the microphone: ${strerror(err.value)}');
      return;
    }
    ctx.ready('S16LE $rate Hz x$ch');
    final clock = AudioClock(rate);
    while (!ctx.stopRequested) {
      if (paSimpleRead(s, buf, bytes, err) < 0) {
        ctx.ended('Microphone read failed: ${strerror(err.value)}');
        return;
      }
      final t = ctx.nowUs();
      // TransferableTypedData copies the native view, so no intermediate list is needed
      ctx.audio(buf.cast<Int16>().asTypedList(frames * ch), rate, ch, clock.ptsFor(frames, t));
    }
  } catch (e) {
    ctx.fail('Microphone: $e');
  } finally {
    if (s != nullptr) paSimpleFree(s);
    calloc.free(spec);
    calloc.free(attr);
    calloc.free(err);
    calloc.free(buf);
    malloc.free(name);
    malloc.free(stream);
    if (devName != nullptr) malloc.free(devName);
  }
}
