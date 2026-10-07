import 'dart:typed_data';

final Uint32List _tab = () {
  final t = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var c = i << 24;
    for (var k = 0; k < 8; k++) {
      c = (c & 0x80000000) != 0 ? ((c << 1) ^ 0x04C11DB7) : (c << 1);
      c &= 0xFFFFFFFF;
    }
    t[i] = c;
  }
  return t;
}();

/// CRC-32/MPEG-2 (PSI sections).
int crc32Mpeg(Uint8List data) {
  var c = 0xFFFFFFFF;
  for (final b in data) {
    c = ((c << 8) & 0xFFFFFFFF) ^ _tab[((c >> 24) ^ b) & 0xFF];
  }
  return c;
}
