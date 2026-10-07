import 'dart:typed_data';

import 'mp4_exception.dart';

/// Parsed AVCDecoderConfigurationRecord (the payload of an 'avcC' box).
class AvcConfig {
  AvcConfig({
    required this.configurationVersion,
    required this.profileIdc,
    required this.profileCompat,
    required this.levelIdc,
    required this.nalLengthSize,
    required this.sps,
    required this.pps,
    required this.raw,
    this.chromaFormat,
    this.bitDepthLuma,
    this.bitDepthChroma,
    this.spsExt = const <Uint8List>[],
  });

  final int configurationVersion;
  final int profileIdc;
  final int profileCompat;
  final int levelIdc;

  /// Size in bytes of the NAL unit length prefix: 1, 2 or 4.
  final int nalLengthSize;

  /// Sequence parameter sets, raw NAL units without start codes.
  final List<Uint8List> sps;

  /// Picture parameter sets, raw NAL units without start codes.
  final List<Uint8List> pps;

  /// The complete avcC payload.
  final Uint8List raw;

  /// High profile extension: chroma_format_idc (0..3), when present.
  final int? chromaFormat;

  /// High profile extension: luma bit depth (8 + bit_depth_luma_minus8).
  final int? bitDepthLuma;

  /// High profile extension: chroma bit depth (8 + bit_depth_chroma_minus8).
  final int? bitDepthChroma;

  /// High profile extension: SPS extension NAL units.
  final List<Uint8List> spsExt;

  /// RFC 6381 style codec string, for example 'avc1.640028'.
  String codecString([String entry = 'avc1']) =>
      '$entry.${_hex2(profileIdc)}${_hex2(profileCompat)}${_hex2(levelIdc)}';

  static String _hex2(int v) => v.toRadixString(16).padLeft(2, '0');

  /// Parses an avcC payload. Copies [raw] so the result does not keep a large
  /// parent buffer alive.
  static AvcConfig parse(Uint8List raw) {
    final b = Uint8List.fromList(raw);
    if (b.length < 7) throw const Mp4FormatException('avcC too short');
    final version = b[0];
    final profile = b[1];
    final compat = b[2];
    final level = b[3];
    final lengthSize = (b[4] & 3) + 1;
    if (lengthSize == 3) {
      throw const Mp4FormatException('avcC has invalid NAL length size 3');
    }
    var o = 5;
    List<Uint8List> readSets(int count) {
      final out = <Uint8List>[];
      for (var i = 0; i < count; i++) {
        if (o + 2 > b.length) throw const Mp4FormatException('avcC truncated');
        final len = (b[o] << 8) | b[o + 1];
        o += 2;
        if (o + len > b.length) {
          throw const Mp4FormatException('avcC truncated');
        }
        out.add(Uint8List.sublistView(b, o, o + len));
        o += len;
      }
      return out;
    }

    final sps = readSets(b[o++] & 0x1F);
    if (o >= b.length) throw const Mp4FormatException('avcC truncated');
    final pps = readSets(b[o++]);
    int? chroma;
    int? depthL;
    int? depthC;
    var spsExt = const <Uint8List>[];
    const highProfiles = <int>{100, 110, 122, 144};
    if (highProfiles.contains(profile) && o + 4 <= b.length) {
      chroma = b[o] & 3;
      depthL = (b[o + 1] & 7) + 8;
      depthC = (b[o + 2] & 7) + 8;
      final n = b[o + 3];
      o += 4;
      try {
        spsExt = readSets(n);
      } on Mp4FormatException {
        spsExt = const <Uint8List>[];
      }
    }
    return AvcConfig(
      configurationVersion: version,
      profileIdc: profile,
      profileCompat: compat,
      levelIdc: level,
      nalLengthSize: lengthSize,
      sps: sps,
      pps: pps,
      raw: b,
      chromaFormat: chroma,
      bitDepthLuma: depthL,
      bitDepthChroma: depthC,
      spsExt: spsExt,
    );
  }
}
