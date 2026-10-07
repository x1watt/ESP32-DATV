/// Entry point for live capture: lists devices and creates [MediaSource]s for the current
/// platform.
///
///   Linux:   camera V4L2, screen X11 (MIT-SHM), microphone PulseAudio/PipeWire (dart:ffi)
///   Windows: camera Media Foundation, screen GDI, microphone waveIn (dart:ffi)
///   Android: camera and microphone through the camera/record plugins, screen through
///            MediaProjection (Kotlin, ScreenCaptureChannel.kt)
///
/// Blocking native loops run in their own isolates (see isolate_capture.dart).
library;

import 'dart:io';

import 'android_capture.dart';
import 'linux_pulse.dart';
import 'linux_v4l2.dart';
import 'linux_x11.dart';
import 'media_source.dart';
import 'windows_gdi.dart';
import 'windows_mf.dart';
import 'windows_wavein.dart';

export 'media_source.dart';

bool get _linux => Platform.isLinux;
bool get _windows => Platform.isWindows;
bool get _android => Platform.isAndroid;

bool get supportsCameraCapture => _linux || _windows || _android;
bool get supportsMicrophoneCapture => _linux || _windows || _android;
bool get supportsScreenCapture => screenCaptureUnavailableReason == null;

/// Why screen capture cannot work here, or null when it can.
String? get screenCaptureUnavailableReason {
  if (_linux) return x11Unsupported();
  if (_windows || _android) return null;
  return 'Screen capture is not supported on ${Platform.operatingSystem}';
}

CaptureError _unsupported(String what) => CaptureError('$what capture is not supported on ${Platform.operatingSystem}');

Future<List<CaptureDevice>> listCameras() async {
  if (_linux) return listV4l2Cameras();
  if (_windows) return listMfCameras();
  if (_android) return listAndroidCameras();
  return const [];
}

/// Screens/monitors. Empty when screen capture is unavailable (see
/// [screenCaptureUnavailableReason]). Android has a single entry: the projection asks the
/// user what to share.
Future<List<CaptureDevice>> listScreens() async {
  if (!supportsScreenCapture) return const [];
  if (_linux) return listX11Screens();
  if (_windows) return listGdiScreens();
  if (_android) return const [CaptureDevice('screen', 'Screen')];
  return const [];
}

Future<List<CaptureDevice>> listMicrophones() async {
  if (_linux) return listPulseSources();
  if (_windows) return listWaveInDevices();
  if (_android) return listRecordMicrophones();
  return const [];
}

/// A camera at the largest mode not wider than [maxWidth] that reaches [fps].
MediaSource cameraSource(CaptureDevice d, {int maxWidth = 1280, int fps = 25}) {
  if (_linux) return v4l2CameraSource(d, maxWidth: maxWidth, fps: fps);
  if (_windows) return mfCameraSource(d, maxWidth: maxWidth, fps: fps);
  if (_android) return AndroidCameraSource(d, maxWidth: maxWidth, fps: fps);
  throw _unsupported('Camera');
}

/// The screen area [d] at [fps]. Pictures wider than twice [maxWidth] are halved at the
/// source (desktop) or scaled to [maxWidth] (Android), so big desktops do not flood the
/// UI isolate; the encoder scales the rest of the way.
MediaSource screenSource(CaptureDevice d, {int fps = 15, int maxWidth = 1280}) {
  final why = screenCaptureUnavailableReason;
  if (why != null) throw CaptureError(why);
  if (_linux) return x11ScreenSource(d, fps: fps, maxWidth: maxWidth);
  if (_windows) return gdiScreenSource(d, fps: fps, maxWidth: maxWidth);
  if (_android) return AndroidScreenSource(fps: fps, maxWidth: maxWidth < 960 ? maxWidth : 960);
  throw _unsupported('Screen');
}

/// 16-bit PCM in 20 ms blocks.
MediaSource micSource(CaptureDevice d, {int sampleRate = 48000, int channels = 1}) {
  if (_linux) return pulseMicSource(d, sampleRate: sampleRate, channels: channels);
  if (_windows) return waveInMicSource(d, sampleRate: sampleRate, channels: channels);
  if (_android) return RecordMicSource(d, sampleRate: sampleRate, channels: channels);
  throw _unsupported('Microphone');
}
