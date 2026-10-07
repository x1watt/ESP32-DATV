import 'dart:typed_data';

/// A planar YUV 4:2:0 picture (BT.601 limited range), tightly packed:
/// Y is width*height, U and V are (width/2)*(height/2). Width and height are even.
class I420Frame {
  I420Frame(this.width, this.height, this.y, this.u, this.v, {this.ptsUs = 0});

  factory I420Frame.alloc(int width, int height, {int ptsUs = 0}) => I420Frame(
        width,
        height,
        Uint8List(width * height),
        Uint8List((width >> 1) * (height >> 1)),
        Uint8List((width >> 1) * (height >> 1)),
        ptsUs: ptsUs,
      );

  final int width;
  final int height;
  final Uint8List y;
  final Uint8List u;
  final Uint8List v;

  /// Presentation time in microseconds.
  int ptsUs;
}

/// Interleaved signed 16-bit PCM.
class PcmBlock {
  PcmBlock(this.samples, this.sampleRate, this.channels, {this.ptsUs = 0});

  final Int16List samples;
  final int sampleRate;
  final int channels;
  int ptsUs;

  int get frames => samples.length ~/ channels;
}
