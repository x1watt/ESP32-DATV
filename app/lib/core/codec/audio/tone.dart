// Phase continuous sine tone generator producing PcmBlock buffers.

import 'dart:math' as math;
import 'dart:typed_data';

import '../frame.dart';

/// Generates a sine test tone (for example 800 Hz) at any sample rate.
/// Consecutive calls to [next] continue the phase and the timestamps.
class ToneGenerator {
  /// [amplitude] is linear peak level relative to full scale (0..1);
  /// the default 0.25 is about -12 dBFS.
  ToneGenerator({
    required this.sampleRate,
    this.channels = 1,
    this.frequencyHz = 800.0,
    this.amplitude = 0.25,
    this.startPtsUs = 0,
  }) {
    if (sampleRate <= 0) throw ArgumentError.value(sampleRate, 'sampleRate');
    if (channels < 1) throw ArgumentError.value(channels, 'channels');
  }

  final int sampleRate;
  final int channels;
  final double frequencyHz;
  final double amplitude;
  final int startPtsUs;

  int _generated = 0;

  /// Total frames (samples per channel) generated so far.
  int get framesGenerated => _generated;

  /// Returns the next [frames] samples per channel. All channels carry the
  /// same signal. ptsUs is derived from the running sample count.
  PcmBlock next(int frames) {
    final out = Int16List(frames * channels);
    final w = 2 * math.pi * frequencyHz / sampleRate;
    final a = (amplitude.clamp(0.0, 1.0)) * 32767.0;
    final pts = startPtsUs + (_generated * 1000000) ~/ sampleRate;
    // Phase is computed from the absolute sample index, wrapped every 1000
    // seconds of samples (a whole number of cycles for any frequency given
    // with up to three decimals), so long runs do not lose precision.
    for (var i = 0; i < frames; i++) {
      final n = _generated + i;
      final v = (a * math.sin(w * (n % (sampleRate * 1000)))).round();
      for (var c = 0; c < channels; c++) {
        out[i * channels + c] = v;
      }
    }
    _generated += frames;
    return PcmBlock(out, sampleRate, channels, ptsUs: pts);
  }
}
