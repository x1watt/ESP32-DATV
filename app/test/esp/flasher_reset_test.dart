import 'dart:typed_data';

import 'package:esp32_datv/core/esp/flasher.dart';
import 'package:esp32_datv/core/esp/transport.dart';
import 'package:test/test.dart';

/// A simulated ESP32-C3 behind its USB-Serial-JTAG port, as esptool's comments describe it:
/// DTR=1 RTS=0 requests download mode, DTR=0 RTS=0 drops the request, DTR=0 RTS=1 holds the
/// chip in reset, and leaving reset starts the ROM loader if download mode was requested.
/// The download request is sampled when the chip leaves reset.
/// With [windows], an RTS change alone does not reach the device (usbser.sys sends the line
/// state only when DTR is written), and like WindowsSerialTransport the host writes DTR again
/// after every RTS change.
class SimChip implements ByteTransport {
  SimChip({this.windows = false, this.inRom = false});

  final bool windows;
  bool inRom;
  bool _dtr = false, _rts = false; // host side
  bool _seenDtr = false, _seenRts = false; // device side
  bool _download = false, _inReset = false;
  int signalWrites = 0;
  final List<int> _out = [];
  final SlipDecoder _slip = SlipDecoder();

  void _deliver() {
    _seenDtr = _dtr;
    _seenRts = _rts;
    if (_seenRts && !_seenDtr) {
      _inReset = true;
    } else if (_inReset && !_seenRts) {
      _inReset = false;
      inRom = _download;
    }
    if (_seenDtr && !_seenRts) _download = true;
    if (!_seenDtr && !_seenRts) _download = false;
  }

  @override
  Future<void> setSignals({bool? dtr, bool? rts}) async {
    signalWrites++;
    if (!windows) {
      // termios TIOCMSET: both lines change together
      if (dtr != null) _dtr = dtr;
      if (rts != null) _rts = rts;
      _deliver();
      return;
    }
    // WindowsSerialTransport: DTR first, then RTS followed by a DTR write
    if (dtr != null) {
      _dtr = dtr;
      _deliver();
    }
    if (rts != null) {
      _rts = rts;
      _deliver();
    }
  }

  @override
  Future<void> write(Uint8List data, {Duration timeout = const Duration(seconds: 2)}) async {
    for (final f in _slip.add(data)) {
      if (!inRom || _inReset || f.length < 8) continue;
      final op = f[1];
      final resp = Uint8List(8 + 4);
      resp[0] = 1;
      resp[1] = op;
      resp[2] = 4;
      if (op == 0x0A) {
        ByteData.sublistView(resp).setUint32(4, esp32c3Magic.first, Endian.little);
      }
      _out.addAll(slipEncode(resp));
    }
  }

  @override
  Future<Uint8List> read({Duration timeout = Duration.zero}) async {
    final r = Uint8List.fromList(_out);
    _out.clear();
    return r;
  }

  @override
  Future<void> flushInput() async => _out.clear();

  @override
  Future<void> close() async {}
}

void main() {
  for (final windows in [false, true]) {
    test('reset into the ROM loader works (${windows ? 'Windows' : 'Linux'} line semantics)', () async {
      final chip = SimChip(windows: windows);
      final magic = await EspFlasher(chip).connect();
      expect(esp32c3Magic, contains(magic));
      expect(chip.inRom, isTrue);
    });
  }

  test('the old sequence (both lines per call, DTR first) fails on Windows', () async {
    final chip = SimChip(windows: true);
    await chip.setSignals(dtr: false, rts: false);
    await chip.setSignals(dtr: true, rts: false);
    await chip.setSignals(dtr: false, rts: true);
    await chip.setSignals(dtr: false, rts: false);
    expect(chip.inRom, isFalse);
  });

  test('a board already in download mode is not reset', () async {
    final chip = SimChip(windows: true, inRom: true);
    await EspFlasher(chip).connect();
    expect(chip.signalWrites, 0);
  });
}
