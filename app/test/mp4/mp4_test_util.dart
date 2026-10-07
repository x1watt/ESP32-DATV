import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:esp32_datv/core/codec/mp4/mp4.dart';

/// Tiny big-endian byte writer for building synthetic MP4 boxes in tests.
class W {
  final BytesBuilder _b = BytesBuilder(copy: false);

  int get length => _b.length;

  void u8(int v) => _b.addByte(v & 0xFF);
  void u16(int v) {
    u8(v >> 8);
    u8(v);
  }

  void u24(int v) {
    u8(v >> 16);
    u8(v >> 8);
    u8(v);
  }

  void u32(int v) {
    u8(v >> 24);
    u8(v >> 16);
    u8(v >> 8);
    u8(v);
  }

  void u64(int v) {
    u32(v ~/ 4294967296);
    u32(v % 4294967296);
  }

  void i64(int v) {
    if (v < 0) {
      u32(0xFFFFFFFF);
      u32(v + 4294967296);
    } else {
      u64(v);
    }
  }

  void bytes(List<int> v) => _b.add(v);
  void str(String s) => _b.add(ascii.encode(s));
  void zeros(int n) => _b.add(Uint8List(n));

  Uint8List take() => _b.takeBytes();
}

Uint8List box(String type, List<List<int>> parts) {
  var len = 8;
  for (final p in parts) {
    len += p.length;
  }
  final w = W()
    ..u32(len)
    ..str(type);
  for (final p in parts) {
    w.bytes(p);
  }
  return w.take();
}

Uint8List fullBox(String type, int version, int flags, List<List<int>> parts) {
  final w = W()
    ..u8(version)
    ..u24(flags);
  return box(type, <List<int>>[w.take(), ...parts]);
}

Uint8List bytesOf(void Function(W w) f) {
  final w = W();
  f(w);
  return w.take();
}

Uint8List concat(List<List<int>> parts) {
  final b = BytesBuilder(copy: false);
  for (final p in parts) {
    b.add(p);
  }
  return b.takeBytes();
}

Uint8List ftyp() => box('ftyp', <List<int>>[
  bytesOf(
    (w) => w
      ..str('isom')
      ..u32(512)
      ..str('isom')
      ..str('iso2')
      ..str('avc1')
      ..str('mp41'),
  ),
]);

Uint8List mvhd(int timescale, int duration) => fullBox('mvhd', 0, 0, [
  bytesOf(
    (w) => w
      ..u32(0)
      ..u32(0)
      ..u32(timescale)
      ..u32(duration)
      ..u32(0x00010000)
      ..u16(0x0100)
      ..zeros(10)
      ..zeros(36)
      ..zeros(24)
      ..u32(3),
  ),
]);

Uint8List tkhd(int id, int w, int h) => fullBox('tkhd', 0, 3, [
  bytesOf(
    (x) => x
      ..u32(0)
      ..u32(0)
      ..u32(id)
      ..u32(0)
      ..u32(0)
      ..zeros(8)
      ..u16(0)
      ..u16(0)
      ..u16(0)
      ..u16(0)
      ..zeros(36)
      ..u32(w << 16)
      ..u32(h << 16),
  ),
]);

Uint8List mdhd(int timescale, int duration, {int version = 0}) =>
    fullBox('mdhd', version, 0, [
      bytesOf((w) {
        if (version == 1) {
          w
            ..u64(0)
            ..u64(0)
            ..u32(timescale)
            ..u64(duration);
        } else {
          w
            ..u32(0)
            ..u32(0)
            ..u32(timescale)
            ..u32(duration);
        }
        w
          ..u16(0x55C4) // 'und'
          ..u16(0);
      }),
    ]);

Uint8List hdlr(String type) => fullBox('hdlr', 0, 0, [
  bytesOf(
    (w) => w
      ..u32(0)
      ..str(type)
      ..zeros(12)
      ..str('h')
      ..u8(0),
  ),
]);

/// avcC with High profile 100, level 4.0, 4 byte lengths.
Uint8List avcC(Uint8List sps, Uint8List pps) => box('avcC', [
  bytesOf(
    (w) => w
      ..u8(1)
      ..u8(100)
      ..u8(0)
      ..u8(40)
      ..u8(0xFF)
      ..u8(0xE1)
      ..u16(sps.length)
      ..bytes(sps)
      ..u8(1)
      ..u16(pps.length)
      ..bytes(pps)
      ..u8(0xFD) // chroma 1
      ..u8(0xF8) // luma 8
      ..u8(0xF8) // chroma 8
      ..u8(0),
  ),
]);

