import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/esp/flasher.dart';
import '../core/esp/transport.dart';
import '../core/esp/tx_config.dart';
import '../engine/engine.dart';
import '../platform/capture/capture_registry.dart' as cap;
import '../platform/capture/media_source.dart';
import '../platform/serial/ports.dart';

enum BoardState { disconnected, connecting, datv, noAnswer, bareC3, unknown, flashing }

/// Bundled firmware (assets/firmware/manifest.json).
class FirmwareBundle {
  FirmwareBundle(this.manifest, this.images);
  final Map<String, dynamic> manifest;
  final List<FlashImage> images;

  int get version => manifest['version'] as int? ?? 0;
  String get describe => 'v$version (${manifest['source_commit'] ?? '?'}, ESP-IDF ${manifest['idf'] ?? '?'})';

  static Future<FirmwareBundle> load() async {
    final m = jsonDecode(await rootBundle.loadString('assets/firmware/manifest.json')) as Map<String, dynamic>;
    final images = <FlashImage>[];
    for (final i in (m['images'] as List).cast<Map<String, dynamic>>()) {
      final data = await rootBundle.load('assets/firmware/${i['file']}');
      images.add(FlashImage(i['file'] as String, i['offset'] as int, data.buffer.asUint8List(), md5: i['md5'] as String?));
    }
    return FirmwareBundle(m, images);
  }
}

class AppController extends ChangeNotifier {
  TxConfig config = const TxConfig();
  SourceKind sourceKind = SourceKind.testPattern;
  String? filePath;
  bool audio = true;
  int width = 640;
  int videoKbps = 0;
  String serviceName = 'ESP32-C3 DATV';
  String provider = 'ESP32-DATV';
  String preset = 'fast';
  String patternText = '';

  List<PortInfo> ports = [];
  PortInfo? selectedPort;
  DeviceSession? session;
  BoardState board = BoardState.disconnected;
  String? boardLine;
  String? message;

  /// Whether [message] reports a problem (shown in red) or a success.
  bool messageIsError = true;
  double? flashProgress;
  String? flashStage;
  FirmwareBundle? firmware;

  List<CaptureDevice> cameras = [], screens = [], mics = [];
  CaptureDevice? camera, screen, mic;
  bool micOn = true;

  TxStatus? status;
  Preview? preview;
  StreamSubscription<TxStatus>? _statusSub;
  StreamSubscription<Preview>? _previewSub;
  bool starting = false;

  TxPlan? get plan {
    try {
      return TxPlan.of(config);
    } catch (_) {
      return null;
    }
  }

