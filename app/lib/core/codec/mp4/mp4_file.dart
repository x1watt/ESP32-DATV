import 'dart:async';
import 'dart:typed_data';

import 'audio_specific_config.dart';
import 'avc_config.dart';
import 'box_reader.dart';
import 'byte_source.dart';
import 'mp4_exception.dart';

export 'avc_config.dart';
export 'mp4_exception.dart';

enum Mp4TrackKind { video, audio, other }

/// Metadata of one sample (no payload). Times are in track timescale units.
class Mp4SampleInfo {
  const Mp4SampleInfo({
    required this.index,
    required this.offset,
    required this.size,
    required this.dts,
    required this.cts,
    required this.duration,
    required this.isSync,
  });

  /// Zero based index in decode order.
  final int index;

  /// Absolute file offset of the sample data.
  final int offset;
  final int size;

  /// Decode time, before the edit list is applied.
  final int dts;

  /// Composition time (dts plus the ctts offset), before the edit list.
  final int cts;
  final int duration;
  final bool isSync;

  @override
  String toString() =>
      'Mp4SampleInfo(#$index off=$offset size=$size '
      'dts=$dts cts=$cts dur=$duration${isSync ? ' sync' : ''})';
}

/// One sample with its payload.
class Mp4Sample {
  const Mp4Sample({
    required this.trackId,
    required this.index,
    required this.dtsUs,
    required this.ptsUs,
    required this.durationUs,
    required this.isSync,
    required this.offset,
    required this.size,
    required this.data,
  });

  final int trackId;
  final int index;

  /// Decode time in microseconds with the edit list applied.
  final int dtsUs;

  /// Presentation time in microseconds with the edit list applied.
  final int ptsUs;
  final int durationUs;
  final bool isSync;
  final int offset;

  /// Size declared by the sample table. [data] may be shorter only when the
  /// file is truncated.
  final int size;

  /// Sample payload. Usually a view into a larger read buffer; copy it if you
  /// need to keep it for long while dropping the others.
  final Uint8List data;
}

/// A track of an MP4 file.
class Mp4Track {
  Mp4Track({
    required this.id,
    required this.kind,
    required this.handler,
    required this.sampleEntry,
    required this.codec,
    required this.supported,
    required this.width,
    required this.height,
    required this.timescale,
    required this.durationTs,
    required this.durationUs,
    required this.sampleCount,
    required this.avgBitrate,
    required this.frameRate,
    required this.avc,
    required this.sampleRate,
    required this.channels,
    required this.audioObjectType,
    required this.audioSpecificConfig,
    required this.codecConfig,
    required this.presentationOffsetUs,
    required this.editMediaTime,
    required this.emptyEditDelayUs,
    required this.originalFormat,
    required this.objectTypeIndication,
    required this.extensionSampleRate,
    required this.language,
    required this.fragmented,
    required this.syncSampleCount,
  });

  final int id;
  final Mp4TrackKind kind;

  /// Handler type from 'hdlr', for example 'vide' or 'soun'.
  final String handler;

  /// Fourcc of the first sample entry, for example 'avc1', 'mp4a', 'encv'.
  final String sampleEntry;

  /// RFC 6381 style codec string, for example 'avc1.640028' or 'mp4a.40.2'.
  final String codec;

  /// True only for avc1/avc3 video with a valid avcC and for AAC in mp4a.
  final bool supported;

  final int width;
  final int height;
  final int timescale;
  final int durationTs;
  final int durationUs;
  final int sampleCount;

  /// Bits per second: total sample bytes over the track duration.
  final int avgBitrate;

  /// Video only: sampleCount divided by the duration in seconds.
  final double? frameRate;

  final AvcConfig? avc;

  /// Audio: output sample rate in Hz (core rate from the ASC when present).
  final int sampleRate;
  final int channels;

  /// Audio: signalled MPEG-4 audio object type (2 = AAC LC), 0 if unknown.
  final int audioObjectType;
  final Uint8List? audioSpecificConfig;

  /// Raw avcC payload (video) or raw AudioSpecificConfig (audio).
  final Uint8List? codecConfig;

  /// Offset added to media times to get presentation times:
  /// emptyEditDelayUs minus editMediaTime in microseconds. Already applied to
  /// [Mp4Sample.dtsUs] and [Mp4Sample.ptsUs].
  final int presentationOffsetUs;

  /// media_time of the first non-empty edit, in track timescale units.
  final int editMediaTime;

  /// Sum of leading empty edits, in microseconds.
  final int emptyEditDelayUs;

  /// For encrypted entries (encv/enca): the 'frma' original format.
  final String? originalFormat;

  /// Audio: objectTypeIndication of the DecoderConfigDescriptor (0x40 = MPEG-4
  /// audio), 0 if absent.
  final int objectTypeIndication;

  /// Audio: SBR output sample rate for explicit HE-AAC signalling.
  final int? extensionSampleRate;

  /// ISO 639-2 language code from 'mdhd'.
  final String language;

  /// True when at least one sample came from a movie fragment.
  final bool fragmented;

  /// Number of sync samples.
  final int syncSampleCount;

  /// Decode time of [s] in microseconds with the edit list applied.
  int dtsUsOf(Mp4SampleInfo s) =>
      mp4TicksToUs(s.dts - editMediaTime, timescale) + emptyEditDelayUs;

