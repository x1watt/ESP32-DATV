/// Android capture: camera through the `camera` plugin (image stream, YUV_420_888 packed to
/// I420), microphone through the `record` plugin (PCM16 stream), screen through
/// MediaProjection in Kotlin (ScreenCaptureChannel.kt, RGBA frames over an EventChannel).
///
/// The plugins deliver on the UI isolate; the per-frame work there is one plane copy
/// (memcpy-like setRange per row), throttled to the requested frame rate.
library;

import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

import 'isolate_capture.dart' show AudioClock;
import 'media_source.dart';
import 'pixel_pack.dart';

// ---------------------------------------------------------------- camera

Future<List<CaptureDevice>> listAndroidCameras() async {
  try {
    final cams = await availableCameras();
    var back = 0, front = 0, ext = 0;
    return [
      for (final c in cams)
        CaptureDevice(c.name, switch (c.lensDirection) {
          CameraLensDirection.back => 'Back camera${++back > 1 ? ' $back' : ''}',
          CameraLensDirection.front => 'Front camera${++front > 1 ? ' $front' : ''}',
          CameraLensDirection.external => 'External camera${++ext > 1 ? ' $ext' : ''}',
        }),
    ];
  } on CameraException {
    return const [];
  }
}

class AndroidCameraSource implements MediaSource {
  AndroidCameraSource(this.device, {this.maxWidth = 1280, this.fps = 25});
  final CaptureDevice device;
  final int maxWidth, fps;
  CameraController? _ctl;
  int _lastUs = -1 << 40;

  @override
  String get label => device.name;

  /// 720x480 for maxWidth up to 720, else 1280x720 (the encoder scales further down).
  ResolutionPreset get _preset => maxWidth <= 352
      ? ResolutionPreset.low
      : maxWidth <= 720
      ? ResolutionPreset.medium
      : ResolutionPreset.high;

  @override
  Future<void> start(MediaSink sink) async {
    final cams = await availableCameras();
    final desc = cams.where((c) => c.name == device.id).firstOrNull;
    if (desc == null) throw CaptureError('Camera "${device.name}" is not available');
    final ctl = CameraController(
      desc,
      _preset,
      enableAudio: false,
      fps: fps,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    try {
      await ctl.initialize();
      final period = 1000000 ~/ fps - 3000;
      await ctl.startImageStream((img) {
        final now = sink.nowUs();
        if (now - _lastUs < period) return;
        _lastUs = now;
        final pic = cameraImageToI420(img);
        if (pic != null) sink.video(RawFormat.i420, pic, img.width & ~1, img.height & ~1, img.width & ~1, now);
      });
      _ctl = ctl;
    } on CameraException catch (e) {
      await ctl.dispose();
      throw CaptureError(
        e.code == 'CameraAccessDenied' || e.code == 'cameraPermission'
            ? 'Camera permission denied'
            : 'Camera: ${e.description ?? e.code}',
      );
    }
  }

  @override
  Future<void> stop() async {
    final c = _ctl;
    _ctl = null;
    if (c == null) return;
    try {
      if (c.value.isStreamingImages) await c.stopImageStream();
    } catch (_) {}
    await c.dispose();
  }
}

/// Packs a YUV_420_888 [CameraImage] into I420 cropped to even dimensions. Null when the
/// image is not three-plane YUV.
Uint8List? cameraImageToI420(CameraImage img) {
  if (img.planes.length < 3) return null;
  final y = img.planes[0], u = img.planes[1], v = img.planes[2];
  return yuv420ToI420(
    width: img.width & ~1,
    height: img.height & ~1,
    y: y.bytes,
    yRowStride: y.bytesPerRow,
    yPixelStride: y.bytesPerPixel ?? 1,
    u: u.bytes,
    v: v.bytes,
    uvRowStride: u.bytesPerRow,
    uvPixelStride: u.bytesPerPixel ?? 1,
  );
}

// ---------------------------------------------------------------- microphone

Future<List<CaptureDevice>> listRecordMicrophones() async {
  final r = AudioRecorder();
  try {
    final devs = await r.listInputDevices();
    return [const CaptureDevice('', 'Default microphone'), for (final d in devs) CaptureDevice(d.id, d.label)];
  } catch (_) {
    return const [CaptureDevice('', 'Default microphone')];
  } finally {
    await r.dispose();
  }
}

class RecordMicSource implements MediaSource {
  RecordMicSource(this.device, {this.sampleRate = 48000, this.channels = 1});
  final CaptureDevice device;
  final int sampleRate, channels;
  AudioRecorder? _rec;
  StreamSubscription<Uint8List>? _sub;

  @override
  String get label => device.name;

  @override
  Future<void> start(MediaSink sink) async {
    final rec = AudioRecorder();
    try {
      if (!await rec.hasPermission()) throw CaptureError('Microphone permission denied');
      InputDevice? dev;
      if (device.id.isNotEmpty) {
        dev = (await rec.listInputDevices()).where((d) => d.id == device.id).firstOrNull;
      }
      final stream = await rec.startStream(
        RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: sampleRate, numChannels: channels, device: dev),
      );
      final frames = sampleRate ~/ 50;
      final blocker = PcmBlocker(frames, channels);
      final clock = AudioClock(sampleRate);
      _sub = stream.listen((bytes) {
        blocker.add(bytes, (pcm) {
          sink.audio(pcm, sampleRate, channels, clock.ptsFor(frames, sink.nowUs()));
        });
      });
      _rec = rec;
    } on CaptureError {
      await rec.dispose();
      rethrow;
    } catch (e) {
      await rec.dispose();
      throw CaptureError('Microphone: $e');
    }
  }

  @override
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    final r = _rec;
    _rec = null;
    if (r == null) return;
    try {
      await r.stop();
    } catch (_) {}
    await r.dispose();
  }
}

// ---------------------------------------------------------------- screen (MediaProjection)

class AndroidScreenSource implements MediaSource {
  AndroidScreenSource({this.fps = 15, this.maxWidth = 960});
  final int fps, maxWidth;

  static const MethodChannel _method = MethodChannel('datv/screen');
  static const EventChannel _events = EventChannel('datv/screen/frames');

  StreamSubscription<dynamic>? _sub;

  /// Called when the user revokes the projection from the notification or the system.
  void Function(String message)? onFailure;

  @override
  String get label => 'Screen';

  @override
  Future<void> start(MediaSink sink) async {
    _sub = _events.receiveBroadcastStream().listen((ev) {
      final m = (ev as Map).cast<String, Object?>();
      final data = m['data'];
      if (data is Uint8List) {
        sink.video(RawFormat.rgba, data, m['w'] as int, m['h'] as int, m['stride'] as int, sink.nowUs());
      } else if (m['ended'] != null) {
        onFailure?.call(m['ended'] as String);
      }
    }, onError: (Object e) => onFailure?.call('$e'));
    try {
      await _method.invokeMethod<void>('start', {'maxWidth': maxWidth, 'fps': fps});
    } on PlatformException catch (e) {
      await _sub?.cancel();
      _sub = null;
      throw CaptureError(e.message ?? e.code);
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _method.invokeMethod<void>('stop');
    } on PlatformException catch (_) {}
    await _sub?.cancel();
    _sub = null;
  }
}
