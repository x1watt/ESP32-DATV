import 'dart:typed_data';

final Uint32List _tab = () {
  final t = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    t[i] = c;
  }
  return t;
}();

/// CRC-32 as zlib / esp_rom_crc32_le compute it (reflected 0x04C11DB7, init and xorout 0xFFFFFFFF).
int crc32Zlib(Uint8List d, [int start = 0, int? end]) {
  var c = 0xFFFFFFFF;
  for (var i = start; i < (end ?? d.length); i++) {
    c = _tab[(c ^ d[i]) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}
