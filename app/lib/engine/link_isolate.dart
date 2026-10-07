/// The link isolate: owns the USB port. It identifies the firmware, flashes, and while
/// transmitting runs mux -> DVB encoder -> pacer, fed with encoded media from other isolates.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../core/dvb/dvbs.dart';
import '../core/dvb/dvbs2.dart';
import '../core/dvb/ts_const.dart';
import '../core/esp/esp_link.dart';
import '../core/esp/flasher.dart';
import '../core/esp/transport.dart';
import '../core/esp/tx_config.dart';
import '../core/pipeline/pacer.dart';
import '../core/ts/mux.dart';
import '../core/ts/ts_rate.dart';
import 'transport_factory.dart';

/// Arguments for [linkIsolateMain].
class LinkIsolateArgs {
  LinkIsolateArgs(this.events, this.port);
  final SendPort events;
  final TransportSpec port;
}

Future<void> _yield() => Future<void>.delayed(Duration.zero);

void linkIsolateMain(LinkIsolateArgs args) {
  final cmds = ReceivePort();
  final media = ReceivePort();
  args.events.send({'ev': 'ready', 'cmd': cmds.sendPort, 'media': media.sendPort});
  final s = _LinkServer(args.events, args.port);
  media.listen(s.onMedia);
  cmds.listen((m) async {
    final msg = (m as Map).cast<String, Object?>();
    if (msg['cmd'] == 'close') {
      await s.close();
      cmds.close();
      media.close();
      Isolate.exit();
    }
    await s.handle(msg);
  });
}

class _LinkServer {
  _LinkServer(this.events, this.spec);

  final SendPort events;
  final TransportSpec spec;
  ByteTransport? _t;
  bool _busy = false;
  Pacer? _pacer;
  TsMuxer? _mux;
  SendPort? _feedback;
  final Queue<Uint8List> _tsQ = Queue<Uint8List>(); // passthrough TS packets
  int _tsQBytes = 0;
  RandomAccessFile? _tsFile;
  final List<int> _tsCarry = [];
  int _srcPackets = 0, _nullPackets = 0;
  bool _passthrough = false;

  /// File packets per channel packet (TS file passthrough at the file's own rate); 1 = no pacing.
  double _fileShare = 1;
  double _fileCredit = 0;

  void _ev(Map<String, Object?> m) => events.send(m);

  Future<ByteTransport> _open() async => _t ??= await openTransport(spec);

  Future<void> _closeTransport() async {
    await _t?.close();
    _t = null;
  }

  Future<void> close() async {
    _pacer?.stop();
    await _closeTransport();
  }

  Future<void> handle(Map<String, Object?> m) async {
    final id = m['id'];
    if (m['cmd'] == 'stop') {
      _pacer?.stop();
      return;
    }
    if (_busy) {
      _ev({'ev': 'error', 'id': id, 'msg': 'Busy'});
      return;
    }
    _busy = true;
    try {
      switch (m['cmd']) {
        case 'hello':
          await _hello(id, probeRom: m['probeRom'] == true);
        case 'flash':
          await _flash(id, m);
        case 'tx':
          await _tx(id, m);
      }
    } catch (e) {
      _ev({'ev': 'error', 'id': id, 'msg': e.toString()});
      await _closeTransport();
    } finally {
      _busy = false;
    }
  }

  Future<void> _hello(Object? id, {required bool probeRom}) async {
    final t = await _open();
    final info = await EspLink(t).hello(tries: probeRom ? 2 : 6);
    if (info != null) {
      _ev({'ev': 'hello', 'id': id, 'version': info.version, 'line': info.line});
      return;
    }
    if (!probeRom) {
      _ev({'ev': 'hello', 'id': id, 'version': null, 'rom': null});
      return;
    }
    // no DATV firmware: is it an ESP32-C3 in ROM-loader reach?
    final rom = await EspFlasher(t).probeRom();
    await _closeTransport(); // the reset re-enumerates on some hosts
    _ev({'ev': 'hello', 'id': id, 'version': null, 'rom': rom});
  }

