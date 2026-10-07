/// Main-isolate facade over the link, encoder and file-source isolates.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../core/esp/flasher.dart';
import '../core/esp/transport.dart';
import '../core/esp/tx_config.dart';
import '../platform/capture/media_source.dart';
import 'encoder_isolate.dart';
import 'file_source_isolate.dart';
import 'link_isolate.dart';
import 'transport_factory.dart';

enum SourceKind { testPattern, camera, screen, file, nullPackets, carrier }

/// What to transmit.
class SourceSpec {
  const SourceSpec({
    required this.kind,
    this.filePath,
    this.audio = true,
    this.width = 640,
    this.videoKbps = 0,
    this.serviceName = 'ESP32-C3 DATV',
    this.provider = 'ESP32-DATV',
    this.preset = 'fast',
    this.text = '',
  });

  final SourceKind kind;

  /// Test pattern: text shown in the middle of the picture.
  final String text;
  final String? filePath;
  final bool audio;
  final int width, videoKbps;
  final String serviceName, provider;
  final String preset;

  bool get isTs => filePath != null && filePath!.toLowerCase().endsWith('.ts');
}

class HelloResult {
  HelloResult({this.version, this.line, this.rom});

  /// Firmware version, null if the board does not run the DATV firmware.
  final int? version;
  final String? line;

  /// True if an ESP32-C3 ROM loader answered (a C3 without DATV firmware), false if not,
  /// null if it was not probed.
  final bool? rom;
}

/// Live status during a transmission.
class TxStatus {
  String? startLine;
  double centreHz = 0, baud = 0, capacity = 0;
  int fillMin = 0, fillMax = 0, target = 0, under = 0;
  double kBps = 0, secs = 0, buffered = 0;
  int muxData = 0, muxNull = 0, muxLate = 0;
  double encFps = 0, encKbps = 0;
  int encQp = 0, encDropped = 0, encW = 0, encH = 0;
  String? fileInfo;
  String? endSummary;
  String? error;
}

class Preview {
  Preview(this.rgba, this.width, this.height);
  final Uint8List rgba;
  final int width, height;
}

class DeviceSession implements MediaSink {
  DeviceSession._(this.port, this._onClose);

  final PortInfo port;
  final Future<void> Function()? _onClose;
  late final Isolate _link;
  late final SendPort _linkCmd;
  late final SendPort _linkMedia;
  final ReceivePort _events = ReceivePort();
  final StreamController<Map<String, Object?>> _bus = StreamController.broadcast();
  int _nextId = 1;

  Isolate? _encoder;
  SendPort? _encPort;
  Isolate? _fileSrc;
  SendPort? _filePort;
  final List<MediaSource> _live = [];
  final Stopwatch _clock = Stopwatch();
  int _inFlight = 0;
  Completer<void>? _encReady;
  final ReceivePort _acks = ReceivePort();

  final TxStatus status = TxStatus();
  final StreamController<TxStatus> _status = StreamController.broadcast();
  final StreamController<Preview> _preview = StreamController.broadcast();

  Stream<TxStatus> get statusStream => _status.stream;
  Stream<Preview> get previews => _preview.stream;
  bool get transmitting => _txId != null;
  int? _txId;

  /// [spec] comes from `prepareTransport` (platform/serial/ports.dart); [onClose] releases it.
  static Future<DeviceSession> open(PortInfo p, TransportSpec spec, {Future<void> Function()? onClose}) async {
    final s = DeviceSession._(p, onClose);
    final ready = Completer<void>();
    s._events.listen((m) {
      final msg = (m as Map).cast<String, Object?>();
      if (msg['ev'] == 'ready') {
        s._linkCmd = msg['cmd'] as SendPort;
        s._linkMedia = msg['media'] as SendPort;
        ready.complete();
        return;
      }
      s._onEvent(msg);
    });
    s._acks.listen((_) => s._inFlight--);
    s._link = await Isolate.spawn(linkIsolateMain, LinkIsolateArgs(s._events.sendPort, spec),
        debugName: 'link');
    await ready.future;
    return s;
  }

  Future<void> close() async {
    await stopTx();
    _linkCmd.send({'cmd': 'close'});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    _link.kill(priority: Isolate.beforeNextEvent);
    _events.close();
    _acks.close();
    await _onClose?.call();
  }

