import 'dart:typed_data';

/// TS null packet (PID 0x1FFF), as in `host/dvbs.py`.
final Uint8List nullPacket = () {
  final p = Uint8List(188)..fillRange(4, 188, 0xFF);
  p[0] = 0x47;
  p[1] = 0x1F;
  p[2] = 0xFF;
  p[3] = 0x10;
  return p;
}();