  /// Presentation time of [s] in microseconds with the edit list applied.
  int ptsUsOf(Mp4SampleInfo s) =>
      mp4TicksToUs(s.cts - editMediaTime, timescale) + emptyEditDelayUs;

  /// Converts a duration in track timescale units to microseconds.
  int ticksToUs(int ticks) => mp4TicksToUs(ticks, timescale);

  @override
  String toString() =>
      'Mp4Track(#$id $handler $codec'
      '${kind == Mp4TrackKind.video ? ' ${width}x$height' : ''}'
      '${kind == Mp4TrackKind.audio ? ' $sampleRate Hz ${channels}ch' : ''}'
      ' samples=$sampleCount ts=$timescale${supported ? '' : ' unsupported'})';
}

/// Demuxer for ISO BMFF (MP4) files, plain or fragmented.
///
/// [open] reads only the top level box headers, 'ftyp', 'moov' and 'moof'
/// boxes; sample payloads are read on demand.
class Mp4File {
  Mp4File._(
    this._src,
    this.majorBrand,
    this.minorVersion,
    this.brands,
    this._tracks,
    this._tables,
    this.isFragmented,
  );

  final ByteSource _src;

  /// Major brand from 'ftyp', or an empty string when there is no 'ftyp'.
  final String majorBrand;
  final int minorVersion;

  /// Compatible brands from 'ftyp'.
  final List<String> brands;
  final List<Mp4Track> _tracks;
  final Map<int, List<Mp4SampleInfo>> _tables;
  final Map<int, List<int>> _syncIndexCache = <int, List<int>>{};

  /// True when the file has an 'mvex' box or 'moof' boxes.
  final bool isFragmented;

  /// Maximum number of bytes fetched in one [ByteSource.read] when reading
  /// runs of contiguous samples.
  static const int maxBatchBytes = 1 << 20;

  List<Mp4Track> get tracks => List<Mp4Track>.unmodifiable(_tracks);

  /// First supported video track.
  Mp4Track? get firstVideoTrack {
    for (final t in _tracks) {
      if (t.kind == Mp4TrackKind.video && t.supported) return t;
    }
    return null;
  }

  /// First supported audio track.
  Mp4Track? get firstAudioTrack {
    for (final t in _tracks) {
      if (t.kind == Mp4TrackKind.audio && t.supported) return t;
    }
    return null;
  }

  Mp4Track track(int trackId) {
    for (final t in _tracks) {
      if (t.id == trackId) return t;
    }
    throw ArgumentError.value(trackId, 'trackId', 'no such track');
  }

  /// Full sample table of a track in decode order (cached, do not modify).
  List<Mp4SampleInfo> sampleTable(int trackId) {
    final t = _tables[trackId];
    if (t == null) {
      throw ArgumentError.value(trackId, 'trackId', 'no such track');
    }
    return t;
  }

  Mp4Sample _make(Mp4Track t, Mp4SampleInfo s, Uint8List data) => Mp4Sample(
    trackId: t.id,
    index: s.index,
    dtsUs: t.dtsUsOf(s),
    ptsUs: t.ptsUsOf(s),
    durationUs: t.ticksToUs(s.duration),
    isSync: s.isSync,
    offset: s.offset,
    size: s.size,
    data: data,
  );

  static Uint8List _slice(Uint8List chunk, int from, int size) {
    var start = from;
    if (start > chunk.length) start = chunk.length;
    var end = from + size;
    if (end > chunk.length) end = chunk.length;
    return Uint8List.sublistView(chunk, start, end);
  }

  /// Samples of one track in decode order, starting at [startIndex].
  /// Contiguous samples are fetched with one read of up to [maxBatchBytes].
  Stream<Mp4Sample> samples(int trackId, {int startIndex = 0}) async* {
    final t = track(trackId);
    final table = sampleTable(trackId);
    var i = startIndex < 0 ? 0 : startIndex;
    while (i < table.length) {
      final first = table[i];
      var end = first.offset + first.size;
      var j = i + 1;
      while (j < table.length) {
        final s = table[j];
        if (s.offset != end || end + s.size - first.offset > maxBatchBytes) {
          break;
        }
        end += s.size;
        j++;
      }
      final chunk = await _src.read(first.offset, end - first.offset);
      for (var k = i; k < j; k++) {
        final s = table[k];
        yield _make(t, s, _slice(chunk, s.offset - first.offset, s.size));
      }
      i = j;
    }
  }

