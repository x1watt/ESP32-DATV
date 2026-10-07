import 'dart:typed_data';

import '../../engine/encoder_isolate.dart' show RawFormat;

export '../../engine/encoder_isolate.dart' show RawFormat;

/// Where capture sources deliver raw media. Timestamps are microseconds on [nowUs]'s clock.
/// [video] drops the picture when the encoder is still busy, so sources may push freely.
abstract class MediaSink {
  /// Monotonic clock shared by all sources of one transmission.
  int nowUs();

  /// One picture. For packed formats [stride] is bytes per row; for i420 the planes are
  /// tightly packed (Y, then U, then V) and [stride] is ignored.
  void video(RawFormat fmt, Uint8List data, int width, int height, int stride, int ptsUs);

  /// Interleaved signed 16-bit PCM.
  void audio(Int16List pcm, int sampleRate, int channels, int ptsUs);
}

/// A live capture source (camera, screen, microphone).
abstract class MediaSource {
  String get label;

  /// Starts delivering into [sink]. Throws a [CaptureError] with a readable message when
  /// the device or permission is not available.
  Future<void> start(MediaSink sink);

  Future<void> stop();
}

class CaptureError implements Exception {
  CaptureError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A selectable device (camera, screen/monitor, microphone).
class CaptureDevice {
  const CaptureDevice(this.id, this.name);
  final String id;
  final String name;
}
