/// MPEG transport stream multiplexer with a constant packet rate (null packets fill the gaps).
///
/// Pull model: the transmitter asks for packets ([take]); every packet advances the mux clock
/// by 188 * 8 / muxRate seconds, PCR is that clock, so the stream is CBR by construction.
/// Encoded access units are queued with their DTS/PTS in source time; the first one sets the
/// offset between source time and mux time ([delayMs] of decoder buffering).
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import '../dvb/ts_const.dart';
import 'crc32.dart';

enum StreamKind { h264, mp2, aacAdts }

class _Pes {
  _Pes(this.data, this.dts90k);
  final Uint8List data; // complete PES packet
  final int dts90k; // in mux time
  int off = 0;
  bool get first => off == 0;
}

class _Es {
  _Es(this.pid, this.kind);
  final int pid;
  final StreamKind kind;
  final Queue<_Pes> q = Queue<_Pes>();
  int cc = 0;
  int queuedBytes = 0;

  int get streamType => switch (kind) { StreamKind.h264 => 0x1B, StreamKind.mp2 => 0x04, StreamKind.aacAdts => 0x0F };
  int get streamId => kind == StreamKind.h264 ? 0xE0 : 0xC0;
}

class MuxStats {
  int dataPackets = 0, nullPackets = 0, psiPackets = 0, latePackets = 0;
}

class TsMuxer {
  TsMuxer({
    required this.muxRate,
    this.serviceName = 'ESP32-C3 DATV',
    this.providerName = 'ESP32-DATV',
    this.patPeriodMs = 200,
    this.pcrPeriodMs = 40,
    this.delayMs = 700,
    this.video = StreamKind.h264,
    this.audio,
    this.serviceId = 1,
    this.pmtPid = 0x1000,
    this.videoPid = 0x100,
    this.audioPid = 0x101,
  }) {
    _v = _Es(videoPid, video);
    if (audio != null) _a = _Es(audioPid, audio!);
  }

  final int muxRate;
  final String serviceName, providerName;
  final int patPeriodMs, pcrPeriodMs, delayMs;
  final StreamKind video;
  final StreamKind? audio;
  final int serviceId, pmtPid, videoPid, audioPid;

  late final _Es _v;
  _Es? _a;
  final MuxStats stats = MuxStats();

  /// Mux clock in 27 MHz units at the start of the next packet.
  int _clock27 = 0;
  int? _offset90k; // mux time = source time + offset
  int _nextPsi = 0, _nextPcr = 0;
  int _patCc = 0, _pmtCc = 0, _sdtCc = 0;
  final Queue<Uint8List> _psiQ = Queue<Uint8List>();

  int get _pktTicks27 => 188 * 8 * 27000000 ~/ muxRate;

  /// Seconds of data queued ahead of the mux clock (for backpressure).
  double get bufferedSeconds {
    int? last;
    for (final es in [_v, ?_a]) {
      if (es.q.isNotEmpty && (last == null || es.q.last.dts90k > last)) last = es.q.last.dts90k;
    }
    if (last == null) return 0;
    return (last - _clock27 ~/ 300) / 90000.0;
  }

  int get queuedBytes => _v.queuedBytes + (_a?.queuedBytes ?? 0);

  /// Mux clock in seconds.
  double get clockSeconds => _clock27 / 27e6;

  void _ensureOffset(int dts90k) {
    _offset90k ??= _clock27 ~/ 300 + delayMs * 90 - dts90k;
  }

  /// Drops all queued data and restarts the timeline (e.g. after a source change).
  void resync() {
    _v.q.clear();
    _v.queuedBytes = 0;
    _a?.q.clear();
    _a?.queuedBytes = 0;
    _offset90k = null;
  }

  /// Queues one H.264 access unit (Annex B). Times in microseconds of source time.
  void addVideo(Uint8List au, {required int ptsUs, int? dtsUs, bool key = false}) {
    final pts = ptsUs * 9 ~/ 100;
    final dts = (dtsUs ?? ptsUs) * 9 ~/ 100;
    _ensureOffset(dts);
    final o = _offset90k!;
    final pes = _pesPacket(_v.streamId, au, pts + o, dts == pts ? null : dts + o, video: true);
    _v.q.add(_Pes(pes, dts + o));
    _v.queuedBytes += pes.length;
  }

