/// A small MPEG-TS demultiplexer for the on-air monitor: reads the PAT, PMT and SDT of the
/// first programme and reassembles its PES packets. Single-section tables only (what this
/// app's muxer and typical DATV encoders send).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'crc32.dart';

class TsStream {
  TsStream(this.pid, this.type);
  final int pid;

  /// stream_type from the PMT (0x1B H.264, 0x03/0x04 MPEG audio, 0x0F AAC, ...).
  final int type;

  String get label => switch (type) {
        0x1B => 'H.264 video',
        0x24 => 'H.265 video',
        0x01 || 0x02 => 'MPEG-2 video',
        0x03 || 0x04 => 'MPEG audio',
        0x0F => 'AAC audio',
        0x11 => 'AAC (LATM) audio',
        0x81 => 'AC-3 audio',
        _ => 'stream type 0x${type.toRadixString(16)}',
      };

  bool get isVideo => type == 0x1B || type == 0x24 || type == 0x01 || type == 0x02;
}

/// One complete PES packet payload of an elementary stream.
class PesPacket {
  PesPacket(this.pid, this.data, this.ptsUs);
  final int pid;
  final Uint8List data;

  /// Presentation time in microseconds, or null when the header had none.
  final int? ptsUs;
}

class _Pes {
  final BytesBuilder buf = BytesBuilder(copy: true);
  int? pts90k;
  bool open = false;
}

class TsDemuxer {
  TsDemuxer({required this.onPes});

  final void Function(PesPacket) onPes;

  int packets = 0, nullPackets = 0, syncErrors = 0, ccErrors = 0, crcErrors = 0;
  int? pmtPid;
  int? serviceId;
  String? serviceName, providerName;
  List<TsStream> streams = const [];

  final Map<int, int> _cc = {};
  final Map<int, _Pes> _pes = {};
  final List<int> _carry = [];

  /// Feeds TS bytes (any chunking; resynchronises on the 0x47 sync byte).
  void feed(Uint8List d) {
    var i = 0;
    if (_carry.isNotEmpty) {
      final need = 188 - _carry.length;
      if (d.length < need) {
        _carry.addAll(d);
        return;
      }
      _carry.addAll(Uint8List.sublistView(d, 0, need));
      if (_carry[0] == 0x47) _packet(Uint8List.fromList(_carry));
      _carry.clear();
      i = need;
    }
    while (i + 188 <= d.length) {
      if (d[i] != 0x47) {
        syncErrors++;
        while (i < d.length && d[i] != 0x47) {
          i++;
        }
        continue;
      }
      _packet(Uint8List.sublistView(d, i, i + 188));
      i += 188;
    }
    if (i < d.length) _carry.addAll(Uint8List.sublistView(d, i));
  }

  /// Forgets partial PES packets after data was skipped.
  void discontinuity() {
    _pes.clear();
    _cc.clear();
    _carry.clear();
  }

  void _packet(Uint8List p) {
    packets++;
    final pid = ((p[1] & 0x1F) << 8) | p[2];
    if (pid == 0x1FFF) {
      nullPackets++;
      return;
    }
    if ((p[1] & 0x80) != 0) return; // transport error indicator
    final pusi = (p[1] & 0x40) != 0;
    final afc = (p[3] >> 4) & 3;
    final cc = p[3] & 0x0F;
    if ((afc & 1) != 0) {
      final last = _cc[pid];
      if (last != null && cc != ((last + 1) & 0x0F) && cc != last) {
        ccErrors++;
        _pes[pid]?.open = false; // drop the broken PES
      }
      _cc[pid] = cc;
    }
    var o = 4;
    if ((afc & 2) != 0) o += 1 + p[4];
    if ((afc & 1) == 0 || o >= 188) return;
    final payload = Uint8List.sublistView(p, o);
    if (pid == 0 || pid == pmtPid || pid == 0x11) {
      if (pusi) _section(pid, payload);
      return;
    }
    if (!streams.any((s) => s.pid == pid)) return;
    final st = _pes.putIfAbsent(pid, _Pes.new);
    if (pusi) {
      _flush(pid, st);
      if (payload.length < 9 || payload[0] != 0 || payload[1] != 0 || payload[2] != 1) return;
      final hdrLen = payload[8];
      st.pts90k = (payload[7] & 0x80) != 0 && payload.length >= 14 ? _readPts(payload, 9) : null;
      final start = 9 + hdrLen;
      if (start > payload.length) return;
      st.open = true;
      st.buf.add(Uint8List.sublistView(payload, start));
    } else if (st.open) {
      st.buf.add(payload);
    }
  }

