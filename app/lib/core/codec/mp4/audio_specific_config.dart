import 'dart:typed_data';

import 'mp4_exception.dart';

/// Minimal MPEG-4 AudioSpecificConfig parser (ISO 14496-3 1.6.2.1).
class AudioSpecificConfig {
  AudioSpecificConfig({
    required this.audioObjectType,
    required this.samplingFrequencyIndex,
    required this.sampleRate,
    required this.channelConfiguration,
    this.extensionAudioObjectType,
    this.extensionSampleRate,
    this.frameLengthFlag = false,
  });

  /// Signalled audio object type (2 = AAC LC, 5 = SBR, 29 = PS, ...).
  final int audioObjectType;
  final int samplingFrequencyIndex;

  /// Core sampling rate in Hz.
  final int sampleRate;

  /// channelConfiguration field (0 means defined in a program config element).
  final int channelConfiguration;

  /// For explicit SBR/PS signalling (AOT 5 or 29): the underlying core AOT.
  final int? extensionAudioObjectType;

  /// For explicit SBR/PS signalling: the output (SBR) sampling rate.
  final int? extensionSampleRate;

  /// GASpecificConfig frameLengthFlag (true means 960 sample frames).
  final bool frameLengthFlag;

  /// Number of output channels implied by [channelConfiguration], or 0 when
  /// unknown.
  int get channels => channelsForConfig(channelConfiguration);

  static const List<int> sampleRates = <int>[
    96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, //
    16000, 12000, 11025, 8000, 7350,
  ];

  static int channelsForConfig(int c) {
    if (c >= 1 && c <= 6) return c;
    if (c == 7) return 8;
    if (c == 11) return 7;
    if (c == 12 || c == 14) return 8;
    if (c == 13) return 24;
    return 0;
  }

  static AudioSpecificConfig parse(Uint8List data) {
    final r = _Bits(data);
    try {
      int readAot() {
        final a = r.read(5);
        return a == 31 ? 32 + r.read(6) : a;
      }

      int readRate(void Function(int) setIndex) {
        final idx = r.read(4);
        setIndex(idx);
        if (idx == 15) return r.read(24);
        return idx < sampleRates.length ? sampleRates[idx] : 0;
      }

      var aot = readAot();
      var freqIndex = 0;
      final rate = readRate((i) => freqIndex = i);
      final chan = r.read(4);
      int? extAot;
      int? extRate;
      if (aot == 5 || aot == 29) {
        extRate = readRate((_) {});
        extAot = readAot();
      }
      final core = extAot ?? aot;
      var frameLength = false;
      const ga = <int>{1, 2, 3, 4, 6, 7, 17, 19, 20, 21, 22, 23};
      if (ga.contains(core) && r.remaining >= 1) {
        frameLength = r.read(1) == 1;
      }
      return AudioSpecificConfig(
        audioObjectType: aot,
        samplingFrequencyIndex: freqIndex,
        sampleRate: rate,
        channelConfiguration: chan,
        extensionAudioObjectType: extAot,
        extensionSampleRate: extRate,
        frameLengthFlag: frameLength,
      );
    } on RangeError {
      throw const Mp4FormatException('AudioSpecificConfig truncated');
    }
  }
}

class _Bits {
  _Bits(this._d);
  final Uint8List _d;
  int _pos = 0;

  int get remaining => _d.length * 8 - _pos;

  int read(int n) {
    if (n > remaining) throw RangeError('out of bits');
    var v = 0;
    for (var i = 0; i < n; i++) {
      final byte = _d[_pos >> 3];
      v = (v << 1) | ((byte >> (7 - (_pos & 7))) & 1);
      _pos++;
    }
    return v;
  }
}