  /// Samples of the selected tracks (all tracks when [trackIds] is null)
  /// merged by dtsUs, ties broken by file offset.
  Stream<Mp4Sample> interleaved({Set<int>? trackIds}) async* {
    final sel = <Mp4Track>[
      for (final t in _tracks)
        if (trackIds == null || trackIds.contains(t.id)) t,
    ];
    final n = sel.length;
    if (n == 0) return;
    final tables = <List<Mp4SampleInfo>>[for (final t in sel) _tables[t.id]!];
    final pos = List<int>.filled(n, 0);
    final nextDts = List<int>.filled(n, 0);
    void refresh(int k) {
      if (pos[k] < tables[k].length) {
        nextDts[k] = sel[k].dtsUsOf(tables[k][pos[k]]);
      }
    }

    for (var k = 0; k < n; k++) {
      refresh(k);
    }

    int pick() {
      var best = -1;
      for (var k = 0; k < n; k++) {
        if (pos[k] >= tables[k].length) continue;
        if (best < 0) {
          best = k;
          continue;
        }
        final d = nextDts[k];
        final bd = nextDts[best];
        if (d < bd ||
            (d == bd &&
                tables[k][pos[k]].offset < tables[best][pos[best]].offset)) {
          best = k;
        }
      }
      return best;
    }

    final batchTrack = <int>[];
    final batchInfo = <Mp4SampleInfo>[];
    var k = pick();
    while (k >= 0) {
      batchTrack.clear();
      batchInfo.clear();
      final first = tables[k][pos[k]];
      var end = first.offset;
      while (k >= 0) {
        final s = tables[k][pos[k]];
        if (batchInfo.isNotEmpty &&
            (s.offset != end || end + s.size - first.offset > maxBatchBytes)) {
          break;
        }
        batchTrack.add(k);
        batchInfo.add(s);
        end = s.offset + s.size;
        pos[k]++;
        refresh(k);
        k = pick();
      }
      final chunk = await _src.read(first.offset, end - first.offset);
      for (var m = 0; m < batchInfo.length; m++) {
        final s = batchInfo[m];
        yield _make(
          sel[batchTrack[m]],
          s,
          _slice(chunk, s.offset - first.offset, s.size),
        );
      }
    }
  }

  /// Reads one sample.
  Future<Mp4Sample> readSample(int trackId, int index) async {
    final t = track(trackId);
    final table = sampleTable(trackId);
    if (index < 0 || index >= table.length) {
      throw RangeError.index(index, table, 'index');
    }
    final s = table[index];
    final data = await _src.read(s.offset, s.size);
    return _make(t, s, data);
  }

  /// Index of the last sync sample whose presentation time is at or before
  /// [ptsUs]. Falls back to the first sync sample (or 0) when there is none.
  int syncSampleAtOrBefore(int trackId, int ptsUs) {
    final t = track(trackId);
    final table = sampleTable(trackId);
    final syncs = _syncIndexCache.putIfAbsent(trackId, () {
      return <int>[
        for (final s in table)
          if (s.isSync) s.index,
      ];
    });
    if (syncs.isEmpty) return 0;
    var best = -1;
    var bestPts = 0;
    for (final i in syncs) {
      final p = t.ptsUsOf(table[i]);
      if (p <= ptsUs && (best < 0 || p >= bestPts)) {
        best = i;
        bestPts = p;
      }
    }
    return best < 0 ? syncs.first : best;
  }

  /// Parses the file structure. Throws [Mp4FormatException] when there is no
  /// usable 'moov' box.
  static Future<Mp4File> open(ByteSource src) async {
    final len = src.length;
    var off = 0;
    Uint8List? ftyp;
    Uint8List? moov;
    final moofs = <_Moof>[];
    var sawBox = false;
    while (off + 8 <= len) {
      final h = await src.read(off, 16);
      if (h.length < 8) break;
      var size = readU32(h, 0);
      final type = fourcc(h, 4);
      var hdr = 8;
      if (size == 1) {
        if (h.length < 16) break;
        size = readU64(h, 8);
        hdr = 16;
      } else if (size == 0) {
        size = len - off;
      }
      if (size < hdr || !_plausibleType(type)) {
        if (!sawBox) throw const Mp4FormatException('not an MP4 file');
        break;
      }
      sawBox = true;
      final avail = len - off;
      final complete = size <= avail;
      if (type == 'moov') {
        if (!complete) throw const Mp4FormatException('moov box is truncated');
        moov ??= await src.read(off, size);
      } else if (type == 'ftyp') {
        ftyp ??= await src.read(off, complete ? size : avail);
      } else if (type == 'moof' && complete) {
        moofs.add(_Moof(off, await src.read(off, size)));
      }
      off += size;
    }
    if (moov == null) throw const Mp4FormatException('no moov box found');

    var major = '';
    var minor = 0;
    final brands = <String>[];
    if (ftyp != null && ftyp.length >= 16) {
      major = fourcc(ftyp, 8);
      minor = readU32(ftyp, 12);
      for (var o = 16; o + 4 <= ftyp.length; o += 4) {
        brands.add(fourcc(ftyp, o));
      }
    }

    final parser = _MoovParser(moov);
    parser.parse();
    for (final m in moofs) {
      parser.parseMoof(m);
    }
    final tracks = <Mp4Track>[];
    final tables = <int, List<Mp4SampleInfo>>{};
    for (final tb in parser.traks) {
      if (tables.containsKey(tb.id)) continue;
      final table = tb.buildTable();
      tables[tb.id] = table;
      tracks.add(tb.finish(table, parser.movieTimescale));
    }
    return Mp4File._(
      src,
      major,
      minor,
      List<String>.unmodifiable(brands),
      tracks,
      tables,
      parser.hasMvex || moofs.isNotEmpty,
    );
  }

  static bool _plausibleType(String t) {
    for (final c in t.codeUnits) {
      if (c < 0x20 || c > 0x7E) return false;
    }
    return true;
  }
}

class _Moof {
  _Moof(this.offset, this.bytes);
  final int offset;
  final Uint8List bytes;
}

class _Trex {
  _Trex(this.sdi, this.duration, this.size, this.flags);
  final int sdi;
  final int duration;
  final int size;
  final int flags;
}

/// Growable per track sample arrays, used while parsing.
class _TrakBuilder {
  int id = 0;
  String handler = '';
  String language = 'und';
  int timescale = 0;
  int mdhdDuration = 0;
  int tkhdWidth = 0;
  int tkhdHeight = 0;

