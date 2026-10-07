/// Pure Dart H.264 (Constrained Baseline, CAVLC) video encoder.
///
/// Produces Annex B access units (AUD, SPS and PPS before every IDR, one
/// slice per picture) under a constant bitrate with a VBV buffer guarantee.
library;

import 'dart:typed_data';

import '../frame.dart';
import 'src/encoder_core.dart';

/// Speed / quality trade-off.
enum H264Preset {
  /// Integer + half sample search, no Intra 4x4 in P frames.
  fast,

  /// Quarter sample search and Intra 4x4 everywhere.
  medium,
}

class H264EncoderConfig {
  H264EncoderConfig({
    required this.width,
    required this.height,
    required this.fps,
    required this.bitrate,
    int? gopFrames,
    int? vbvBits,
    this.qpMin = 10,
    this.qpMax = 51,
    this.preset = H264Preset.medium,
    this.vui = true,
  })  : gopFrames = gopFrames ?? 2 * fps,
        vbvBits = vbvBits ?? bitrate ~/ 2 {
    if (width <= 0 || height <= 0 || width.isOdd || height.isOdd) {
      throw ArgumentError('width and height must be positive and even');
    }
    if (fps <= 0 || bitrate <= 0) {
      throw ArgumentError('fps and bitrate must be positive');
    }
  }

  /// Picture size in luma samples (even).
  final int width, height;

  /// Frames per second (integer).
  final int fps;

  /// Target bitrate in bits per second (whole access units, start codes
  /// included).
  final int bitrate;

  /// Distance between IDR pictures in frames.
  int gopFrames;

  /// Size of the rate control buffer in bits. Each access unit is admitted
  /// only if it fits: fill + size <= vbvBits, where fill drains by
  /// bitrate / fps per frame.
  int vbvBits;

  int qpMin;
  int qpMax;
  H264Preset preset;

  /// Emit VUI (timing info, colour description, bitstream restriction).
  bool vui;
}

/// One coded access unit.
class H264Frame {
  H264Frame(this.data, this.keyframe, this.ptsUs, this.qp);

  /// Annex B byte stream of the whole access unit.
  final Uint8List data;

  /// True for IDR access units (they carry SPS and PPS).
  final bool keyframe;
  final int ptsUs;

  /// Average luma QP of the coded macroblocks.
  final int qp;
}

class H264Encoder {
  H264Encoder(this.config) : _core = EncoderCore(config);

  final H264EncoderConfig config;
  final EncoderCore _core;

  /// Encodes one picture. Width and height must match the configuration.
  H264Frame encode(I420Frame f, {bool forceIdr = false}) {
    if (f.width != config.width || f.height != config.height) {
      throw ArgumentError('frame size ${f.width}x${f.height} does not match '
          'encoder ${config.width}x${config.height}');
    }
    return _core.encode(f, forceIdr);
  }

  /// Encoder buffer occupancy in bits after the last frame.
  double get vbvFill => _core.rc.fill;

  /// Highest buffer occupancy reached right after adding a frame.
  double get vbvPeak => _core.rc.peakFill;

  /// Number of VBV violations (only possible when even a minimal frame does
  /// not fit, e.g. an absurdly small buffer).
  int get vbvViolations => _core.vbvViolations;

  /// level_idc written in the SPS.
  int get levelIdc => _core.levelIdc;

  /// The decoded picture of the last frame (cropped), exactly as a
  /// conforming decoder reconstructs it. Intended for tests.
  I420Frame reconstruction() => _core.reconstruction();
}
