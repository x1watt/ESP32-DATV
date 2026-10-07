import 'dart:typed_data';

/// Random access byte source for the MP4 demuxer.
///
/// Implementations may be backed by memory, a file, a web Blob, HTTP range
/// requests and so on. [read] must return at most [length] bytes; it returns
/// fewer bytes only when the range crosses the end of the source.
abstract class ByteSource {
  /// Total size in bytes.
  int get length;

  /// Reads [length] bytes starting at [offset]. The result is clamped at the
  /// end of the source (and is empty when [offset] is at or past the end).
  Future<Uint8List> read(int offset, int length);
}

/// A [ByteSource] over an in-memory buffer. Reads return views, not copies.
class MemoryByteSource implements ByteSource {
  MemoryByteSource(Uint8List bytes) : _bytes = bytes;

  final Uint8List _bytes;

  @override
  int get length => _bytes.length;

  @override
  Future<Uint8List> read(int offset, int length) {
    return Future<Uint8List>.value(readSync(offset, length));
  }

  /// Synchronous variant of [read].
  Uint8List readSync(int offset, int length) {
    final total = _bytes.length;
    var start = offset < 0 ? 0 : offset;
    if (start > total) start = total;
    var end = offset + (length < 0 ? 0 : length);
    if (end > total) end = total;
    if (end < start) end = start;
    return Uint8List.sublistView(_bytes, start, end);
  }
}