  // Sample entry.
  String sampleEntry = '';
  String? originalFormat;
  int width = 0;
  int height = 0;
  AvcConfig? avc;
  bool avcInvalid = false;
  bool isHevc = false;
  int entrySampleRate = 0;
  int entryChannels = 0;
  int oti = 0;
  Uint8List? asc;
  int esdsAvgBitrate = 0;

  // Edit list.
  int editMediaTime = 0;
  int emptyDelayMovieTicks = 0;

  // Sample table from stbl, in compact form.
  final List<int> offsets = <int>[];
  final List<int> sizes = <int>[];
  final List<int> dts = <int>[];
  final List<int> ctsOff = <int>[];
  final List<int> durations = <int>[];
  final List<bool> sync = <bool>[];
  bool fromFragments = false;
  int nextFragmentDts = 0;

  List<Mp4SampleInfo> buildTable() {
    final n = sizes.length;
    return List<Mp4SampleInfo>.generate(
      n,
      (i) => Mp4SampleInfo(
        index: i,
        offset: offsets[i],
        size: sizes[i],
        dts: dts[i],
        cts: dts[i] + ctsOff[i],
        duration: durations[i],
        isSync: sync[i],
      ),
      growable: false,
    );
  }

  Mp4Track finish(List<Mp4SampleInfo> table, int movieTimescale) {
    final kind = switch (handler) {
      'vide' => Mp4TrackKind.video,
      'soun' => Mp4TrackKind.audio,
      _ => Mp4TrackKind.other,
    };
    var total = 0;
    var syncCount = 0;
    var sampleSpan = 0;
    if (table.isNotEmpty) {
      final last = table.last;
      sampleSpan = last.dts + last.duration - table.first.dts;
    }
    for (final s in table) {
      total += s.size;
      if (s.isSync) syncCount++;
    }
    var durTs = mdhdDuration;
    if (fromFragments || durTs <= 0 || durTs == 0xFFFFFFFF) {
      durTs = sampleSpan > durTs || durTs == 0xFFFFFFFF ? sampleSpan : durTs;
    }
    if (durTs < 0) durTs = 0;
    final durUs = mp4TicksToUs(durTs, timescale);
    final seconds = durUs / 1e6;
    final bitrate = seconds > 0 ? (total * 8 / seconds).round() : 0;

    final entry = sampleEntry;
    final effective = originalFormat ?? entry;
    var codec = entry;
    var supported = false;
    var sampleRate = 0;
    var channels = 0;
    var aot = 0;
    int? extRate;
    Uint8List? config;
    if (effective == 'avc1' || effective == 'avc3') {
      final a = avc;
      if (a != null) {
        codec = a.codecString(effective);
        config = a.raw;
        supported =
            originalFormat == null && a.sps.isNotEmpty && a.pps.isNotEmpty;
      }
    } else if (effective == 'mp4a') {
      codec = 'mp4a';
      sampleRate = entrySampleRate;
      channels = entryChannels;
      if (oti != 0) codec = 'mp4a.${oti.toRadixString(16)}';
      final ascBytes = asc;
      AudioSpecificConfig? parsed;
      if (ascBytes != null && ascBytes.isNotEmpty) {
        try {
          parsed = AudioSpecificConfig.parse(ascBytes);
        } on Mp4FormatException {
          parsed = null;
        }
      }
      if (parsed != null) {
        aot = parsed.audioObjectType;
        if (parsed.sampleRate > 0) sampleRate = parsed.sampleRate;
        if (parsed.channels > 0) channels = parsed.channels;
        extRate = parsed.extensionSampleRate;
        config = ascBytes;
        if (oti == 0x40) codec = 'mp4a.40.$aot';
      }
      const aacOti = <int>{0x40, 0x66, 0x67, 0x68};
      supported =
          originalFormat == null &&
          aacOti.contains(oti) &&
          parsed != null &&
          channels > 0 &&
          sampleRate > 0;
      if (oti == 0x67 || oti == 0x66 || oti == 0x68) {
        // MPEG-2 AAC profiles map onto MPEG-4 object types 1..3.
        if (aot == 0) aot = oti - 0x66 + 1;
      }
    }
    var w = width;
    var h = height;
    if (kind == Mp4TrackKind.video && (w == 0 || h == 0)) {
      w = tkhdWidth;
      h = tkhdHeight;
    }
    final delayUs = mp4TicksToUs(emptyDelayMovieTicks, movieTimescale);
    return Mp4Track(
      id: id,
      kind: kind,
      handler: handler,
      sampleEntry: entry,
      codec: codec,
      supported: supported && kind != Mp4TrackKind.other,
      width: kind == Mp4TrackKind.video ? w : 0,
      height: kind == Mp4TrackKind.video ? h : 0,
      timescale: timescale,
      durationTs: durTs,
      durationUs: durUs,
      sampleCount: table.length,
      avgBitrate: bitrate,
      frameRate: kind == Mp4TrackKind.video && seconds > 0
          ? table.length / seconds
          : null,
      avc: avc,
      sampleRate: sampleRate,
      channels: channels,
      audioObjectType: aot,
      audioSpecificConfig: effective == 'mp4a' ? asc : null,
      codecConfig: config,
      presentationOffsetUs: delayUs - mp4TicksToUs(editMediaTime, timescale),
      editMediaTime: editMediaTime,
      emptyEditDelayUs: delayUs,
      originalFormat: originalFormat,
      objectTypeIndication: oti,
      extensionSampleRate: extRate,
      language: language,
      fragmented: fromFragments,
      syncSampleCount: syncCount,
    );
  }
}

