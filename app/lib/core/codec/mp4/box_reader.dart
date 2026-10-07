import 'dart:typed_data';

import 'mp4_exception.dart';

/// 2^32 as an int, used to combine 64-bit values without ByteData.getUint64
/// (which is not supported when compiling to JavaScript).
const int _two32 = 4294967296;

/// A box header located inside an in-memory buffer.
class BoxHeader {
  const BoxHeader(this.type, this.start, this.headerSize, this.end);

  /// Four character code, for example 'moov'.
  final String type;

  /// Offset of the first byte of the box (its size field) in the buffer.
  final int start;

  /// 8, or 16 when a 64-bit largesize is used (plus 16 for 'uuid' boxes).
  final int headerSize;

  /// Offset one past the last byte of the box in the buffer.
  final int end;

  /// Offset of the payload.
  int get body => start + headerSize;

  int get payloadSize => end - body;
}

String fourcc(Uint8List b, int o) =>
    String.fromCharCodes(<int>[b[o], b[o + 1], b[o + 2], b[o + 3]]);

int readU16(Uint8List b, int o) => (b[o] << 8) | b[o + 1];

int readU24(Uint8List b, int o) => (b[o] << 16) | (b[o + 1] << 8) | b[o + 2];

int readU32(Uint8List b, int o) =>
    ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]) & 0xFFFFFFFF;

int readI32(Uint8List b, int o) {
  final v = readU32(b, o);
  return v >= 0x80000000 ? v - _two32 : v;
}

int readI16(Uint8List b, int o) {
  final v = readU16(b, o);
  return v >= 0x8000 ? v - 0x10000 : v;
}

/// Unsigned 64-bit read. Exact up to 2^53 on the web.
int readU64(Uint8List b, int o) => readU32(b, o) * _two32 + readU32(b, o + 4);

/// Signed 64-bit read. Exact within +-2^53 on the web.
int readI64(Uint8List b, int o) {
  final hi = readU32(b, o);
  final lo = readU32(b, o + 4);
  if (hi >= 0x80000000) return (hi - _two32) * _two32 + lo;
  return hi * _two32 + lo;
}

/// Iterates over the child boxes in `b[start, end)`. Stops quietly at a
/// truncated or garbage header; a child that claims to extend past [end] is
/// clamped to [end].
Iterable<BoxHeader> childBoxes(Uint8List b, int start, int end) sync* {
  var o = start;
  if (end > b.length) end = b.length;
  while (o + 8 <= end) {
    var size = readU32(b, o);
    final type = fourcc(b, o + 4);
    var hdr = 8;
    if (size == 1) {
      if (o + 16 > end) return;
      size = readU64(b, o + 8);
      hdr = 16;
    } else if (size == 0) {
      size = end - o;
    }
    if (type == 'uuid') hdr += 16;
    if (size < hdr) return;
    var boxEnd = o + size;
    if (boxEnd > end) boxEnd = end;
    if (o + hdr > boxEnd) return;
    yield BoxHeader(type, o, hdr, boxEnd);
    o += size;
  }
}

/// First child box of [type] in `b[start, end)`, or null.
BoxHeader? findChild(Uint8List b, int start, int end, String type) {
  for (final h in childBoxes(b, start, end)) {
    if (h.type == type) return h;
  }
  return null;
}

/// Follows a path of nested box types starting inside [parent].
BoxHeader? findPath(Uint8List b, BoxHeader parent, List<String> path) {
  BoxHeader? cur = parent;
  for (final t in path) {
    if (cur == null) return null;
    cur = findChild(b, cur.body, cur.end, t);
  }
  return cur;
}

/// Throws [Mp4FormatException] if `need` bytes are not available at [o]
/// within a box ending at [end].
void ensure(int o, int need, int end, String what) {
  if (o + need > end) {
    throw Mp4FormatException('$what box is truncated');
  }
}

/// Converts [ticks] in [timescale] units to microseconds, rounding toward
/// negative infinity. Avoids intermediate products above 2^53 so it is exact
/// on the web too (as long as the result itself fits).
int mp4TicksToUs(int ticks, int timescale) {
  if (timescale <= 0) return 0;
  final r = ticks % timescale; // always non-negative in Dart
  final q = (ticks - r) ~/ timescale;
  return q * 1000000 + (r * 1000000) ~/ timescale;
}