Uint8List avc1Entry(int width, int height, Uint8List avcc) => box('avc1', [
  bytesOf(
    (w) => w
      ..zeros(6)
      ..u16(1)
      ..u16(0)
      ..u16(0)
      ..zeros(12)
      ..u16(width)
      ..u16(height)
      ..u32(0x00480000)
      ..u32(0x00480000)
      ..u32(0)
      ..u16(1)
      ..zeros(32)
      ..u16(0x18)
      ..u16(0xFFFF),
  ),
  avcc,
]);

/// Writes an MPEG-4 descriptor with a 4 byte (padded) length, as many muxers
/// do, to exercise the variable length parsing.
Uint8List descriptor(int tag, List<int> body) => bytesOf(
  (w) => w
    ..u8(tag)
    ..u8(0x80 | ((body.length >> 21) & 0x7F))
    ..u8(0x80 | ((body.length >> 14) & 0x7F))
    ..u8(0x80 | ((body.length >> 7) & 0x7F))
    ..u8(body.length & 0x7F)
    ..bytes(body),
);

Uint8List esds(List<int> asc, {int oti = 0x40}) {
  final dsi = descriptor(5, asc);
  final dcd = descriptor(
    4,
    concat([
      bytesOf(
        (w) => w
          ..u8(oti)
          ..u8(0x15)
          ..u24(0)
          ..u32(128000)
          ..u32(128000),
      ),
      dsi,
    ]),
  );
  final sl = descriptor(6, [2]);
  // ES_Descriptor with streamDependenceFlag and OCRstreamFlag set to test
  // flag handling.
  final es = descriptor(
    3,
    concat([
      bytesOf(
        (w) => w
          ..u16(1)
          ..u8(0xA0)
          ..u16(7)
          ..u16(9),
      ),
      dcd,
      sl,
    ]),
  );
  return fullBox('esds', 0, 0, [es]);
}

Uint8List mp4aEntry(int channels, int rate, List<int> asc) => box('mp4a', [
  bytesOf(
    (w) => w
      ..zeros(6)
      ..u16(1)
      ..u16(0)
      ..u16(0)
      ..u32(0)
      ..u16(channels)
      ..u16(16)
      ..u16(0)
      ..u16(0)
      ..u32(rate << 16),
  ),
  esds(asc),
]);

Uint8List stsd(Uint8List entry) =>
    fullBox('stsd', 0, 0, [bytesOf((w) => w.u32(1)), entry]);

Uint8List stts(List<(int, int)> entries) => fullBox('stts', 0, 0, [
  bytesOf((w) {
    w.u32(entries.length);
    for (final (c, d) in entries) {
      w
        ..u32(c)
        ..u32(d);
    }
  }),
]);

Uint8List ctts(int version, List<(int, int)> entries) =>
    fullBox('ctts', version, 0, [
      bytesOf((w) {
        w.u32(entries.length);
        for (final (c, o) in entries) {
          w
            ..u32(c)
            ..u32(o < 0 ? o + 4294967296 : o);
        }
      }),
    ]);

Uint8List stsc(List<(int, int)> entries) => fullBox('stsc', 0, 0, [
  bytesOf((w) {
    w.u32(entries.length);
    for (final (first, per) in entries) {
      w
        ..u32(first)
        ..u32(per)
        ..u32(1);
    }
  }),
]);

Uint8List stsz(List<int> sizes) => fullBox('stsz', 0, 0, [
  bytesOf((w) {
    w
      ..u32(0)
      ..u32(sizes.length);
    for (final s in sizes) {
      w.u32(s);
    }
  }),
]);

Uint8List stz2(List<int> sizes, int field) => fullBox('stz2', 0, 0, [
  bytesOf((w) {
    w
      ..u24(0)
      ..u8(field)
      ..u32(sizes.length);
    if (field == 4) {
      for (var i = 0; i < sizes.length; i += 2) {
        final hi = sizes[i];
        final lo = i + 1 < sizes.length ? sizes[i + 1] : 0;
        w.u8((hi << 4) | lo);
      }
    } else if (field == 8) {
      for (final s in sizes) {
        w.u8(s);
      }
    } else {
      for (final s in sizes) {
        w.u16(s);
      }
    }
  }),
]);

Uint8List stco(List<int> offsets, {bool co64 = false}) =>
    fullBox(co64 ? 'co64' : 'stco', 0, 0, [
      bytesOf((w) {
        w.u32(offsets.length);
        for (final o in offsets) {
          if (co64) {
            w.u64(o);
          } else {
            w.u32(o);
          }
        }
      }),
    ]);