  String? get planError {
    try {
      TxPlan.of(config);
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  bool get transmitting => session?.transmitting ?? false;

  Future<void> init() async {
    try {
      final p = await SharedPreferences.getInstance();
      final j = p.getString('config');
      if (j != null) config = TxConfig.fromJson(jsonDecode(j) as Map<String, dynamic>);
      final s = p.getString('stream');
      if (s != null) {
        final m = jsonDecode(s) as Map<String, dynamic>;
        sourceKind = SourceKind.values.asNameMap()[m['source']] ?? sourceKind;
        filePath = m['file'] as String?;
        audio = m['audio'] as bool? ?? audio;
        width = m['width'] as int? ?? width;
        videoKbps = m['videoKbps'] as int? ?? videoKbps;
        serviceName = m['service'] as String? ?? serviceName;
        provider = m['provider'] as String? ?? provider;
        preset = m['preset'] as String? ?? preset;
        patternText = m['text'] as String? ?? patternText;
        micOn = m['mic'] as bool? ?? micOn;
      }
    } catch (_) {
      // corrupt preferences: keep defaults
    }
    try {
      firmware = await FirmwareBundle.load();
    } catch (e) {
      message = 'Bundled firmware missing: $e';
      messageIsError = true;
    }
    await refreshPorts();
    unawaited(refreshCaptureDevices());
    notifyListeners();
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('config', jsonEncode(config.toJson()));
    await p.setString(
        'stream',
        jsonEncode({
          'source': sourceKind.name,
          'file': filePath,
          'audio': audio,
          'width': width,
          'videoKbps': videoKbps,
          'service': serviceName,
          'provider': provider,
          'preset': preset,
          'text': patternText,
          'mic': micOn,
        }));
  }

  void update(TxConfig c) {
    config = c;
    notifyListeners();
    unawaited(_save());
  }

  void updateStream(void Function() f) {
    f();
    notifyListeners();
    unawaited(_save());
  }

  Future<void> refreshPorts() async {
    try {
      ports = await listPorts();
    } catch (e) {
      ports = [];
      message = 'Cannot list ports: $e';
      messageIsError = true;
    }
    if (selectedPort == null || !ports.any((p) => p.id == selectedPort!.id)) {
      String? last;
      try {
        last = (await SharedPreferences.getInstance()).getString('port');
      } catch (_) {}
      selectedPort = ports.where((p) => p.id == last).firstOrNull ??
          ports.where((p) => p.isEspressif).firstOrNull ??
          ports.firstOrNull;
    } else {
      selectedPort = ports.firstWhere((p) => p.id == selectedPort!.id);
    }
    notifyListeners();
  }

  Future<void> refreshCaptureDevices() async {
    try {
      cameras = await cap.listCameras();
    } catch (_) {
      cameras = [];
    }
    try {
      screens = await cap.listScreens();
    } catch (_) {
      screens = [];
    }
    try {
      mics = await cap.listMicrophones();
    } catch (_) {
      mics = [];
    }
    camera ??= cameras.firstOrNull;
    screen ??= screens.firstOrNull;
    mic ??= mics.firstOrNull;
    notifyListeners();
  }

  void selectPort(PortInfo? p) {
    selectedPort = p;
    notifyListeners();
  }

  Future<void> connect() async {
    final p = selectedPort;
    if (p == null) return;
    await disconnect();
    board = BoardState.connecting;
    message = null;
    notifyListeners();
    try {
      final spec = await prepareTransport(p);
      final s = await DeviceSession.open(p, spec, onClose: () => releaseTransport(p));
      session = s;
      _statusSub = s.statusStream.listen((st) {
        status = st;
        notifyListeners();
      });
      _previewSub = s.previews.listen((pv) {
        preview = pv;
        notifyListeners();
      });
      final h = await s.hello();
      if (h.version != null) {
        board = BoardState.datv;
        boardLine = h.line;
      } else {
        board = BoardState.noAnswer;
        boardLine = null;
      }
      unawaited(SharedPreferences.getInstance().then((pr) => pr.setString('port', p.id)));
    } catch (e) {
      board = BoardState.disconnected;
      message = 'Connection failed: $e';
      messageIsError = true;
      await disconnect();
    }
    notifyListeners();
  }

  /// Resets a board that does not answer into the ROM loader to see whether it is an ESP32-C3.
  Future<void> identifyChip() async {
    final s = session;
    if (s == null) return;
    board = BoardState.connecting;
    notifyListeners();
    try {
      final h = await s.hello(probeRom: true);
      board = h.version != null ? BoardState.datv : (h.rom == true ? BoardState.bareC3 : BoardState.unknown);
      boardLine = h.line;
    } catch (e) {
      board = BoardState.unknown;
      message = 'Identification failed: $e';
      messageIsError = true;
    }
    notifyListeners();
  }

  Future<void> disconnect() async {
    await _statusSub?.cancel();
    await _previewSub?.cancel();
    _statusSub = null;
    _previewSub = null;
    final s = session;
    session = null;
    board = BoardState.disconnected;
    boardLine = null;
    if (s != null) await s.close();
    notifyListeners();
  }

  Future<void> flash() async {
    final s = session, fw = firmware;
    if (s == null || fw == null) return;
    board = BoardState.flashing;
    flashProgress = 0;
    message = null;
    notifyListeners();
    try {
      final h = await s.flash(fw.images, progress: (stage, f) {
        flashStage = stage;
        flashProgress = f;
        notifyListeners();
      });
      board = h.version != null ? BoardState.datv : BoardState.unknown;
      boardLine = h.line;
      message = h.version != null ? 'Firmware installed and verified.' : 'Flashed, but the board does not answer yet. Reconnect.';
      messageIsError = h.version == null;
    } catch (e) {
      board = BoardState.unknown;
      message = 'Flashing failed: $e';
      messageIsError = true;
    }
    flashProgress = null;
    notifyListeners();
  }

  Future<void> start() async {
    final s = session;
    if (s == null) return;
    starting = true;
    message = null;
    preview = null;
    notifyListeners();
    final live = <MediaSource>[];
    try {
      final b = TxPlan.of(config).budget(width: width, videoKbps: videoKbps, audio: audio);
      if (sourceKind == SourceKind.camera) {
        if (camera == null) throw CaptureError('No camera found');
        live.add(cap.cameraSource(camera!, maxWidth: width, fps: b.fps));
      }
      if (sourceKind == SourceKind.screen) {
        if (screen == null) throw CaptureError('No screen found');
        live.add(cap.screenSource(screen!, fps: b.fps, maxWidth: b.maxWidth));
      }
      final wantsMic = audio && micOn && (sourceKind == SourceKind.camera || sourceKind == SourceKind.screen);
      if (wantsMic) {
        if (mic == null) throw CaptureError('No microphone found');
        live.add(cap.micSource(mic!, sampleRate: 48000, channels: 1));
      }
      if (sourceKind == SourceKind.file && (filePath == null || filePath!.isEmpty)) {
        throw CaptureError('Choose a video file first');
      }
      await s.startTx(
        config,
        SourceSpec(
          kind: sourceKind,
          filePath: filePath,
          // camera/screen without the microphone: no audio stream
          audio: audio && (sourceKind == SourceKind.testPattern || sourceKind == SourceKind.file || wantsMic),
          width: width,
          videoKbps: videoKbps,
          serviceName: serviceName,
          provider: provider,
          preset: preset,
          text: patternText,
        ),
        live: live,
      );
    } catch (e) {
      message = e.toString();
      messageIsError = true;
      for (final l in live) {
        unawaited(l.stop().catchError((_) {}));
      }
      await s.stopTx();
    }
    starting = false;
    notifyListeners();
  }

  /// Updates the test pattern text (live while transmitting).
  void setPatternText(String t) {
    patternText = t;
    session?.setPatternText(t);
    unawaited(_save());
  }

  Future<void> stop() async {
    await session?.stopTx();
    notifyListeners();
  }
}

extension FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