class _MoovParser {
  _MoovParser(this.b);

  final Uint8List b;
  int movieTimescale = 1000;
  bool hasMvex = false;
  final List<_TrakBuilder> traks = <_TrakBuilder>[];
  final Map<int, _Trex> trex = <int, _Trex>{};

  void parse() {
    // Account for a 64-bit moov header.
    final root = BoxHeader('moov', 0, readU32(b, 0) == 1 ? 16 : 8, b.length);
    for (final c in childBoxes(b, root.body, root.end)) {
      switch (c.type) {
        case 'mvhd':
          _mvhd(c);
        case 'mvex':
          hasMvex = true;
          for (final e in childBoxes(b, c.body, c.end)) {
            if (e.type == 'trex' && e.payloadSize >= 24) {
              final o = e.body + 4;
              trex[readU32(b, o)] = _Trex(
                readU32(b, o + 4),
                readU32(b, o + 8),
                readU32(b, o + 12),
                readU32(b, o + 16),
              );
            }
          }
      }
    }
    for (final c in childBoxes(b, root.body, root.end)) {
      if (c.type == 'trak') {
        final t = _trak(c);
        if (t != null) traks.add(t);
      }
    }
  }

  void _mvhd(BoxHeader h) {
    final o = h.body;
    ensure(o, 4, h.end, 'mvhd');
    final v = b[o];
    final tsAt = v == 1 ? o + 20 : o + 12;
    ensure(tsAt, 4, h.end, 'mvhd');
    final ts = readU32(b, tsAt);
    if (ts > 0) movieTimescale = ts;
  }

  _TrakBuilder? _trak(BoxHeader trak) {
    final t = _TrakBuilder();
    final tkhd = findChild(b, trak.body, trak.end, 'tkhd');
    if (tkhd == null) return null;
    _tkhd(tkhd, t);
    final mdia = findChild(b, trak.body, trak.end, 'mdia');
    if (mdia == null) return null;
    final mdhd = findChild(b, mdia.body, mdia.end, 'mdhd');
    if (mdhd == null) throw const Mp4FormatException('trak without mdhd');
    _mdhd(mdhd, t);
    final hdlr = findChild(b, mdia.body, mdia.end, 'hdlr');
    if (hdlr != null && hdlr.payloadSize >= 12) {
      t.handler = fourcc(b, hdlr.body + 8);
    }
    final elst = findPath(b, trak, const <String>['edts', 'elst']);
    if (elst != null) _elst(elst, t);
    final stbl = findPath(b, mdia, const <String>['minf', 'stbl']);
    if (stbl != null) _stbl(stbl, t);
    return t;
  }

  void _tkhd(BoxHeader h, _TrakBuilder t) {
    final o = h.body;
    ensure(o, 4, h.end, 'tkhd');
    final v = b[o];
    final idAt = v == 1 ? o + 20 : o + 12;
    ensure(idAt, 4, h.end, 'tkhd');
    t.id = readU32(b, idAt);
    // version 1: 4 + 8 + 8 + 4 + 4 + 8 = 36, version 0: 4 + 4 + 4 + 4 + 4 + 4 = 24
    // then reserved 8, layer 2, group 2, volume 2, reserved 2, matrix 36.
    final whAt = (v == 1 ? o + 36 : o + 24) + 52;
    if (whAt + 8 <= h.end) {
      t.tkhdWidth = readU32(b, whAt) >> 16;
      t.tkhdHeight = readU32(b, whAt + 4) >> 16;
    }
  }

  void _mdhd(BoxHeader h, _TrakBuilder t) {
    final o = h.body;
    ensure(o, 4, h.end, 'mdhd');
    final v = b[o];
    int langAt;
    if (v == 1) {
      ensure(o, 36, h.end, 'mdhd');
      t.timescale = readU32(b, o + 20);
      t.mdhdDuration = readU64(b, o + 24);
      langAt = o + 32;
    } else {
      ensure(o, 24, h.end, 'mdhd');
      t.timescale = readU32(b, o + 12);
      t.mdhdDuration = readU32(b, o + 16);
      langAt = o + 20;
    }
    final l = readU16(b, langAt);
    if (l != 0 && l != 0x7FFF) {
      t.language = String.fromCharCodes(<int>[
        ((l >> 10) & 31) + 0x60,
        ((l >> 5) & 31) + 0x60,
        (l & 31) + 0x60,
      ]);
    }
    if (t.timescale == 0) throw const Mp4FormatException('mdhd timescale 0');
  }

  void _elst(BoxHeader h, _TrakBuilder t) {
    final o = h.body;
    if (o + 8 > h.end) return;
    final v = b[o];
    final count = readU32(b, o + 4);
    final entrySize = v == 1 ? 20 : 12;
    var p = o + 8;
    var delay = 0;
    for (var i = 0; i < count && p + entrySize <= h.end; i++, p += entrySize) {
      final segDur = v == 1 ? readU64(b, p) : readU32(b, p);
      final mediaTime = v == 1 ? readI64(b, p + 8) : readI32(b, p + 4);
      if (mediaTime == -1) {
        delay += segDur;
        continue;
      }
      t.editMediaTime = mediaTime;
      break;
    }
    t.emptyDelayMovieTicks = delay;
  }