  /// Queues one audio frame (MP2 frame or ADTS frame).
  void addAudio(Uint8List frame, {required int ptsUs}) {
    final a = _a;
    if (a == null) return;
    final pts = ptsUs * 9 ~/ 100;
    _ensureOffset(pts);
    final o = _offset90k!;
    final pes = _pesPacket(a.streamId, frame, pts + o, null, video: false);
    a.q.add(_Pes(pes, pts + o));
    a.queuedBytes += pes.length;
  }

  static void _putTs(Uint8List b, int off, int marker, int t) {
    b[off] = (marker << 4) | (((t >> 30) & 7) << 1) | 1;
    b[off + 1] = (t >> 22) & 0xFF;
    b[off + 2] = (((t >> 15) & 0x7F) << 1) | 1;
    b[off + 3] = (t >> 7) & 0xFF;
    b[off + 4] = ((t & 0x7F) << 1) | 1;
  }

  Uint8List _pesPacket(int streamId, Uint8List payload, int pts, int? dts, {required bool video}) {
    final hdrData = dts != null ? 10 : 5;
    final out = Uint8List(9 + hdrData + payload.length);
    out[0] = 0;
    out[1] = 0;
    out[2] = 1;
    out[3] = streamId;
    final len = 3 + hdrData + payload.length;
    // video PES may use length 0 (unbounded) when too long
    final pl = (video && len > 0xFFFF) ? 0 : len;
    out[4] = (pl >> 8) & 0xFF;
    out[5] = pl & 0xFF;
    out[6] = 0x80 | (video ? 0x04 : 0x00); // marker bits, data_alignment for video
    out[7] = dts != null ? 0xC0 : 0x80;
    out[8] = hdrData;
    final p = pts & 0x1FFFFFFFF;
    if (dts != null) {
      _putTs(out, 9, 3, p);
      _putTs(out, 14, 1, dts & 0x1FFFFFFFF);
    } else {
      _putTs(out, 9, 2, p);
    }
    out.setRange(9 + hdrData, out.length, payload);
    return out;
  }

  // ---------------------------------------------------------------- PSI
  Uint8List _section(int tableId, int ext, List<int> body, {int version = 0}) {
    // syntax section: table_id, length, ext, version, section numbers, body, CRC
    final len = 5 + body.length + 4;
    final s = <int>[
      tableId,
      0xB0 | ((len >> 8) & 0x0F),
      len & 0xFF,
      (ext >> 8) & 0xFF,
      ext & 0xFF,
      0xC1 | ((version & 0x1F) << 1),
      0,
      0,
      ...body,
    ];
    final crc = crc32Mpeg(Uint8List.fromList(s));
    s.addAll([(crc >> 24) & 0xFF, (crc >> 16) & 0xFF, (crc >> 8) & 0xFF, crc & 0xFF]);
    return Uint8List.fromList(s);
  }

  Uint8List _psiPacket(int pid, Uint8List section, int cc) {
    final p = Uint8List(188)..fillRange(0, 188, 0xFF);
    p[0] = 0x47;
    p[1] = 0x40 | ((pid >> 8) & 0x1F);
    p[2] = pid & 0xFF;
    p[3] = 0x10 | (cc & 0x0F);
    p[4] = 0; // pointer field
    p.setRange(5, 5 + section.length, section);
    return p;
  }

  void _queuePsi() {
    final pat = _section(0x00, 1, [
      (serviceId >> 8) & 0xFF, serviceId & 0xFF, 0xE0 | ((pmtPid >> 8) & 0x1F), pmtPid & 0xFF, //
    ]);
    final esInfo = <int>[];
    for (final es in [_v, ?_a]) {
      esInfo.addAll([es.streamType, 0xE0 | ((es.pid >> 8) & 0x1F), es.pid & 0xFF, 0xF0, 0x00]);
    }
    final pmt = _section(0x02, serviceId, [
      0xE0 | ((videoPid >> 8) & 0x1F), videoPid & 0xFF, // PCR PID
      0xF0, 0x00, // program info length
      ...esInfo,
    ]);
    final prov = utf8.encode(providerName), name = utf8.encode(serviceName);
    final desc = [0x48, 3 + prov.length + name.length, 0x01, prov.length, ...prov, name.length, ...name];
    final sdt = _section(0x42, 1, [
      0x00, 0x01, // original network id
      0xFF, // reserved
      (serviceId >> 8) & 0xFF, serviceId & 0xFF,
      0xFC, // EIT flags off
      0x80 | ((desc.length >> 8) & 0x0F), desc.length & 0xFF, // running, not scrambled
      ...desc,
    ]);
    _psiQ.add(_psiPacket(0x0000, pat, _patCc++));
    _psiQ.add(_psiPacket(pmtPid, pmt, _pmtCc++));
    _psiQ.add(_psiPacket(0x0011, sdt, _sdtCc++));
  }

