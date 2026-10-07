/// Windows microphone capture with winmm waveIn (CALLBACK_NULL, the loop polls the WHDR_DONE
/// flag of four 20 ms buffers). dart:ffi only; the loop is synchronous so it stays on one
/// OS thread.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'isolate_capture.dart';
import 'media_source.dart';

class _WinMM {
  final DynamicLibrary lib = DynamicLibrary.open('winmm.dll');

  late final int Function() getNumDevs = lib.lookupFunction<Uint32 Function(), int Function()>('waveInGetNumDevs');
  late final int Function(int, Pointer<Uint8>, int) getDevCaps = lib
      .lookupFunction<Uint32 Function(UintPtr, Pointer<Uint8>, Uint32), int Function(int, Pointer<Uint8>, int)>(
        'waveInGetDevCapsW',
      );
  late final int Function(Pointer<IntPtr>, int, Pointer<Uint8>, int, int, int) open = lib
      .lookupFunction<
        Uint32 Function(Pointer<IntPtr>, Uint32, Pointer<Uint8>, UintPtr, UintPtr, Uint32),
        int Function(Pointer<IntPtr>, int, Pointer<Uint8>, int, int, int)
      >('waveInOpen');
  late final int Function(int, Pointer<Uint8>, int) prepareHeader = lib
      .lookupFunction<Uint32 Function(IntPtr, Pointer<Uint8>, Uint32), int Function(int, Pointer<Uint8>, int)>(
        'waveInPrepareHeader',
      );
  late final int Function(int, Pointer<Uint8>, int) unprepareHeader = lib
      .lookupFunction<Uint32 Function(IntPtr, Pointer<Uint8>, Uint32), int Function(int, Pointer<Uint8>, int)>(
        'waveInUnprepareHeader',
      );
  late final int Function(int, Pointer<Uint8>, int) addBuffer = lib
      .lookupFunction<Uint32 Function(IntPtr, Pointer<Uint8>, Uint32), int Function(int, Pointer<Uint8>, int)>(
        'waveInAddBuffer',
      );
  late final int Function(int) start = lib.lookupFunction<Uint32 Function(IntPtr), int Function(int)>('waveInStart');
  late final int Function(int) stop = lib.lookupFunction<Uint32 Function(IntPtr), int Function(int)>('waveInStop');
  late final int Function(int) reset = lib.lookupFunction<Uint32 Function(IntPtr), int Function(int)>('waveInReset');
  late final int Function(int) close = lib.lookupFunction<Uint32 Function(IntPtr), int Function(int)>('waveInClose');
}

const int _waveMapper = 0xFFFFFFFF;
const int _hdrSize = 48; // WAVEHDR on 64-bit
const int _whdrDone = 1;

String _mmError(int e) => switch (e) {
  2 => 'the device is gone (bad device id)',
  4 => 'the device is in use by another program',
  6 => 'no driver',
  32 => 'the device does not support 16-bit PCM at this rate',
  _ => 'MMSYSERR $e',
};

/// Lists waveIn devices. Ids are the device index ("" = system default). The names come
/// from WAVEINCAPS and are cut to 31 characters by Windows.
Future<List<CaptureDevice>> listWaveInDevices() => Isolate.run(() {
  final mm = _WinMM();
  final caps = calloc<Uint8>(80);
  try {
    final out = [const CaptureDevice('', 'Default microphone')];
    final n = mm.getNumDevs();
    for (var i = 0; i < n; i++) {
      if (mm.getDevCaps(i, caps, 80) != 0) continue;
      out.add(CaptureDevice('$i', (caps + 8).cast<Utf16>().toDartString()));
    }
    return out;
  } finally {
    calloc.free(caps);
  }
});

MediaSource waveInMicSource(CaptureDevice d, {int sampleRate = 48000, int channels = 1}) =>
    IsolateCaptureSource(d.name, waveInCaptureMain, {'dev': d.id, 'rate': sampleRate, 'ch': channels});

