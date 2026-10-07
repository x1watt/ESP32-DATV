import 'dart:io';
import 'dart:typed_data';

import '../../core/codec/mp4/byte_source.dart';

/// Random access to a local file for the MP4 demuxer.
class FileByteSource implements ByteSource {
  FileByteSource._(this._f, this.length);

  static FileByteSource open(String path) {
    final f = File(path).openSync();
    return FileByteSource._(f, f.lengthSync());
  }

  final RandomAccessFile _f;
  @override
  final int length;

  @override
  Future<Uint8List> read(int offset, int length) async {
    _f.setPositionSync(offset);
    return _f.readSync(length);
  }

  void close() => _f.closeSync();
}