  void _stbl(BoxHeader stbl, _TrakBuilder t) {
    BoxHeader? stsd, stts, ctts, stsc, stsz, stz2, stco, co64, stss;
    for (final c in childBoxes(b, stbl.body, stbl.end)) {
      switch (c.type) {
        case 'stsd':
          stsd = c;
        case 'stts':
          stts = c;
        case 'ctts':
          ctts = c;
        case 'stsc':
          stsc = c;
        case 'stsz':
          stsz = c;
        case 'stz2':
          stz2 = c;
        case 'stco':
          stco = c;
        case 'co64':
          co64 = c;
        case 'stss':
          stss = c;
      }
    }
    if (stsd != null) _stsd(stsd, t);

    // Sample sizes.
    final sizes = t.sizes;
    if (stsz != null) {
      final o = stsz.body;
      ensure(o, 12, stsz.end, 'stsz');
      final fixed = readU32(b, o + 4);
      final count = readU32(b, o + 8);
      if (fixed != 0) {
        for (var i = 0; i < count; i++) {
          sizes.add(fixed);
        }
      } else {
        ensure(o + 12, count * 4, stsz.end, 'stsz');
        for (var i = 0; i < count; i++) {
          sizes.add(readU32(b, o + 12 + i * 4));
        }
      }
    } else if (stz2 != null) {
      final o = stz2.body;
      ensure(o, 12, stz2.end, 'stz2');
      final field = b[o + 7];
      final count = readU32(b, o + 8);
      final p = o + 12;
      switch (field) {
        case 4:
          ensure(p, (count + 1) >> 1, stz2.end, 'stz2');
          for (var i = 0; i < count; i++) {
            final byte = b[p + (i >> 1)];
            sizes.add((i & 1) == 0 ? byte >> 4 : byte & 15);
          }
        case 8:
          ensure(p, count, stz2.end, 'stz2');
          for (var i = 0; i < count; i++) {
            sizes.add(b[p + i]);
          }
        case 16:
          ensure(p, count * 2, stz2.end, 'stz2');
          for (var i = 0; i < count; i++) {
            sizes.add(readU16(b, p + i * 2));
          }
        default:
          throw Mp4FormatException('stz2 field size $field');
      }
    }
    final n = sizes.length;
    if (n == 0) return;

    // Chunk offsets.
    final chunks = <int>[];
    if (stco != null) {
      final o = stco.body;
      ensure(o, 8, stco.end, 'stco');
      final count = readU32(b, o + 4);
      ensure(o + 8, count * 4, stco.end, 'stco');
      for (var i = 0; i < count; i++) {
        chunks.add(readU32(b, o + 8 + i * 4));
      }
    } else if (co64 != null) {
      final o = co64.body;
      ensure(o, 8, co64.end, 'co64');
      final count = readU32(b, o + 4);
      ensure(o + 8, count * 8, co64.end, 'co64');
      for (var i = 0; i < count; i++) {
        chunks.add(readU64(b, o + 8 + i * 8));
      }
    } else {
      throw const Mp4FormatException('stbl without stco/co64');
    }
    if (stsc == null) throw const Mp4FormatException('stbl without stsc');

    // Sample to chunk.
    final offsets = t.offsets;
    {
      final o = stsc.body;
      ensure(o, 8, stsc.end, 'stsc');
      final count = readU32(b, o + 4);
      ensure(o + 8, count * 12, stsc.end, 'stsc');
      var sample = 0;
      for (var e = 0; e < count && sample < n; e++) {
        final p = o + 8 + e * 12;
        final firstChunk = readU32(b, p);
        final perChunk = readU32(b, p + 4);
        final lastChunk = e + 1 < count
            ? readU32(b, p + 12) - 1
            : chunks.length;
        for (var c = firstChunk; c <= lastChunk && sample < n; c++) {
          if (c < 1 || c > chunks.length) break;
          var off = chunks[c - 1];
          for (var k = 0; k < perChunk && sample < n; k++) {
            offsets.add(off);
            off += sizes[sample];
            sample++;
          }
        }
      }
      if (sample < n) {
        // Sample table references more samples than chunks hold: drop them.
        sizes.length = sample;
      }
    }
    final count = sizes.length;

    // Decode times.
    final dts = t.dts;
    final durs = t.durations;
    if (stts != null) {
      final o = stts.body;
      ensure(o, 8, stts.end, 'stts');
      final entries = readU32(b, o + 4);
      ensure(o + 8, entries * 8, stts.end, 'stts');
      var cur = 0;
      for (var e = 0; e < entries && dts.length < count; e++) {
        final c = readU32(b, o + 8 + e * 8);
        final d = readU32(b, o + 12 + e * 8);
        for (var k = 0; k < c && dts.length < count; k++) {
          dts.add(cur);
          durs.add(d);
          cur += d;
        }
      }
      while (dts.length < count) {
        dts.add(cur);
        durs.add(0);
      }
    } else {
      for (var i = 0; i < count; i++) {
        dts.add(0);
        durs.add(0);
      }
    }

    // Composition offsets. Version 0 is read as signed too, like most
    // demuxers, since some writers store negative values there.
    final cto = t.ctsOff;
    if (ctts != null) {
      final o = ctts.body;
      ensure(o, 8, ctts.end, 'ctts');
      final entries = readU32(b, o + 4);
      ensure(o + 8, entries * 8, ctts.end, 'ctts');
      for (var e = 0; e < entries && cto.length < count; e++) {
        final c = readU32(b, o + 8 + e * 8);
        final off = readI32(b, o + 12 + e * 8);
        for (var k = 0; k < c && cto.length < count; k++) {
          cto.add(off);
        }
      }
    }
    while (cto.length < count) {
      cto.add(0);
    }

    // Sync samples.
    final sync = t.sync;
    if (stss != null) {
      for (var i = 0; i < count; i++) {
        sync.add(false);
      }
      final o = stss.body;
      ensure(o, 8, stss.end, 'stss');
      final entries = readU32(b, o + 4);
      ensure(o + 8, entries * 4, stss.end, 'stss');
      for (var e = 0; e < entries; e++) {
        final k = readU32(b, o + 8 + e * 4);
        if (k >= 1 && k <= count) sync[k - 1] = true;
      }
    } else {
      for (var i = 0; i < count; i++) {
        sync.add(true);
      }
    }
    if (count > 0) {
      t.nextFragmentDts = dts[count - 1] + durs[count - 1];
    }
  }