  Future<void> _flash(Object? id, Map<String, Object?> m) async {
    final t = await _open();
    final imgs = [
      for (final i in (m['images'] as List).cast<Map>())
        FlashImage(i['name'] as String, i['offset'] as int, (i['data'] as TransferableTypedData).materialize().asUint8List(),
            md5: i['md5'] as String?),
    ];
    var lastPct = -1;
    await EspFlasher(t).flash(imgs, progress: (stage, f) {
      final pct = (f * 100).floor();
      if (pct != lastPct) {
        lastPct = pct;
        _ev({'ev': 'flashProgress', 'id': id, 'stage': stage, 'f': f});
      }
    });
    await _closeTransport();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final t2 = await _open();
    final info = await EspLink(t2).hello(tries: 8);
    _ev({'ev': 'flashed', 'id': id, 'version': info?.version, 'line': info?.line});
  }

  // ---------------------------------------------------------------- media in
  void onMedia(Object? msg) {
    final m = (msg as Map).cast<String, Object?>();
    switch (m['k']) {
      case 'feedback':
        _feedback = m['port'] as SendPort?;
      case 'v':
        final d = (m['data'] as TransferableTypedData).materialize().asUint8List();
        _mux?.addVideo(d, ptsUs: m['pts'] as int, dtsUs: m['dts'] as int?, key: m['key'] == true);
      case 'a':
        final d = (m['data'] as TransferableTypedData).materialize().asUint8List();
        _mux?.addAudio(d, ptsUs: m['pts'] as int);
      case 'ts':
        final d = (m['data'] as TransferableTypedData).materialize().asUint8List();
        _pushTs(d);
      case 'resync':
        _mux?.resync();
    }
  }

  void _pushTs(Uint8List d) {
    _tsCarry.addAll(d);
    var i = 0;
    while (_tsCarry.length - i >= 376) {
      if (_tsCarry[i] != 0x47 || _tsCarry[i + 188] != 0x47) {
        i++;
        continue;
      }
      _tsQ.add(Uint8List.fromList(_tsCarry.sublist(i, i + 188)));
      _tsQBytes += 188;
      i += 188;
    }
    _tsCarry.removeRange(0, i);
  }

  /// Next 8 TS packets for the DVB encoder.
  Uint8List _take8() {
    if (!_passthrough) {
      final out = _mux!.take(8);
      return out;
    }
    if (_tsFile != null && _tsQBytes < 188 * 64) {
      var d = _tsFile!.readSync(188 * 64);
      if (d.isEmpty) {
        _tsFile!.setPositionSync(0); // loop the file
        d = _tsFile!.readSync(188 * 64);
      }
      _pushTs(d);
    }
    final out = Uint8List(188 * 8);
    for (var i = 0; i < 8; i++) {
      _fileCredit += _fileShare;
      if (_fileCredit > 2) _fileCredit = 2;
      if (_tsQ.isNotEmpty && _fileCredit >= 1) {
        _fileCredit -= 1;
        out.setRange(188 * i, 188 * i + 188, _tsQ.removeFirst());
        _tsQBytes -= 188;
        _srcPackets++;
      } else {
        out.setRange(188 * i, 188 * i + 188, nullPacket);
        _nullPackets++;
      }
    }
    return out;
  }