/// Isolate entry point of the waveIn loop.
void waveInCaptureMain(CaptureIsolateArgs args) {
  final ctx = CaptureIsolateContext(args);
  final rate = ctx.cfg['rate'] as int, ch = ctx.cfg['ch'] as int;
  final dev = ctx.cfg['dev'] as String;
  final devId = dev.isEmpty ? _waveMapper : int.parse(dev);
  final mm = _WinMM();
  const nbuf = 4;
  final frames = rate ~/ 50, bytes = frames * ch * 2;
  final fmt = calloc<Uint8>(20);
  final handle = calloc<IntPtr>();
  final hdrs = calloc<Uint8>(_hdrSize * nbuf);
  final data = calloc<Uint8>(bytes * nbuf);
  var h = 0;
  final prepared = <int>[];
  try {
    final f = ByteData.sublistView(fmt.asTypedList(20));
    f.setUint16(0, 1, Endian.little); // WAVE_FORMAT_PCM
    f.setUint16(2, ch, Endian.little);
    f.setUint32(4, rate, Endian.little);
    f.setUint32(8, rate * ch * 2, Endian.little);
    f.setUint16(12, ch * 2, Endian.little);
    f.setUint16(14, 16, Endian.little);
    f.setUint16(16, 0, Endian.little);
    var r = mm.open(handle, devId, fmt, 0, 0, 0); // CALLBACK_NULL
    if (r != 0) {
      ctx.fail(
        'Cannot open the microphone: ${_mmError(r)}. '
        'Check Settings > Privacy > Microphone ("Let desktop apps access your microphone").',
      );
      return;
    }
    h = handle.value;
    for (var i = 0; i < nbuf; i++) {
      final hdr = hdrs + i * _hdrSize;
      final hb = ByteData.sublistView(hdr.asTypedList(_hdrSize));
      hb.setUint64(0, (data + i * bytes).address, Endian.little); // lpData
      hb.setUint32(8, bytes, Endian.little); // dwBufferLength
      r = mm.prepareHeader(h, hdr, _hdrSize);
      if (r != 0) {
        ctx.fail('waveInPrepareHeader failed: ${_mmError(r)}');
        return;
      }
      prepared.add(i);
      r = mm.addBuffer(h, hdr, _hdrSize);
      if (r != 0) {
        ctx.fail('waveInAddBuffer failed: ${_mmError(r)}');
        return;
      }
    }
    r = mm.start(h);
    if (r != 0) {
      ctx.fail('waveInStart failed: ${_mmError(r)}');
      return;
    }
    ctx.ready('PCM16 $rate Hz x$ch');
    final clock = AudioClock(rate);
    var idx = 0;
    while (!ctx.stopRequested) {
      final hdr = hdrs + idx * _hdrSize;
      final flags = (hdr + 24).cast<Uint32>();
      if (flags.value & _whdrDone == 0) {
        sleep(const Duration(milliseconds: 3));
        continue;
      }
      final t = ctx.nowUs();
      final got = (hdr + 12).cast<Uint32>().value; // dwBytesRecorded
      final n = got ~/ (2 * ch);
      if (n > 0) {
        ctx.audio((data + idx * bytes).cast<Int16>().asTypedList(n * ch), rate, ch, clock.ptsFor(n, t));
      }
      flags.value = flags.value & ~_whdrDone;
      (hdr + 12).cast<Uint32>().value = 0;
      r = mm.addBuffer(h, hdr, _hdrSize);
      if (r != 0) {
        ctx.ended('Microphone stopped: ${_mmError(r)}');
        return;
      }
      idx = (idx + 1) % nbuf;
    }
  } catch (e) {
    ctx.fail('Microphone: $e');
  } finally {
    if (h != 0) {
      mm.stop(h);
      mm.reset(h); // returns all buffers (marked done)
      for (final i in prepared) {
        mm.unprepareHeader(h, hdrs + i * _hdrSize, _hdrSize);
      }
      mm.close(h);
    }
    calloc.free(fmt);
    calloc.free(handle);
    calloc.free(hdrs);
    calloc.free(data);
  }
}