  void _stsd(BoxHeader stsd, _TrakBuilder t) {
    final o = stsd.body;
    if (o + 8 > stsd.end) return;
    final entry = findFirstEntry(o + 8, stsd.end);
    if (entry == null) return;
    t.sampleEntry = entry.type;
    final type = entry.type;
    final isVideoEntry =
        const <String>{
          'avc1', 'avc3', 'hvc1', 'hev1', 'encv', 'mp4v', 'av01', 'vp09', //
        }.contains(type) ||
        t.handler == 'vide';
    final isAudioEntry =
        const <String>{'mp4a', 'enca'}.contains(type) || t.handler == 'soun';
    int childStart;
    if (isVideoEntry && t.handler != 'soun') {
      final p = entry.body;
      if (p + 78 > entry.end) return;
      t.width = readU16(b, p + 24);
      t.height = readU16(b, p + 26);
      childStart = p + 78;
    } else if (isAudioEntry) {
      final p = entry.body;
      if (p + 28 > entry.end) return;
      final qtVersion = readU16(b, p + 8);
      t.entryChannels = readU16(b, p + 16);
      t.entrySampleRate = readU32(b, p + 24) >> 16;
      childStart = p + 28;
      if (qtVersion == 1) {
        childStart = p + 44;
      } else if (qtVersion == 2 && p + 64 <= entry.end) {
        final bd = ByteData.sublistView(b, p + 32, p + 40);
        t.entrySampleRate = bd.getFloat64(0).round();
        t.entryChannels = readU32(b, p + 40);
        childStart = p + 64;
      }
    } else {
      return;
    }
    if (childStart > entry.end) return;
    final sinf = findChild(b, childStart, entry.end, 'sinf');
    if (sinf != null) {
      final frma = findChild(b, sinf.body, sinf.end, 'frma');
      if (frma != null && frma.payloadSize >= 4) {
        t.originalFormat = fourcc(b, frma.body);
      }
    } else if (type == 'encv' || type == 'enca') {
      t.originalFormat = type;
    }
    for (final c in childBoxes(b, childStart, entry.end)) {
      switch (c.type) {
        case 'avcC':
          try {
            t.avc = AvcConfig.parse(Uint8List.sublistView(b, c.body, c.end));
          } on Mp4FormatException {
            t.avcInvalid = true;
          }
        case 'hvcC':
          t.isHevc = true;
        case 'esds':
          _esds(c, t);
        case 'wave':
          final e = findChild(b, c.body, c.end, 'esds');
          if (e != null) _esds(e, t);
      }
    }
  }

  BoxHeader? findFirstEntry(int start, int end) {
    for (final c in childBoxes(b, start, end)) {
      return c;
    }
    return null;
  }

  /// Parses an 'esds' box: ES_Descriptor, DecoderConfigDescriptor and
  /// DecoderSpecificInfo (ISO 14496-1 7.2.6).
  void _esds(BoxHeader h, _TrakBuilder t) {
    var p = h.body + 4; // version and flags
    final end = h.end;

    // Returns (tag, length, payload start) or null.
    (int, int, int)? desc(int at, int limit) {
      if (at + 2 > limit) return null;
      final tag = b[at];
      var q = at + 1;
      var len = 0;
      for (var i = 0; i < 4; i++) {
        if (q >= limit) return null;
        final c = b[q++];
        len = (len << 7) | (c & 0x7F);
        if ((c & 0x80) == 0) break;
      }
      if (q + len > limit) len = limit - q;
      return (tag, len, q);
    }

    final es = desc(p, end);
    if (es == null || es.$1 != 3) return;
    final esEnd = es.$3 + es.$2;
    p = es.$3;
    if (p + 3 > esEnd) return;
    final flags = b[p + 2];
    p += 3;
    if ((flags & 0x80) != 0) p += 2; // dependsOn_ES_ID
    if ((flags & 0x40) != 0) {
      if (p >= esEnd) return;
      p += 1 + b[p]; // URL
    }
    if ((flags & 0x20) != 0) p += 2; // OCR_ES_Id
    while (p < esEnd) {
      final d = desc(p, esEnd);
      if (d == null) return;
      final (tag, len, body) = d;
      if (tag == 4 && len >= 13) {
        t.oti = b[body];
        t.esdsAvgBitrate = readU32(b, body + 9);
        var q = body + 13;
        final dEnd = body + len;
        while (q < dEnd) {
          final s = desc(q, dEnd);
          if (s == null) break;
          if (s.$1 == 5) {
            t.asc = Uint8List.fromList(
              Uint8List.sublistView(b, s.$3, s.$3 + s.$2),
            );
            break;
          }
          q = s.$3 + s.$2;
        }
        return;
      }
      p = body + len;
    }
  }