Uint8List stss(List<int> oneBased) => fullBox('stss', 0, 0, [
  bytesOf((w) {
    w.u32(oneBased.length);
    for (final s in oneBased) {
      w.u32(s);
    }
  }),
]);

/// Edit list entries: (segment duration in movie ticks, media time).
Uint8List edts(int version, List<(int, int)> entries) => box('edts', [
  fullBox('elst', version, 0, [
    bytesOf((w) {
      w.u32(entries.length);
      for (final (d, t) in entries) {
        if (version == 1) {
          w
            ..u64(d)
            ..i64(t);
        } else {
          w
            ..u32(d)
            ..u32(t < 0 ? t + 4294967296 : t);
        }
        w
          ..u16(1)
          ..u16(0);
      }
    }),
  ]),
]);

Uint8List trak({
  required int id,
  required String handler,
  required int timescale,
  required int duration,
  required Uint8List entry,
  required List<Uint8List> stblTables,
  Uint8List? edit,
  int width = 0,
  int height = 0,
}) {
  return box('trak', [
    tkhd(id, width, height),
    ?edit,
    box('mdia', [
      mdhd(timescale, duration, version: id.isEven ? 1 : 0),
      hdlr(handler),
      box('minf', [
        box('dinf', [
          fullBox('dref', 0, 0, [
            bytesOf((w) => w.u32(1)),
            fullBox('url ', 0, 1, []),
          ]),
        ]),
        box('stbl', [stsd(entry), ...stblTables]),
      ]),
    ]),
  ]);
}

/// A [ByteSource] over a file, for tests only.
class FileByteSource implements ByteSource {
  FileByteSource(String path) : _f = File(path).openSync() {
    _len = _f.lengthSync();
  }

  final RandomAccessFile _f;
  late final int _len;
  int reads = 0;

  @override
  int get length => _len;

  @override
  Future<Uint8List> read(int offset, int length) async {
    reads++;
    var n = length;
    if (offset + n > _len) n = _len - offset;
    if (n <= 0) return Uint8List(0);
    _f.setPositionSync(offset);
    return _f.readSync(n);
  }

  void close() => _f.closeSync();
}

/// Wraps a source and counts reads.
class CountingSource implements ByteSource {
  CountingSource(this.inner);
  final ByteSource inner;
  int reads = 0;
  int bytes = 0;

  @override
  int get length => inner.length;

  @override
  Future<Uint8List> read(int offset, int length) async {
    reads++;
    final r = await inner.read(offset, length);
    bytes += r.length;
    return r;
  }
}

/// A sparse virtual file: zero bytes everywhere except the given segments.
class SparseSource implements ByteSource {
  SparseSource(this.length, this.segments);

  @override
  final int length;
  final Map<int, Uint8List> segments;

  @override
  Future<Uint8List> read(int offset, int len) async {
    var n = len;
    if (offset + n > length) n = length - offset;
    if (n <= 0) return Uint8List(0);
    final out = Uint8List(n);
    segments.forEach((start, data) {
      final s = start > offset ? start : offset;
      final e1 = start + data.length;
      final e2 = offset + n;
      final e = e1 < e2 ? e1 : e2;
      if (e > s) out.setRange(s - offset, e - offset, data, s - start);
    });
    return out;
  }
}

class ProbePacket {
  ProbePacket(this.ptsTime, this.dtsTime, this.size, this.pos, this.key);
  final double? ptsTime;
  final double? dtsTime;
  final int size;
  final int pos;
  final bool key;
}

bool toolExists(String name) {
  try {
    final r = Process.runSync(name, ['-version']);
    return r.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// Packets of one stream (`v` or `a`) as reported by ffprobe.
List<ProbePacket> ffprobePackets(String path, String stream) {
  final r = Process.runSync('ffprobe', [
    '-v',
    'error',
    '-select_streams',
    stream,
    '-show_entries',
    'packet=pts_time,dts_time,size,pos,flags',
    '-of',
    'csv=p=0',
    path,
  ]);
  if (r.exitCode != 0) throw StateError('ffprobe failed: ${r.stderr}');
  final out = <ProbePacket>[];
  for (final line in (r.stdout as String).split('\n')) {
    final l = line.trim();
    if (l.isEmpty) continue;
    final f = l.split(',');
    out.add(
      ProbePacket(
        double.tryParse(f[0]),
        double.tryParse(f[1]),
        int.parse(f[2]),
        int.tryParse(f[3]) ?? -1,
        f[4].contains('K'),
      ),
    );
  }
  return out;
}