  // ---------------------------------------------------------------- TX
  Future<void> _tx(Object? id, Map<String, Object?> m) async {
    final cfg = TxConfig.fromJson((m['config'] as Map).cast<String, dynamic>());
    final plan = TxPlan.of(cfg);
    final cw = m['cw'] == true;
    final tsPath = m['tsFile'] as String?;
    _passthrough = tsPath != null || m['passthrough'] == true;
    _tsQ.clear();
    _tsQBytes = 0;
    _tsCarry.clear();
    _srcPackets = 0;
    _nullPackets = 0;
    _fileShare = 1;
    _fileCredit = 0;
    if (tsPath != null) {
      final f = _tsFile = await File(tsPath).open();
      final head = f.readSync(4 << 20);
      f.setPositionSync(0);
      final rate = measureTsRate(head);
      if (rate != null) {
        if (rate > plan.capacity * 1.001) {
          await f.close();
          _tsFile = null;
          throw EspError('The TS file needs ${(rate / 1000).toStringAsFixed(1)} kb/s, the channel carries '
              '${(plan.capacity / 1000).toStringAsFixed(1)} kb/s: use a higher symbol rate or FEC, or re-encode the file');
        }
        _fileShare = rate / plan.capacity;
      }
      _ev({'ev': 'fileInfo', 'id': id, 'text': rate == null
          ? 'TS file without PCR: sent at the channel rate'
          : 'TS file at ${(rate / 1000).toStringAsFixed(1)} kb/s, padded with null packets'});
    }
    final mux = m['mux'] as Map?;
    _mux = _passthrough || mux == null
        ? null
        : TsMuxer(
            muxRate: mux['rate'] as int,
            serviceName: mux['service'] as String? ?? 'ESP32-C3 DATV',
            providerName: mux['provider'] as String? ?? 'ESP32-DATV',
            patPeriodMs: mux['patMs'] as int? ?? 200,
            pcrPeriodMs: mux['pcrMs'] as int? ?? 40,
            audio: switch (mux['audio']) { 'mp2' => StreamKind.mp2, 'aac' => StreamKind.aacAdts, _ => null },
          );
    if (!_passthrough && _mux == null) _passthrough = true; // null packets only
    final Uint8List Function(Uint8List) enc = cfg.standard == Standard.dvbs
        ? DvbsEncoder(fec: cfg.fec, swapIq: cfg.swapIq, invert: cfg.invert).encode
        : Dvbs2Encoder(
            fec: cfg.fec,
            short: cfg.shortFrames,
            pilots: cfg.pilots,
            swapIq: cfg.swapIq,
            invert: cfg.invert,
            mod: cfg.effectiveMod,
            bits3: plan.bits3,
          ).encode;
    final cwBlock = Uint8List(4096)..fillRange(0, 4096, plan.mod == Dvbs2Mod.qpsk ? 0xFF : 0x00);

    final t = await _open();
    final link = EspLink(t);
    final info = await link.hello(tries: 6, bootWaitMs: 200);
    if (info == null) throw EspError('The board does not answer INFO: flash the DATV firmware first');
    final st = await link.start(plan.command);
    _ev({
      'ev': 'txStarted',
      'id': id,
      'line': st.line,
      'loHz': st.loHz,
      'centreHz': plan.centreHz(st.loHz),
      'baud': plan.baudAct,
      'capacity': plan.capacity,
    });
    var yieldCount = 0;
    final pacer = _pacer = Pacer(link, plan, (w) async {
      // let media messages in regularly
      if (++yieldCount % 4 == 0) await _yield();
      if (cw) return cwBlock;
      return enc(_take8());
    });
    final statTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final mx = _mux;
      // seconds of queued data: the timestamps ahead of the clock, or the bytes still to send
      final backlog = (mx?.queuedBytes ?? _tsQBytes) * 8 / plan.capacity;
      final ahead = mx?.bufferedSeconds ?? 0;
      final buffered = ahead > backlog ? ahead : backlog;
      _feedback?.send({'k': 'buf', 's': buffered});
    });
    try {
      await pacer.run(onStats: (s) {
        final mx = _mux;
        _ev({
          'ev': 'txStats',
          'id': id,
          'fillMin': s.fillMin,
          'fillMax': s.fillMax,
          'target': s.target,
          'under': s.underruns,
          'kBps': s.kBytesPerSecond,
          'secs': s.elapsed.inMilliseconds / 1000,
          'muxData': mx?.stats.dataPackets ?? _srcPackets,
          'muxNull': mx?.stats.nullPackets ?? _nullPackets,
          'muxLate': mx?.stats.latePackets ?? 0,
          'buffered': mx?.bufferedSeconds ?? 0,
        });
      });
    } finally {
      statTimer.cancel();
      _pacer = null;
      _mux = null;
      await _tsFile?.close();
      _tsFile = null;
      String summary;
      try {
        summary = await link.finish(sendStop: !plan.a16s8);
      } catch (e) {
        summary = 'no summary ($e)';
      }
      _ev({'ev': 'txEnd', 'id': id, 'summary': summary});
    }
  }
}
