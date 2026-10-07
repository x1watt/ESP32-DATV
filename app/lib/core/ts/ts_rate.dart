import 'dart:typed_data';

/// Bit rate of a constant-rate transport stream, measured from the PCRs of its first PCR PID
/// (bytes between the first and the last PCR in [data] over their time difference).
/// Returns null when there are fewer than two PCRs.
double? measureTsRate(Uint8List data) {
  int? pid, firstOff, firstPcr, lastOff, lastPcr;
  for (var o = 0; o + 188 <= data.length; o += 188) {
    if (data[o] != 0x47) {
      // resync on the next sync byte
      final n = data.indexOf(0x47, o + 1);
      if (n < 0) break;
      o = n - 188;
      continue;
    }
    final afc = (data[o + 3] >> 4) & 3;
    if (afc < 2 || data[o + 4] < 7 || (data[o + 5] & 0x10) == 0) continue;
    final p = ((data[o + 1] & 0x1F) << 8) | data[o + 2];
    pid ??= p;
    if (p != pid) continue;
    final b = data;
    final base = (b[o + 6] << 25) | (b[o + 7] << 17) | (b[o + 8] << 9) | (b[o + 9] << 1) | (b[o + 10] >> 7);
    final ext = ((b[o + 10] & 1) << 8) | b[o + 11];
    final pcr = base * 300 + ext;
    if (firstPcr == null) {
      firstPcr = pcr;
      firstOff = o;
    } else if (pcr > firstPcr) {
      lastPcr = pcr;
      lastOff = o;
    }
  }
  if (firstPcr == null || lastPcr == null) return null;
  return (lastOff! - firstOff!) * 8 / ((lastPcr - firstPcr) / 27e6);
}