  void _flush(int pid, _Pes st) {
    if (st.open && st.buf.length > 0) {
      final pts = st.pts90k;
      onPes(PesPacket(pid, st.buf.takeBytes(), pts == null ? null : pts * 100 ~/ 9));
    }
    st.buf.clear();
    st.open = false;
  }

  /// Hands out the PES packets still being collected (the end of a stream).
  void flush() {
    _pes.forEach(_flush);
  }

  static int _readPts(Uint8List b, int o) =>
      ((b[o] >> 1) & 7) << 30 | b[o + 1] << 22 | (b[o + 2] >> 1) << 15 | b[o + 3] << 7 | (b[o + 4] >> 1);

  void _section(int pid, Uint8List payload) {
    final ptr = payload[0];
    final s = 1 + ptr;
    if (s + 3 > payload.length) return;
    final len = ((payload[s + 1] & 0x0F) << 8) | payload[s + 2];
    if (s + 3 + len > payload.length || len < 9) return;
    final sec = Uint8List.sublistView(payload, s, s + 3 + len);
    if (crc32Mpeg(sec) != 0) {
      crcErrors++;
      return;
    }
    final body = Uint8List.sublistView(sec, 8, sec.length - 4);
    switch (sec[0]) {
      case 0x00 when pid == 0:
        for (var i = 0; i + 4 <= body.length; i += 4) {
          final prog = (body[i] << 8) | body[i + 1];
          if (prog == 0) continue; // network PID
          final pmt = ((body[i + 2] & 0x1F) << 8) | body[i + 3];
          if (pmtPid != pmt) {
            pmtPid = pmt;
            serviceId = prog;
            streams = const [];
          }
          break;
        }
      case 0x02 when pid == pmtPid:
        if (body.length < 4) return;
        final infoLen = ((body[2] & 0x0F) << 8) | body[3];
        final list = <TsStream>[];
        for (var i = 4 + infoLen; i + 5 <= body.length;) {
          final esPid = ((body[i + 1] & 0x1F) << 8) | body[i + 2];
          list.add(TsStream(esPid, body[i]));
          i += 5 + (((body[i + 3] & 0x0F) << 8) | body[i + 4]);
        }
        streams = list;
      case 0x42 when pid == 0x11:
        // original_network_id(2) reserved(1), then services
        for (var i = 3; i + 5 <= body.length;) {
          final sid = (body[i] << 8) | body[i + 1];
          final dlen = ((body[i + 3] & 0x0F) << 8) | body[i + 4];
          final end = (i + 5 + dlen).clamp(0, body.length);
          if (serviceId == null || sid == serviceId) {
            for (var d = i + 5; d + 2 <= end;) {
              final tag = body[d], l = body[d + 1];
              if (tag == 0x48 && d + 2 + l <= end && l >= 3) {
                final pl = body[d + 3];
                if (d + 4 + pl < end) {
                  providerName = _text(Uint8List.sublistView(body, d + 4, d + 4 + pl));
                  final nl = body[d + 4 + pl];
                  final ns = d + 5 + pl;
                  if (ns + nl <= end) serviceName = _text(Uint8List.sublistView(body, ns, ns + nl));
                }
              }
              d += 2 + l;
            }
          }
          i = end;
        }
    }
  }

  /// DVB text: a leading byte below 0x20 selects the character table (UTF-8 is 0x15).
  static String _text(Uint8List b) {
    if (b.isEmpty) return '';
    if (b[0] == 0x15) return utf8.decode(b.sublist(1), allowMalformed: true);
    if (b[0] < 0x20) b = b.sublist(1);
    return utf8.decode(b, allowMalformed: true);
  }
}
