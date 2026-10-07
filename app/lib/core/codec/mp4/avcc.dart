import 'dart:typed_data';

import 'avc_config.dart';

export 'mp4_exception.dart';

/// Splits an AVCC (length prefixed) sample into NAL units. Returns views into
/// [sample]. Stops without throwing at a truncated or nonsensical length.
/// Zero length NAL units are skipped.
List<Uint8List> splitLengthPrefixedNals(Uint8List sample, int nalLengthSize) {
  final out = <Uint8List>[];
  if (nalLengthSize < 1 || nalLengthSize > 4) return out;
  final n = sample.length;
  var o = 0;
  while (o + nalLengthSize <= n) {
    var len = 0;
    for (var i = 0; i < nalLengthSize; i++) {
      len = (len << 8) | sample[o + i];
    }
    o += nalLengthSize;
    if (len > n - o) break;
    if (len > 0) out.add(Uint8List.sublistView(sample, o, o + len));
    o += len;
  }
  return out;
}

/// Converts an AVCC sample into Annex B with 4 byte start codes. NAL units in
/// [prepend] (for example SPS and PPS before a keyframe) are emitted first.
Uint8List avccToAnnexB(
  Uint8List sample,
  int nalLengthSize, {
  List<Uint8List>? prepend,
}) {
  final nals = <Uint8List>[
    ...?prepend,
    ...splitLengthPrefixedNals(sample, nalLengthSize),
  ];
  return _joinWithStartCodes(nals);
}

/// All SPS and PPS of [c] (SPS first) with 4 byte start codes.
Uint8List avcConfigToAnnexB(AvcConfig c) =>
    _joinWithStartCodes(<Uint8List>[...c.sps, ...c.pps]);

Uint8List _joinWithStartCodes(List<Uint8List> nals) {
  var total = 0;
  for (final n in nals) {
    total += 4 + n.length;
  }
  final out = Uint8List(total);
  var o = 0;
  for (final n in nals) {
    out[o + 3] = 1;
    o += 4;
    out.setRange(o, o + n.length, n);
    o += n.length;
  }
  return out;
}