  void _onEvent(Map<String, Object?> m) {
    switch (m['ev']) {
      case 'txStarted':
        status
          ..startLine = m['line'] as String?
          ..centreHz = (m['centreHz'] as num).toDouble()
          ..baud = (m['baud'] as num).toDouble()
          ..capacity = (m['capacity'] as num).toDouble();
        _status.add(status);
      case 'txStats':
        status
          ..fillMin = m['fillMin'] as int
          ..fillMax = m['fillMax'] as int
          ..target = m['target'] as int
          ..under = m['under'] as int
          ..kBps = (m['kBps'] as num).toDouble()
          ..secs = (m['secs'] as num).toDouble()
          ..muxData = m['muxData'] as int
          ..muxNull = m['muxNull'] as int
          ..muxLate = m['muxLate'] as int
          ..buffered = (m['buffered'] as num).toDouble();
        _status.add(status);
      case 'txEnd':
        status.endSummary = m['summary'] as String?;
        _txId = null;
        _stopSources();
        _status.add(status);
      case 'encStats':
        status
          ..encFps = (m['fps'] as num).toDouble()
          ..encKbps = (m['kbps'] as num).toDouble()
          ..encQp = m['qp'] as int
          ..encDropped = m['dropped'] as int
          ..encW = m['w'] as int
          ..encH = m['h'] as int;
        _status.add(status);
      case 'encReady':
        _encPort = m['port'] as SendPort;
        _encReady?.complete();
        if (_filePort != null) _encPort!.send({'k': 'sourceFeedback', 'port': _filePort});
      case 'fileReady':
        _filePort = m['port'] as SendPort;
        _encPort?.send({'k': 'sourceFeedback', 'port': _filePort});
        _linkMedia.send({'k': 'feedback', 'port': _filePort}); // passthrough: the link paces the file
      case 'fileInfo':
        status.fileInfo = m['text'] as String?;
        _status.add(status);
      case 'preview':
        _preview.add(Preview((m['data'] as TransferableTypedData).materialize().asUint8List(), m['w'] as int,
            m['h'] as int));
      case 'isolateError':
        status.error = '${m['where']}: ${m['msg']}';
        // ignore: avoid_print
        print('isolate error in ${m['where']}: ${m['msg']}\n${m['stack']}');
        _status.add(status);
      case 'error':
        if (m['id'] == _txId) {
          status.error = m['msg'] as String?;
          _txId = null;
          _stopSources();
          _status.add(status);
        }
    }
    _bus.add(m);
  }

  Future<Map<String, Object?>> _request(Map<String, Object?> cmd, Set<String> finalEvents,
      {void Function(Map<String, Object?>)? onEvent}) async {
    final id = _nextId++;
    final done = Completer<Map<String, Object?>>();
    final sub = _bus.stream.listen((m) {
      if (m['id'] != id) return;
      if (m['ev'] == 'error') {
        if (!done.isCompleted) done.completeError(StateError(m['msg'] as String? ?? 'error'));
      } else if (finalEvents.contains(m['ev'])) {
        if (!done.isCompleted) done.complete(m);
      } else {
        onEvent?.call(m);
      }
    });
    _linkCmd.send({...cmd, 'id': id});
    try {
      return await done.future;
    } finally {
      await sub.cancel();
    }
  }

  /// Checks for the DATV firmware (INFO). With [probeRom], a board without it is reset into
  /// the ROM loader to see whether it is an ESP32-C3 (this restarts the board).
  Future<HelloResult> hello({bool probeRom = false}) async {
    final r = await _request({'cmd': 'hello', 'probeRom': probeRom}, {'hello'});
    return HelloResult(version: r['version'] as int?, line: r['line'] as String?, rom: r['rom'] as bool?);
  }

  Future<HelloResult> flash(List<FlashImage> images, {FlashProgress? progress}) async {
    final r = await _request(
      {
        'cmd': 'flash',
        'images': [
          for (final i in images)
            {'name': i.name, 'offset': i.offset, 'md5': i.md5, 'data': TransferableTypedData.fromList([i.data])},
        ],
      },
      {'flashed'},
      onEvent: (m) {
        if (m['ev'] == 'flashProgress') progress?.call(m['stage'] as String, (m['f'] as num).toDouble());
      },
    );
    return HelloResult(version: r['version'] as int?, line: r['line'] as String?);
  }