  /// Parses one 'moof' and appends its samples to the matching tracks.
  void parseMoof(_Moof moof) {
    final m = moof.bytes;
    final base0 = moof.offset;
    final hdr = readU32(m, 0) == 1 ? 16 : 8;
    var prevTrafEnd = base0;
    for (final traf in childBoxes(m, hdr, m.length)) {
      if (traf.type != 'traf') continue;
      final tfhd = findChild(m, traf.body, traf.end, 'tfhd');
      if (tfhd == null || tfhd.payloadSize < 8) continue;
      var p = tfhd.body;
      final tfFlags = readU24(m, p + 1);
      final trackId = readU32(m, p + 4);
      p += 8;
      _TrakBuilder? t;
      for (final x in traks) {
        if (x.id == trackId) {
          t = x;
          break;
        }
      }
      if (t == null) continue;
      final tx = trex[trackId];
      int need(int n) {
        if (p + n > tfhd.end) {
          throw const Mp4FormatException('tfhd box is truncated');
        }
        final at = p;
        p += n;
        return at;
      }

      int base;
      if ((tfFlags & 0x1) != 0) {
        base = readU64(m, need(8));
      } else if ((tfFlags & 0x20000) != 0) {
        base = base0;
      } else {
        base = prevTrafEnd;
      }
      if ((tfFlags & 0x2) != 0) need(4); // sample description index
      final defDur = (tfFlags & 0x8) != 0
          ? readU32(m, need(4))
          : (tx?.duration ?? 0);
      final defSize = (tfFlags & 0x10) != 0
          ? readU32(m, need(4))
          : (tx?.size ?? 0);
      final defFlags = (tfFlags & 0x20) != 0
          ? readU32(m, need(4))
          : (tx?.flags ?? 0);

      final tfdt = findChild(m, traf.body, traf.end, 'tfdt');
      if (tfdt != null && tfdt.payloadSize >= 8) {
        t.nextFragmentDts = m[tfdt.body] == 1 && tfdt.payloadSize >= 12
            ? readU64(m, tfdt.body + 4)
            : readU32(m, tfdt.body + 4);
      }
      var cursor = base;
      for (final trun in childBoxes(m, traf.body, traf.end)) {
        if (trun.type != 'trun') continue;
        cursor = _trun(m, trun, t, base, cursor, defDur, defSize, defFlags);
      }
      prevTrafEnd = cursor;
    }
  }

  int _trun(
    Uint8List m,
    BoxHeader h,
    _TrakBuilder t,
    int base,
    int cursor,
    int defDur,
    int defSize,
    int defFlags,
  ) {
    var p = h.body;
    if (p + 8 > h.end) return cursor;
    final version = m[p];
    final f = readU24(m, p + 1);
    final count = readU32(m, p + 4);
    p += 8;
    if ((f & 0x1) != 0) {
      if (p + 4 > h.end) return cursor;
      cursor = base + readI32(m, p);
      p += 4;
    }
    int? firstFlags;
    if ((f & 0x4) != 0) {
      if (p + 4 > h.end) return cursor;
      firstFlags = readU32(m, p);
      p += 4;
    }
    final hasDur = (f & 0x100) != 0;
    final hasSize = (f & 0x200) != 0;
    final hasFlags = (f & 0x400) != 0;
    final hasCto = (f & 0x800) != 0;
    final per =
        (hasDur ? 4 : 0) +
        (hasSize ? 4 : 0) +
        (hasFlags ? 4 : 0) +
        (hasCto ? 4 : 0);
    var dts = t.nextFragmentDts;
    for (var i = 0; i < count; i++) {
      if (per > 0 && p + per > h.end) break;
      final dur = hasDur ? readU32(m, p) : defDur;
      if (hasDur) p += 4;
      final size = hasSize ? readU32(m, p) : defSize;
      if (hasSize) p += 4;
      var flags = hasFlags ? readU32(m, p) : defFlags;
      if (hasFlags) p += 4;
      if (i == 0 && firstFlags != null && !hasFlags) flags = firstFlags;
      var cto = 0;
      if (hasCto) {
        cto = version == 0 ? readU32(m, p) : readI32(m, p);
        if (version == 0 && cto >= 0x80000000) cto -= 0x100000000;
        p += 4;
      }
      final dependsOn = (flags >> 24) & 3;
      final nonSync = (flags & 0x10000) != 0;
      t.offsets.add(cursor);
      t.sizes.add(size);
      t.dts.add(dts);
      t.ctsOff.add(cto);
      t.durations.add(dur);
      t.sync.add(dependsOn == 2 || !nonSync);
      cursor += size;
      dts += dur;
    }
    t.nextFragmentDts = dts;
    t.fromFragments = true;
    return cursor;
  }
}