  // ---------------------------------------------------------------- packets
  Uint8List _pcrOnlyPacket(int pcr27) {
    final p = Uint8List(188)..fillRange(0, 188, 0xFF);
    p[0] = 0x47;
    p[1] = (videoPid >> 8) & 0x1F;
    p[2] = videoPid & 0xFF;
    p[3] = 0x20 | (_v.cc & 0x0F); // adaptation only, CC does not advance
    p[4] = 183;
    p[5] = 0x10;
    _putPcr(p, 6, pcr27);
    return p;
  }

  static void _putPcr(Uint8List p, int off, int pcr27) {
    final base = (pcr27 ~/ 300) & 0x1FFFFFFFF;
    final ext = pcr27 % 300;
    p[off] = (base >> 25) & 0xFF;
    p[off + 1] = (base >> 17) & 0xFF;
    p[off + 2] = (base >> 9) & 0xFF;
    p[off + 3] = (base >> 1) & 0xFF;
    p[off + 4] = ((base & 1) << 7) | 0x7E | ((ext >> 8) & 1);
    p[off + 5] = ext & 0xFF;
  }

  Uint8List _dataPacket(_Es es, int pcr27OrMinus) {
    final pes = es.q.first;
    final p = Uint8List(188);
    p[0] = 0x47;
    p[1] = (pes.first ? 0x40 : 0) | ((es.pid >> 8) & 0x1F);
    p[2] = es.pid & 0xFF;
    final withPcr = pcr27OrMinus >= 0;
    var afLen = withPcr ? 7 : 0; // adaptation_field_length (excluding itself)
    final remaining = pes.data.length - pes.off;
    var room = 184 - (withPcr ? 1 + afLen : 0);
    if (remaining < room) {
      // stuff with adaptation field
      final need = room - remaining;
      if (withPcr) {
        afLen += need;
      } else {
        afLen = need - 1; // need >= 1
      }
      room = remaining;
    }
    final hasAf = withPcr || remaining < 184;
    p[3] = (hasAf ? 0x30 : 0x10) | (es.cc & 0x0F);
    es.cc = (es.cc + 1) & 0x0F;
    var o = 4;
    if (hasAf) {
      p[o++] = afLen;
      if (afLen > 0) {
        p[o++] = withPcr ? 0x10 : 0x00;
        if (withPcr) {
          _putPcr(p, o, pcr27OrMinus);
          o += 6;
        }
        final stuffEnd = 5 + afLen;
        while (o < stuffEnd) {
          p[o++] = 0xFF;
        }
      }
    }
    final n = 188 - o;
    p.setRange(o, 188, pes.data, pes.off);
    pes.off += n;
    es.queuedBytes -= n;
    if (pes.off >= pes.data.length) es.q.removeFirst();
    return p;
  }

  /// The next [n] packets (n * 188 bytes).
  Uint8List take(int n) {
    final out = Uint8List(188 * n);
    for (var i = 0; i < n; i++) {
      out.setRange(188 * i, 188 * i + 188, _next());
    }
    return out;
  }

  Uint8List _next() {
    final now = _clock27;
    _clock27 += _pktTicks27;
    if (now >= _nextPsi) {
      _queuePsi();
      _nextPsi = now + patPeriodMs * 27000;
    }
    if (_psiQ.isNotEmpty) {
      stats.psiPackets++;
      return _psiQ.removeFirst();
    }
    final pcrDue = now >= _nextPcr;
    // the stream whose head has the earliest DTS goes first
    _Es? es;
    for (final e in [_v, ?_a]) {
      if (e.q.isEmpty) continue;
      if (es == null || e.q.first.dts90k < es.q.first.dts90k) es = e;
    }
    if (pcrDue) _nextPcr = now + pcrPeriodMs * 27000;
    if (es == null) {
      if (pcrDue) return _pcrOnlyPacket(now);
      stats.nullPackets++;
      return nullPacket;
    }
    if (pcrDue && es != _v) {
      // PCR rides on the video PID; send a PCR-only packet first, the data next time
      return _pcrOnlyPacket(now);
    }
    stats.dataPackets++;
    if (es.q.first.dts90k * 300 < now) stats.latePackets++;
    return _dataPacket(es, pcrDue ? now : -1);
  }
}