  // ---------------------------------------------------------------- transmission
  /// Starts transmitting. [live] are already-created capture sources (camera/screen/mic).
  Future<void> startTx(TxConfig cfg, SourceSpec src, {List<MediaSource> live = const []}) async {
    if (_txId != null) throw StateError('Already transmitting');
    final plan = TxPlan.of(cfg);
    final b = plan.budget(width: src.width, videoKbps: src.videoKbps, audio: src.audio);
    if (b.videoBitrate < 6000 && src.kind != SourceKind.nullPackets && src.kind != SourceKind.carrier && !src.isTs) {
      throw ConfigError('Channel capacity ${(plan.capacity / 1000).toStringAsFixed(1)} kb/s is too small for video: '
          'use a higher symbol rate or FEC');
    }
    status
      ..startLine = null
      ..endSummary = null
      ..error = null
      ..fileInfo = null
      ..encFps = 0
      ..encKbps = 0;
    _clock
      ..reset()
      ..start();
    _inFlight = 0;
    final id = _nextId++;
    _txId = id;
    final media = src.kind != SourceKind.nullPackets && src.kind != SourceKind.carrier && !src.isTs;
    final audioKbps = src.audio ? b.audioKbps : 0;
    var passthrough = false;
    if (src.kind == SourceKind.file && !src.isTs) {
      // decide passthrough vs transcode in the file isolate; it reports back
      passthrough = await FileSourceProbe.fits(src.filePath!, b);
    }
    if (media && !passthrough) {
      _encReady = Completer<void>();
      _encoder = await Isolate.spawn(
          encoderIsolateMain,
          EncoderIsolateArgs(
            _events.sendPort,
            _linkMedia,
            EncoderSpec(
              maxWidth: b.maxWidth,
              fps: b.fps,
              videoBitrate: b.videoBitrate,
              audioKbps: audioKbps,
              audioRate: b.audioRate,
              audioChannels: b.audioChannels,
              testPattern: src.kind == SourceKind.testPattern,
              preset: src.preset,
              text: src.text,
            ),
          ),
          debugName: 'encoder');
      await _encReady!.future;
    }
    _linkCmd.send({
      'cmd': 'tx',
      'id': id,
      'config': cfg.toJson(),
      'cw': src.kind == SourceKind.carrier,
      'tsFile': src.isTs ? src.filePath : null,
      'mux': media
          ? {
              'rate': plan.capacity.floor(), // mux clock = channel rate; the budget leaves the margin
              'service': src.serviceName,
              'provider': src.provider,
              'patMs': (b.patPeriod * 1000).round(),
              'pcrMs': b.pcrPeriodMs,
              'audio': passthrough ? (src.audio ? 'aac' : null) : (audioKbps > 0 ? 'mp2' : null),
            }
          : null,
    });
    if (src.kind == SourceKind.file && !src.isTs) {
      _fileSrc = await Isolate.spawn(
          fileSourceIsolateMain,
          FileSourceArgs(
            path: src.filePath!,
            events: _events.sendPort,
            encoder: passthrough ? null : _encPort,
            link: _linkMedia,
            passthrough: passthrough,
            audio: src.audio,
          ),
          debugName: 'file');
    }
    for (final s in live) {
      await s.start(this);
      _live.add(s);
    }
  }

  /// Changes the test pattern text while transmitting.
  void setPatternText(String t) => _encPort?.send({'k': 'text', 't': t});

  Future<void> stopTx() async {
    _linkCmd.send({'cmd': 'stop'});
    await _stopSources();
  }

  Future<void> _stopSources() async {
    final live = List.of(_live);
    _live.clear();
    for (final s in live) {
      try {
        await s.stop();
      } catch (_) {
        // ignore
      }
    }
    _encPort?.send({'k': 'stop'});
    _encPort = null;
    _filePort?.send({'k': 'stop'});
    _filePort = null;
    // isolates exit on 'stop'; make sure they are gone even if one is stuck
    final enc = _encoder, file = _fileSrc;
    _encoder = null;
    _fileSrc = null;
    Future<void>.delayed(const Duration(seconds: 2), () {
      enc?.kill();
      file?.kill();
    });
  }

  // ---------------------------------------------------------------- MediaSink for live sources
  @override
  int nowUs() => _clock.elapsedMicroseconds;

  @override
  void video(RawFormat fmt, Uint8List data, int width, int height, int stride, int ptsUs) {
    final p = _encPort;
    if (p == null || _inFlight >= 2) return; // the encoder is busy: drop
    _inFlight++;
    p.send({
      'k': 'v',
      'fmt': fmt.index,
      'data': TransferableTypedData.fromList([data]),
      'w': width,
      'h': height,
      'stride': stride,
      'pts': ptsUs,
      'live': true,
      'ack': _acks.sendPort,
    });
  }

  @override
  void audio(Int16List pcm, int sampleRate, int channels, int ptsUs) {
    _encPort?.send({
      'k': 'a',
      'data': TransferableTypedData.fromList([pcm]),
      'rate': sampleRate,
      'ch': channels,
      'pts': ptsUs,
    });
  }
}
