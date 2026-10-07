// Pure Dart AAC-LC decoder (ISO/IEC 14496-3 general audio, object type 2).
//
// Supported: SCE, CPE, LFE, DSE, FIL, PCE (CCE is parsed and ignored),
// ICS info with long/start/stop/eight-short windows and grouping, section
// data, scale factors, all 11 spectral Huffman codebooks with escapes,
// pulse data, TNS, M/S stereo, intensity stereo, PNS, sine and KBD windows,
// IMDCT and overlap-add. The signal path mirrors FFmpeg's native float
// decoder so the PCM output matches it within rounding.
//
// HE-AAC (SBR/PS) is not decoded: when it is signalled the LC core is
// decoded at the core sample rate and [AacDecoder.sbrSignalled] is set.
//
// Library code only uses dart:typed_data and dart:math so it also runs on
// the web.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:esp32_datv/core/codec/frame.dart';

import 'aac_tables.dart';

/// Sampling frequencies indexed by sampling_frequency_index.
const List<int> aacSampleRates = [
  96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, //
  11025, 8000, 7350,
];

/// Maps an arbitrary sample rate to the nearest sampling frequency index
/// (same thresholds as ISO/IEC 14496-3 table 4.82).
int aacSamplingIndexForRate(int rate) {
  const thresholds = [
    92017, 75132, 55426, 46009, 37566, 27713, 23004, 18783, 13856, 11502, //
    9391,
  ];
  for (var i = 0; i < thresholds.length; i++) {
    if (rate >= thresholds[i]) return i;
  }
  return 11;
}

/// Parsed AudioSpecificConfig (or the equivalent ADTS header fields).
class AacConfig {
  AacConfig({
    required this.objectType,
    required this.samplingIndex,
    required this.sampleRate,
    required this.channelConfig,
    required this.channels,
    this.sbrSignalled = false,
    this.psSignalled = false,
    this.extensionSampleRate = 0,
    this.pceElements = const [],
  });

  /// Core audio object type (2 = AAC-LC). For explicit HE-AAC signalling this
  /// is the underlying core type, not 5 or 29.
  final int objectType;
  final int samplingIndex;

  /// Core sample rate (the rate at which this decoder outputs PCM).
  final int sampleRate;
  final int channelConfig;

  /// Output channel count.
  final int channels;

  /// True when SBR (HE-AAC) is explicitly signalled in the config.
  final bool sbrSignalled;

  /// True when PS (HE-AAC v2) is explicitly signalled in the config.
  final bool psSignalled;

  /// SBR output sample rate when [sbrSignalled], else 0.
  final int extensionSampleRate;

  /// Element list from a program_config_element as (type << 4 | tag),
  /// in output order. Empty when channelConfig != 0.
  final List<int> pceElements;

  /// Parses an AudioSpecificConfig.
  factory AacConfig.parse(Uint8List asc) {
    final r = _Bits(asc);
    int readAot() {
      final a = r.read(5);
      return a == 31 ? 32 + r.read(6) : a;
    }

    int readRate(void Function(int) setIndex) {
      final idx = r.read(4);
      if (idx == 15) {
        final rate = r.read(24);
        setIndex(aacSamplingIndexForRate(rate));
        return rate;
      }
      if (idx >= aacSampleRates.length) {
        throw const FormatException('AAC: reserved sampling index');
      }
      setIndex(idx);
      return aacSampleRates[idx];
    }

    var aot = readAot();
    var sfi = 0;
    final rate = readRate((i) => sfi = i);
    final chanConfig = r.read(4);
    var sbr = false, ps = false;
    var extRate = 0;
    if (aot == 5 || aot == 29) {
      sbr = true;
      ps = aot == 29;
      extRate = readRate((_) {});
      aot = readAot();
      if (aot == 22) r.read(4);
    }
    var pce = const <int>[];
    var pceChannels = 0;
    const gaTypes = {1, 2, 3, 4, 6, 7, 17, 19, 20, 21, 22, 23};
    if (gaTypes.contains(aot)) {
      if (r.read(1) == 1) {
        throw UnsupportedError('AAC: 960-sample frames are not supported');
      }
      if (r.read(1) == 1) r.read(14); // dependsOnCoreCoder
      final extFlag = r.read(1);
      if (chanConfig == 0) {
        final p = _parsePce(r);
        pce = p.elements;
        pceChannels = p.channels;
      }
      if (aot == 6 || aot == 20) r.read(3);
      if (extFlag == 1) {
        if (aot == 22) r.read(16);
        if (aot == 17 || aot == 19 || aot == 20 || aot == 23) r.read(3);
        r.read(1);
      }
    }
    // Backward compatible (sync extension) SBR/PS signalling.
    if (!sbr && r.bitsLeft >= 16) {
      if (r.read(11) == 0x2b7) {
        final extAot = readAot();
        if (extAot == 5) {
          sbr = r.read(1) == 1;
          if (sbr) {
            extRate = readRate((_) {});
            if (r.bitsLeft >= 12 && r.read(11) == 0x548) ps = r.read(1) == 1;
          }
        }
      }
    }
    return AacConfig(
      objectType: aot,
      samplingIndex: sfi,
      sampleRate: rate,
      channelConfig: chanConfig,
      channels: chanConfig == 0
          ? pceChannels
          : (chanConfig < 8 ? const [0, 1, 2, 3, 4, 5, 6, 8][chanConfig] : 0),
      sbrSignalled: sbr,
      psSignalled: ps,
      extensionSampleRate: extRate,
      pceElements: pce,
    );
  }

  /// Builds a minimal 2-byte AudioSpecificConfig for an LC stream.
  static Uint8List buildAsc(int objectType, int samplingIndex, int chanConfig) {
    final v = (objectType << 11) | (samplingIndex << 7) | (chanConfig << 3);
    return Uint8List.fromList([v >> 8, v & 0xff]);
  }
}

class _Pce {
  _Pce(this.elements, this.channels);
  final List<int> elements;
  final int channels;
}

_Pce _parsePce(_Bits r) {
  r.read(4); // element_instance_tag
  r.read(2); // object_type
  r.read(4); // sampling_frequency_index
  final nFront = r.read(4), nSide = r.read(4), nBack = r.read(4);
  final nLfe = r.read(2), nAssoc = r.read(3), nCc = r.read(4);
  if (r.read(1) == 1) r.read(4);
  if (r.read(1) == 1) r.read(4);
  if (r.read(1) == 1) r.read(3);
  final elements = <int>[];
  var channels = 0;
  for (final n in [nFront, nSide, nBack]) {
    for (var i = 0; i < n; i++) {
      final isCpe = r.read(1) == 1;
      final tag = r.read(4);
      elements.add(((isCpe ? _typeCpe : _typeSce) << 4) | tag);
      channels += isCpe ? 2 : 1;
    }
  }
  for (var i = 0; i < nLfe; i++) {
    elements.add((_typeLfe << 4) | r.read(4));
    channels++;
  }
  for (var i = 0; i < nAssoc; i++) {
    r.read(4);
  }
  for (var i = 0; i < nCc; i++) {
    r.read(5);
  }
  r.alignByte();
  final comment = r.read(8);
  r.skip(8 * comment);
  return _Pce(elements, channels);
}

/// One ADTS frame: parsed header fields and the raw payload.
class AdtsFrame {
  AdtsFrame({
    required this.objectType,
    required this.samplingIndex,
    required this.channelConfig,
    required this.protectionAbsent,
    required this.frameLength,
    required this.headerLength,
    required this.rawDataBlocks,
    required this.payload,
  });

  /// Audio object type (profile + 1), normally 2 for LC.
  final int objectType;
  final int samplingIndex;
  final int channelConfig;
  final bool protectionAbsent;

  /// Total frame length in bytes including the header.
  final int frameLength;

  /// Header length in bytes (7, or 9 with CRC).
  final int headerLength;

  /// Number of raw_data_blocks in this frame (1..4).
  final int rawDataBlocks;

  /// The raw_data_block bytes (everything after the header).
  final Uint8List payload;

  int get sampleRate => aacSampleRates[samplingIndex];

  /// Equivalent AudioSpecificConfig.
  Uint8List get audioSpecificConfig =>
      AacConfig.buildAsc(objectType, samplingIndex, channelConfig);

  /// Parses one ADTS frame at [offset] of [data]. Returns null when there is
  /// no sync word there or the frame is truncated.
  static AdtsFrame? parse(Uint8List data, [int offset = 0]) {
    if (offset + 7 > data.length) return null;
    if (data[offset] != 0xff || (data[offset + 1] & 0xf6) != 0xf0) {
      return null;
    }
    final protAbsent = (data[offset + 1] & 1) == 1;
    final profile = data[offset + 2] >> 6;
    final sfi = (data[offset + 2] >> 2) & 0xf;
    if (sfi >= aacSampleRates.length) return null;
    final chan = ((data[offset + 2] & 1) << 2) | (data[offset + 3] >> 6);
    final len =
        ((data[offset + 3] & 3) << 11) |
        (data[offset + 4] << 3) |
        (data[offset + 5] >> 5);
    final blocks = (data[offset + 6] & 3) + 1;
    final hdr = protAbsent ? 7 : (blocks == 1 ? 9 : 7 + 2 * blocks);
    if (len < hdr || offset + len > data.length) return null;
    return AdtsFrame(
      objectType: profile + 1,
      samplingIndex: sfi,
      channelConfig: chan,
      protectionAbsent: protAbsent,
      frameLength: len,
      headerLength: hdr,
      rawDataBlocks: blocks,
      payload: Uint8List.sublistView(data, offset + hdr, offset + len),
    );
  }

  /// Splits an ADTS byte stream into frames, resynchronising on garbage.
  static Iterable<AdtsFrame> split(Uint8List data) sync* {
    var pos = 0;
    while (pos + 7 <= data.length) {
      final f = parse(data, pos);
      if (f == null) {
        pos++;
        continue;
      }
      yield f;
      pos += f.frameLength;
    }
  }
}

/// Builds a 7-byte ADTS header (no CRC, one raw data block) for passthrough
/// remuxing of raw AAC frames.
///
/// [frameLength] is the length of the raw_data_block payload in bytes, NOT
/// including the header; the header's frame_length field is set to
/// [frameLength] + 7. Explicit SBR/PS configs are written with the LC core
/// type and core sampling index (implicit signalling), as ADTS requires.
Uint8List adtsHeader(Uint8List asc, int frameLength) {
  final c = AacConfig.parse(asc);
  final full = frameLength + 7;
  if (full > 0x1fff) throw ArgumentError('ADTS frame too long: $full');
  final profile = (c.objectType - 1) & 3;
  final chan = c.channelConfig & 7;
  return Uint8List.fromList([
    0xff,
    0xf1,
    (profile << 6) | (c.samplingIndex << 2) | (chan >> 2),
    ((chan & 3) << 6) | (full >> 11),
    (full >> 3) & 0xff,
    ((full & 7) << 5) | 0x1f,
    0xfc,
  ]);
}

// ---------------------------------------------------------------------------
// Bit reader

class _Bits {
  _Bits(Uint8List data)
    : _b = Uint8List(data.length + 8),
      _lenBits = data.length * 8 {
    _b.setRange(0, data.length, data);
  }

  final Uint8List _b;
  final int _lenBits;
  int pos = 0;

  int get bitsLeft => _lenBits - pos;

  /// Peeks up to 25 bits.
  @pragma('vm:prefer-inline')
  int peek(int n) {
    final p = pos >> 3;
    final b = _b;
    final w = (b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3];
    return (w >>> (32 - (pos & 7) - n)) & ((1 << n) - 1);
  }

  @pragma('vm:prefer-inline')
  int read(int n) {
    if (n > 24) {
      final hi = read(n - 16);
      return (hi << 16) | read(16);
    }
    if (pos + n > _lenBits) _overread();
    final v = peek(n);
    pos += n;
    return v;
  }

  @pragma('vm:prefer-inline')
  int read1() {
    if (pos >= _lenBits) _overread();
    final v = (_b[pos >> 3] >> (7 - (pos & 7))) & 1;
    pos++;
    return v;
  }

  void skip(int n) {
    pos += n;
    if (pos > _lenBits) _overread();
  }

  void alignByte() => pos = (pos + 7) & ~7;

  Never _overread() => throw const FormatException('AAC: bitstream overread');

  /// Decodes one symbol from a multi-level lookup table.
  @pragma('vm:prefer-inline')
  int vlc(_Vlc v) {
    var bits = v.rootBits;
    var off = 0;
    final t = v.table;
    while (true) {
      final e = t[off + peek(bits)];
      if (e >= 0) {
        pos += e & 31;
        if (pos > _lenBits) _overread();
        return e >> 5;
      }
      pos += bits;
      final x = -1 - e;
      off = x >> 5;
      bits = x & 31;
    }
  }
}

// ---------------------------------------------------------------------------
// Huffman lookup tables
//
// Entry >= 0: leaf, (symbol << 5) | bitsToConsume.
// Entry < 0: -1 - ((subTableOffset << 5) | subTableBits).

class _Vlc {
  _Vlc(List<int> codes, List<int> lens, this.rootBits) {
    final entries = List<int>.filled(1 << rootBits, 0, growable: true);
    _fill(
      entries,
      0,
      rootBits,
      List<int>.generate(codes.length, (i) => i),
      0,
      codes,
      lens,
    );
    table = Int32List.fromList(entries);
  }

  final int rootBits;
  late final Int32List table;

  void _fill(
    List<int> e,
    int off,
    int bits,
    List<int> syms,
    int prefix,
    List<int> codes,
    List<int> lens,
  ) {
    final groups = <int, List<int>>{};
    for (final s in syms) {
      final rem = lens[s] - prefix;
      final code = codes[s] & ((1 << rem) - 1);
      if (rem <= bits) {
        final base = code << (bits - rem);
        final n = 1 << (bits - rem);
        for (var i = 0; i < n; i++) {
          e[off + base + i] = (s << 5) | rem;
        }
      } else {
        groups.putIfAbsent(code >> (rem - bits), () => []).add(s);
      }
    }
    groups.forEach((top, g) {
      var maxRem = 0;
      for (final s in g) {
        maxRem = math.max(maxRem, lens[s] - prefix - bits);
      }
      final sub = math.min(maxRem, rootBits);
      final subOff = e.length;
      e.addAll(List<int>.filled(1 << sub, 0));
      e[off + top] = -1 - ((subOff << 5) | sub);
      _fill(e, subOff, sub, g, prefix + bits, codes, lens);
    });
  }
}

/// Spectral codebook metadata and unpacked symbol values.
class _Codebook {
  _Codebook(int cb)
    : vlc = _Vlc(aacSpectralCodes[cb - 1], aacSpectralBits[cb - 1], 8),
      quad = cb <= 4,
      unsigned = !(cb == 1 || cb == 2 || cb == 5 || cb == 6),
      escape = cb == 11 {
    final n = aacSpectralCodes[cb - 1].length;
    final dim = quad ? 4 : 2;
    final mod = cb <= 4
        ? 3
        : cb <= 6
        ? 9
        : cb <= 8
        ? 8
        : cb <= 10
        ? 13
        : 17;
    final off = unsigned ? 0 : (mod - 1) >> 1;
    vals = Int8List(n * dim);
    for (var s = 0; s < n; s++) {
      var x = s;
      for (var d = dim - 1; d >= 0; d--) {
        vals[s * dim + d] = (x % mod) - off;
        x ~/= mod;
      }
    }
  }

  final _Vlc vlc;
  final bool quad;
  final bool unsigned;
  final bool escape;
  late final Int8List vals;
}

// ---------------------------------------------------------------------------
// Shared constant tables

class _Tables {
  _Tables._() {
    for (var i = 0; i < pow43.length; i++) {
      pow43[i] = math.pow(i, 4.0 / 3.0).toDouble();
    }
    for (var i = 0; i < 256; i++) {
      sfGain[i] = -math.pow(2.0, (i - 100) / 4.0).toDouble();
    }
    for (var i = 0; i < 1024; i++) {
      sine1024[i] = math.sin((i + 0.5) * (math.pi / 2048.0));
    }
    for (var i = 0; i < 128; i++) {
      sine128[i] = math.sin((i + 0.5) * (math.pi / 256.0));
    }
    _kbd(kbd1024, 4.0, 1024);
    _kbd(kbd128, 6.0, 128);
  }

  static final _Tables instance = _Tables._();

  final Float64List pow43 = Float64List(8224);
  final Float64List sfGain = Float64List(256);
  final Float64List sine1024 = Float64List(1024);
  final Float64List sine128 = Float64List(128);
  final Float64List kbd1024 = Float64List(1024);
  final Float64List kbd128 = Float64List(128);
  final _Vlc scalefactor = _Vlc(aacScalefactorCodes, aacScalefactorBits, 8);
  final List<_Codebook> codebooks = List<_Codebook>.generate(
    11,
    (i) => _Codebook(i + 1),
  );
  final _Imdct imdctLong = _Imdct(2048, 1.0 / 1024.0);
  final _Imdct imdctShort = _Imdct(256, 1.0 / 128.0);

  static void _kbd(Float64List w, double alpha, int n) {
    final local = Float64List(n);
    var sum = 0.0;
    final a2 = (alpha * math.pi / n) * (alpha * math.pi / n);
    for (var i = 0; i < n; i++) {
      final tmp = i * (n - i) * a2;
      var bessel = 1.0;
      for (var j = 50; j > 0; j--) {
        bessel = bessel * tmp / (j * j) + 1;
      }
      sum += bessel;
      local[i] = sum;
    }
    sum++;
    for (var i = 0; i < n; i++) {
      w[i] = math.sqrt(local[i] / sum);
    }
  }
}

// ---------------------------------------------------------------------------
// IMDCT (FFmpeg-compatible "half" IMDCT via an N/4 point complex FFT)

class _Imdct {
  _Imdct(this.n, double scale)
    : tcos = Float64List(n >> 2),
      tsin = Float64List(n >> 2),
      re = Float64List(n >> 2),
      im = Float64List(n >> 2),
      _fft = _Fft(n >> 2) {
    final s = math.sqrt(scale);
    for (var i = 0; i < (n >> 2); i++) {
      final a = 2 * math.pi * (i + 1.0 / 8.0) / n;
      tcos[i] = -math.cos(a) * s;
      tsin[i] = -math.sin(a) * s;
    }
  }

  final int n;
  final Float64List tcos, tsin, re, im;
  final _Fft _fft;

  /// Writes the n/2 middle samples of the IMDCT of input[inOff..inOff+n/2).
  void half(Float64List input, int inOff, Float64List out, int outOff) {
    final n2 = n >> 1, n4 = n >> 2, n8 = n >> 3;
    final re = this.re, im = this.im, tc = tcos, ts = tsin;
    for (var k = 0; k < n4; k++) {
      final in1 = input[inOff + 2 * k];
      final in2 = input[inOff + n2 - 1 - 2 * k];
      re[k] = in2 * tc[k] - in1 * ts[k];
      im[k] = in2 * ts[k] + in1 * tc[k];
    }
    _fft.run(re, im);
    for (var k = 0; k < n8; k++) {
      final a = n8 - k - 1, b = n8 + k;
      final ar = re[a], ai = im[a], br = re[b], bi = im[b];
      final r0 = ai * ts[a] - ar * tc[a];
      final i1 = ai * tc[a] + ar * ts[a];
      final r1 = bi * ts[b] - br * tc[b];
      final i0 = bi * tc[b] + br * ts[b];
      re[a] = r0;
      im[a] = i0;
      re[b] = r1;
      im[b] = i1;
    }
    for (var j = 0; j < n4; j++) {
      out[outOff + 2 * j] = re[j];
      out[outOff + 2 * j + 1] = im[j];
    }
  }
}

/// In-place radix-2 complex FFT with a positive exponent (FFmpeg "inverse").
class _Fft {
  _Fft(this.n)
    : rev = Int32List(n),
      cosT = Float64List(n >> 1),
      sinT = Float64List(n >> 1) {
    var bits = 0;
    while ((1 << bits) < n) {
      bits++;
    }
    for (var i = 0; i < n; i++) {
      var r = 0;
      for (var b = 0; b < bits; b++) {
        if ((i >> b) & 1 == 1) r |= 1 << (bits - 1 - b);
      }
      rev[i] = r;
    }
    for (var i = 0; i < (n >> 1); i++) {
      cosT[i] = math.cos(2 * math.pi * i / n);
      sinT[i] = math.sin(2 * math.pi * i / n);
    }
  }

  final int n;
  final Int32List rev;
  final Float64List cosT, sinT;

  void run(Float64List re, Float64List im) {
    final n = this.n;
    for (var i = 0; i < n; i++) {
      final j = rev[i];
      if (j > i) {
        final tr = re[i];
        re[i] = re[j];
        re[j] = tr;
        final ti = im[i];
        im[i] = im[j];
        im[j] = ti;
      }
    }
    for (var size = 2; size <= n; size <<= 1) {
      final half = size >> 1;
      final step = n ~/ size;
      for (var i = 0; i < n; i += size) {
        var t = 0;
        for (var j = i; j < i + half; j++) {
          final c = cosT[t], s = sinT[t];
          final k = j + half;
          final xr = re[k], xi = im[k];
          final tr = xr * c - xi * s;
          final ti = xr * s + xi * c;
          re[k] = re[j] - tr;
          im[k] = im[j] - ti;
          re[j] += tr;
          im[j] += ti;
          t += step;
        }
      }
    }
  }
}

/// dst[d..d+2len) = overlap of src0 (falling) and src1 (rising), FFmpeg
/// vector_fmul_window semantics.
@pragma('vm:prefer-inline')
void _fmulWindow(
  Float64List dst,
  int d,
  Float64List src0,
  int s0,
  Float64List src1,
  int s1,
  Float64List win,
  int len,
) {
  d += len;
  s0 += len;
  for (var i = -len, j = len - 1; i < 0; i++, j--) {
    final a = src0[s0 + i];
    final b = src1[s1 + j];
    final wi = win[len + i];
    final wj = win[len + j];
    dst[d + i] = a * wj - b * wi;
    dst[d + j] = a * wi + b * wj;
  }
}

// ---------------------------------------------------------------------------
// Channel state

const int _onlyLong = 0;
const int _longStart = 1;
const int _eightShort = 2;
const int _longStop = 3;

const int _typeSce = 0;
const int _typeCpe = 1;
const int _typeCce = 2;
const int _typeLfe = 3;
const int _typeDse = 4;
const int _typePce = 5;
const int _typeFil = 6;
const int _typeEnd = 7;

const int _btZero = 0;
const int _btNoise = 13;
const int _btIntensity2 = 14;
const int _btIntensity = 15;

class _Ics {
  int winSeq0 = 0, winSeq1 = 0;
  int kb0 = 0, kb1 = 0;
  int maxSfb = 0;
  int numWindowGroups = 1;
  final Int32List groupLen = Int32List(8);
  int numWindows = 1;
  List<int> swbOffset = const [];
  int numSwb = 0;
  int tnsMaxBands = 0;

  void copyFrom(_Ics o) {
    winSeq0 = o.winSeq0;
    winSeq1 = o.winSeq1;
    kb0 = o.kb0;
    kb1 = o.kb1;
    maxSfb = o.maxSfb;
    numWindowGroups = o.numWindowGroups;
    groupLen.setAll(0, o.groupLen);
    numWindows = o.numWindows;
    swbOffset = o.swbOffset;
    numSwb = o.numSwb;
    tnsMaxBands = o.tnsMaxBands;
  }
}

class _Channel {
  final _Ics ics = _Ics();
  final Int32List bandType = Int32List(128);
  final Int32List runEnd = Int32List(128);
  final Float64List sf = Float64List(128);
  final Float64List coef = Float64List(1024);
  final Int32List quant = Int32List(1024);
  final Float64List saved = Float64List(512);
  final Float64List out = Float64List(1024);
  // TNS
  bool tnsPresent = false;
  final Int32List tnsNFilt = Int32List(8);
  final Int32List tnsLength = Int32List(32);
  final Int32List tnsOrder = Int32List(32);
  final Int32List tnsDir = Int32List(32);
  final Float64List tnsCoef = Float64List(32 * 20);
}

class _Element {
  _Element(this.type, int nch)
    : ch = List<_Channel>.generate(nch, (_) => _Channel());
  final int type;
  final List<_Channel> ch;
  final Int32List msMask = Int32List(128);
  int firstOutput = -1;
}

// ---------------------------------------------------------------------------
// Decoder

/// Counters of coding tools seen in the stream (useful for tests).
class AacToolStats {
  int frames = 0;
  int eightShortWindows = 0;
  int startStopWindows = 0;
  int kbdWindows = 0;
  int pnsBands = 0;
  int intensityBands = 0;
  int msBands = 0;
  int tnsFilters = 0;
  int pulses = 0;
  int escapes = 0;
  int sbrPayloads = 0;

  @override
  String toString() =>
      'frames=$frames short=$eightShortWindows '
      'startStop=$startStopWindows kbd=$kbdWindows pns=$pnsBands '
      'is=$intensityBands ms=$msBands tns=$tnsFilters pulses=$pulses '
      'esc=$escapes sbr=$sbrPayloads';
}

/// AAC-LC decoder producing 1024-sample interleaved Int16 PCM blocks.
class AacDecoder {
  AacDecoder(this.config) {
    if (config.objectType != 2) {
      throw UnsupportedError(
        'AAC: object type ${config.objectType} not supported (LC only)',
      );
    }
    sbrSignalled = config.sbrSignalled;
    if (config.channelConfig == 0 && config.pceElements.isNotEmpty) {
      _layout = List<int>.from(config.pceElements);
    } else if (config.channelConfig >= 1 && config.channelConfig <= 7) {
      _layout = List<int>.from(_defaultLayouts[config.channelConfig]);
    }
    _outChannels = config.channels;
  }

  /// Creates a decoder from an MPEG-4 AudioSpecificConfig.
  factory AacDecoder.fromAudioSpecificConfig(Uint8List asc) =>
      AacDecoder(AacConfig.parse(asc));

  /// Creates a decoder from the fields of an ADTS frame.
  factory AacDecoder.fromAdts(AdtsFrame f) =>
      AacDecoder.fromAudioSpecificConfig(f.audioSpecificConfig);

  final AacConfig config;

  /// True when HE-AAC SBR was signalled (explicitly in the config, or
  /// implicitly by SBR extension payloads in the stream). The SBR part is
  /// ignored; output is the LC core at [sampleRate].
  bool sbrSignalled = false;

  /// Tool usage counters, updated while decoding.
  final AacToolStats stats = AacToolStats();

  /// Number of leading output samples (per channel) still to be dropped.
  /// Set this from an MP4 edit list if desired. Like FFmpeg, a libfaac
  /// encoder signature in a fill element adds 1024 (encoder delay).
  int skipSamples = 0;

  /// Output sample rate (core rate).
  int get sampleRate => config.sampleRate;

  /// Output channel count (known after construction for channelConfig 1..7).
  int get channels => _outChannels;

  /// Samples per channel per frame.
  static const int frameSamples = 1024;

  /// Duration of one frame in microseconds.
  int get frameDurationUs => (1024 * 1000000) ~/ sampleRate;

  static const List<List<int>> _defaultLayouts = [
    [],
    [_typeSce << 4],
    [_typeCpe << 4],
    [_typeSce << 4, _typeCpe << 4],
    [_typeSce << 4, _typeCpe << 4, (_typeSce << 4) | 1],
    [_typeSce << 4, _typeCpe << 4, (_typeCpe << 4) | 1],
    [_typeSce << 4, _typeCpe << 4, (_typeCpe << 4) | 1, _typeLfe << 4],
    [
      _typeSce << 4,
      _typeCpe << 4,
      (_typeCpe << 4) | 1,
      (_typeCpe << 4) | 2,
      _typeLfe << 4,
    ],
  ];

  final _Tables _t = _Tables.instance;
  List<int> _layout = [];
  int _outChannels = 0;
  final Map<int, _Element> _elements = {};
  int _randomState = 0x1f2e3d4c;
  final Float64List _buf = Float64List(1024);
  final Float64List _temp = Float64List(128);
  final Float64List _lpc = Float64List(20);
  final _Channel _cceScratch = _Channel();

  /// Decodes one raw_data_block (as stored in MP4 samples).
  PcmBlock decodeFrame(Uint8List rawDataBlock, {int ptsUs = 0}) {
    final r = _Bits(rawDataBlock);
    return _decodeBlock(r, ptsUs);
  }

  /// Decodes all raw_data_blocks of an ADTS frame.
  List<PcmBlock> decodeAdtsFrame(AdtsFrame f, {int ptsUs = 0}) {
    final r = _Bits(f.payload);
    final out = <PcmBlock>[];
    for (var i = 0; i < f.rawDataBlocks; i++) {
      out.add(_decodeBlock(r, ptsUs + i * frameDurationUs));
      r.alignByte();
      if (!f.protectionAbsent && f.rawDataBlocks > 1) r.skip(16);
    }
    return out;
  }

  /// Resets overlap and window state (for seeking).
  void reset() {
    _elements.clear();
    _randomState = 0x1f2e3d4c;
  }

  _Element _element(int type, int id) {
    final key = (type << 4) | id;
    return _elements.putIfAbsent(
      key,
      () => _Element(type, type == _typeCpe ? 2 : 1),
    );
  }

  PcmBlock _decodeBlock(_Bits r, int ptsUs) {
    final decoded = <_Element>[];
    while (true) {
      final type = r.read(3);
      if (type == _typeEnd) break;
      final id = r.read(4);
      switch (type) {
        case _typeSce:
        case _typeLfe:
          final e = _element(type, id);
          _decodeIcs(r, e.ch[0], false);
          decoded.add(e);
        case _typeCpe:
          final e = _element(type, id);
          _decodeCpe(r, e);
          decoded.add(e);
        case _typeCce:
          _decodeCce(r);
        case _typeDse:
          final align = r.read1();
          var count = r.read(8);
          if (count == 255) count += r.read(8);
          if (align == 1) r.alignByte();
          r.skip(8 * count);
        case _typePce:
          final p = _parsePce(r);
          if (_layout.isEmpty) {
            _layout = p.elements;
            _outChannels = p.channels;
          }
        case _typeFil:
          var cnt = id;
          if (cnt == 15) cnt += r.read(8) - 1;
          if (cnt > 0) {
            if (r.bitsLeft < 8 * cnt) r._overread();
            final start = r.pos;
            final ext = r.read(4);
            if (ext == 13 || ext == 14) {
              sbrSignalled = true;
              stats.sbrPayloads++;
            } else if (ext == 0 && 8 * cnt - 4 >= 13 + 7 * 8) {
              r.skip(13);
              final sig = StringBuffer();
              for (var i = 0; i < 7; i++) {
                sig.writeCharCode(r.read(8));
              }
              if (sig.toString() == 'libfaac') skipSamples = 1024;
            }
            r.pos = start + 8 * cnt;
          }
      }
    }
    if (_layout.isEmpty) {
      // No config: assign outputs in order of appearance.
      for (final e in decoded) {
        final key = _elements.entries.firstWhere((x) => x.value == e).key;
        _layout.add(key);
      }
      _outChannels = 0;
      for (final k in _layout) {
        _outChannels += (k >> 4) == _typeCpe ? 2 : 1;
      }
    }
    for (final e in decoded) {
      for (final ch in e.ch) {
        _spectralToSample(ch);
      }
    }
    // Interleave in layout order.
    final nch = _outChannels;
    final pcm = Int16List(1024 * nch);
    var oc = 0;
    for (final key in _layout) {
      final e = _elements[key];
      final count = (key >> 4) == _typeCpe ? 2 : 1;
      for (var c = 0; c < count && oc < nch; c++, oc++) {
        if (e == null || !decoded.contains(e)) continue;
        final src = e.ch[c].out;
        for (var i = 0, j = oc; i < 1024; i++, j += nch) {
          final v = src[i].round();
          pcm[j] = v > 32767 ? 32767 : (v < -32768 ? -32768 : v);
        }
      }
    }
    stats.frames++;
    if (skipSamples > 0 && nch > 0) {
      final drop = math.min(skipSamples, 1024);
      skipSamples -= drop;
      return PcmBlock(
        Int16List.sublistView(pcm, drop * nch),
        sampleRate,
        nch,
        ptsUs: ptsUs + drop * 1000000 ~/ sampleRate,
      );
    }
    return PcmBlock(pcm, sampleRate, nch, ptsUs: ptsUs);
  }

  // -- ICS ------------------------------------------------------------------

  void _decodeIcsInfo(_Bits r, _Ics ics) {
    if (r.read1() == 1) {
      throw const FormatException('AAC: reserved bit set');
    }
    ics.winSeq1 = ics.winSeq0;
    ics.winSeq0 = r.read(2);
    ics.kb1 = ics.kb0;
    ics.kb0 = r.read1();
    if (ics.kb0 == 1) stats.kbdWindows++;
    if (ics.winSeq0 == _eightShort) stats.eightShortWindows++;
    if (ics.winSeq0 == _longStart || ics.winSeq0 == _longStop) {
      stats.startStopWindows++;
    }
    ics.numWindowGroups = 1;
    ics.groupLen[0] = 1;
    final sfi = config.samplingIndex;
    if (ics.winSeq0 == _eightShort) {
      ics.maxSfb = r.read(4);
      for (var i = 0; i < 7; i++) {
        if (r.read1() == 1) {
          ics.groupLen[ics.numWindowGroups - 1]++;
        } else {
          ics.numWindowGroups++;
          ics.groupLen[ics.numWindowGroups - 1] = 1;
        }
      }
      ics.numWindows = 8;
      ics.swbOffset = aacSwbOffset128[sfi];
      ics.numSwb = aacNumSwb128[sfi];
      ics.tnsMaxBands = aacTnsMaxBands128[sfi];
    } else {
      ics.maxSfb = r.read(6);
      ics.numWindows = 1;
      ics.swbOffset = aacSwbOffset1024[sfi];
      ics.numSwb = aacNumSwb1024[sfi];
      ics.tnsMaxBands = aacTnsMaxBands1024[sfi];
      if (r.read1() == 1) {
        throw const FormatException('AAC: prediction not allowed in LC');
      }
    }
    if (ics.maxSfb > ics.numSwb) {
      ics.maxSfb = 0;
      throw const FormatException('AAC: max_sfb exceeds band count');
    }
  }

  void _decodeCpe(_Bits r, _Element e) {
    final c0 = e.ch[0], c1 = e.ch[1];
    final common = r.read1() == 1;
    var msPresent = 0;
    if (common) {
      _decodeIcsInfo(r, c0.ics);
      final kb = c1.ics.kb0;
      c1.ics.copyFrom(c0.ics);
      c1.ics.kb1 = kb;
      msPresent = r.read(2);
      if (msPresent == 3) {
        throw const FormatException('AAC: reserved ms_mask_present');
      }
      final maxIdx = c0.ics.numWindowGroups * c0.ics.maxSfb;
      if (msPresent == 1) {
        for (var i = 0; i < maxIdx; i++) {
          e.msMask[i] = r.read1();
        }
      } else if (msPresent == 2) {
        e.msMask.fillRange(0, maxIdx, 1);
      }
    }
    _decodeIcs(r, c0, common);
    _decodeIcs(r, c1, common);
    if (common && msPresent != 0) _applyMs(e);
    _applyIntensity(e, msPresent);
  }

  void _decodeCce(_Bits r) {
    // Parsed for bitstream sync only; coupling is not applied.
    var couplingPoint = 2 * r.read1();
    final numCoupled = r.read(3);
    var numGain = 0;
    for (var c = 0; c <= numCoupled; c++) {
      numGain++;
      final isCpe = r.read1() == 1;
      r.read(4);
      if (isCpe && r.read(2) == 3) numGain++;
    }
    couplingPoint += (r.read1() | (couplingPoint >> 1));
    r.read1(); // sign
    r.read(2); // scale
    final sce = _cceScratch;
    _decodeIcs(r, sce, false);
    for (var c = 1; c < numGain; c++) {
      final cge = couplingPoint == 3 ? 1 : r.read1();
      if (cge == 1) {
        r.vlc(_t.scalefactor);
      }
      if (couplingPoint != 3 && cge == 0) {
        final ics = sce.ics;
        var idx = 0;
        for (var g = 0; g < ics.numWindowGroups; g++) {
          for (var sfb = 0; sfb < ics.maxSfb; sfb++, idx++) {
            if (sce.bandType[idx] != _btZero) r.vlc(_t.scalefactor);
          }
        }
      }
    }
  }

  void _decodeIcs(_Bits r, _Channel ch, bool commonWindow) {
    final ics = ch.ics;
    final globalGain = r.read(8);
    if (!commonWindow) _decodeIcsInfo(r, ics);
    _decodeBandTypes(r, ch);
    _decodeScalefactors(r, ch, globalGain);
    var pulsePresent = false;
    var numPulse = 0;
    final pulsePos = Int32List(4), pulseAmp = Int32List(4);
    if (r.read1() == 1) {
      if (ics.winSeq0 == _eightShort) {
        throw const FormatException('AAC: pulse data in short window');
      }
      pulsePresent = true;
      numPulse = r.read(2) + 1;
      stats.pulses += numPulse;
      final swb = r.read(6);
      if (swb >= ics.numSwb) throw const FormatException('AAC: bad pulse');
      var pos = ics.swbOffset[swb] + r.read(5);
      final limit = ics.swbOffset[ics.numSwb];
      for (var i = 0; i < numPulse; i++) {
        if (i > 0) pos += r.read(5);
        if (pos >= limit) throw const FormatException('AAC: bad pulse');
        pulsePos[i] = pos;
        pulseAmp[i] = r.read(4);
      }
    }
    ch.tnsPresent = r.read1() == 1;
    if (ch.tnsPresent) _decodeTns(r, ch);
    if (r.read1() == 1) {
      throw UnsupportedError('AAC: gain control (SSR) not supported');
    }
    _decodeSpectrum(r, ch);
    if (pulsePresent) {
      final off = ics.swbOffset;
      var idx = 0;
      for (var i = 0; i < numPulse; i++) {
        final p = pulsePos[i];
        while (off[idx + 1] <= p) {
          idx++;
        }
        final bt = ch.bandType[idx];
        if (bt != _btNoise && ch.sf[idx] != 0) {
          var q = ch.quant[p];
          q = q > 0 ? q + pulseAmp[i] : q - pulseAmp[i];
          ch.quant[p] = q;
          final a = q < 0 ? -q : q;
          final m = a < _t.pow43.length
              ? _t.pow43[a]
              : math.pow(a, 4.0 / 3.0).toDouble();
          ch.coef[p] = (q < 0 ? -m : m) * ch.sf[idx];
        }
      }
    }
  }

  void _decodeBandTypes(_Bits r, _Channel ch) {
    final ics = ch.ics;
    final bits = ics.winSeq0 == _eightShort ? 3 : 5;
    final esc = (1 << bits) - 1;
    var idx = 0;
    for (var g = 0; g < ics.numWindowGroups; g++) {
      var k = 0;
      while (k < ics.maxSfb) {
        var end = k;
        final bt = r.read(4);
        if (bt == 12) throw const FormatException('AAC: invalid band type');
        int incr;
        do {
          incr = r.read(bits);
          end += incr;
          if (end > ics.maxSfb) {
            throw const FormatException('AAC: section exceeds max_sfb');
          }
        } while (incr == esc);
        for (; k < end; k++) {
          ch.bandType[idx] = bt;
          ch.runEnd[idx++] = end;
        }
      }
    }
  }

  void _decodeScalefactors(_Bits r, _Channel ch, int globalGain) {
    final ics = ch.ics;
    var off0 = globalGain, off1 = globalGain - 90, off2 = 0;
    var noiseFlag = true;
    final sfVlc = _t.scalefactor;
    var idx = 0;
    for (var g = 0; g < ics.numWindowGroups; g++) {
      var i = 0;
      while (i < ics.maxSfb) {
        final runEnd = ch.runEnd[idx];
        final bt = ch.bandType[idx];
        if (bt == _btZero) {
          for (; i < runEnd; i++, idx++) {
            ch.sf[idx] = 0;
          }
        } else if (bt == _btIntensity || bt == _btIntensity2) {
          for (; i < runEnd; i++, idx++) {
            off2 += r.vlc(sfVlc) - 60;
            final c = off2.clamp(-155, 100);
            ch.sf[idx] = math.pow(2.0, -c / 4.0).toDouble();
          }
        } else if (bt == _btNoise) {
          for (; i < runEnd; i++, idx++) {
            if (noiseFlag) {
              noiseFlag = false;
              off1 += r.read(9) - 256;
            } else {
              off1 += r.vlc(sfVlc) - 60;
            }
            final c = off1.clamp(-100, 155);
            ch.sf[idx] = -math.pow(2.0, c / 4.0).toDouble();
          }
        } else {
          for (; i < runEnd; i++, idx++) {
            off0 += r.vlc(sfVlc) - 60;
            if (off0 < 0 || off0 > 255) {
              throw const FormatException('AAC: scalefactor out of range');
            }
            ch.sf[idx] = _t.sfGain[off0];
          }
        }
      }
    }
  }

  void _decodeTns(_Bits r, _Channel ch) {
    final is8 = ch.ics.winSeq0 == _eightShort;
    final maxOrder = is8 ? 7 : 12;
    for (var w = 0; w < ch.ics.numWindows; w++) {
      final nFilt = r.read(is8 ? 1 : 2);
      ch.tnsNFilt[w] = nFilt;
      if (nFilt == 0) continue;
      final coefRes = r.read1();
      for (var f = 0; f < nFilt; f++) {
        final fi = w * 4 + f;
        ch.tnsLength[fi] = r.read(is8 ? 4 : 6);
        final order = r.read(is8 ? 3 : 5);
        if (order > maxOrder) {
          ch.tnsOrder[fi] = 0;
          throw const FormatException('AAC: TNS order too high');
        }
        ch.tnsOrder[fi] = order;
        if (order > 0) {
          ch.tnsDir[fi] = r.read1();
          final compress = r.read1();
          final coefLen = coefRes + 3 - compress;
          final resBits = coefRes + 3;
          final iqfac = ((1 << (resBits - 1)) - 0.5) / (math.pi / 2.0);
          final iqfacM = ((1 << (resBits - 1)) + 0.5) / (math.pi / 2.0);
          for (var i = 0; i < order; i++) {
            var q = r.read(coefLen);
            if (q >= (1 << (coefLen - 1))) q -= 1 << coefLen;
            ch.tnsCoef[fi * 20 + i] = math.sin(q / (q >= 0 ? iqfac : iqfacM));
          }
        }
      }
    }
  }

  void _decodeSpectrum(_Bits r, _Channel ch) {
    final ics = ch.ics;
    final off = ics.swbOffset;
    final coef = ch.coef;
    final quant = ch.quant;
    final winLen = 1024 ~/ ics.numWindows;
    for (var w = 0; w < ics.numWindows; w++) {
      final s = w * 128 + off[ics.maxSfb];
      coef.fillRange(s, w * 128 + winLen, 0.0);
      quant.fillRange(s, w * 128 + winLen, 0);
    }
    final pow43 = _t.pow43;
    var idx = 0;
    var winBase = 0;
    for (var g = 0; g < ics.numWindowGroups; g++) {
      final gLen = ics.groupLen[g];
      for (var i = 0; i < ics.maxSfb; i++, idx++) {
        final bt = ch.bandType[idx];
        final start = off[i];
        final len = off[i + 1] - start;
        if (bt == _btZero || bt >= _btIntensity2) {
          for (var w = 0; w < gLen; w++) {
            final b = winBase + w * 128 + start;
            coef.fillRange(b, b + len, 0.0);
            quant.fillRange(b, b + len, 0);
          }
        } else if (bt == _btNoise) {
          stats.pnsBands++;
          for (var w = 0; w < gLen; w++) {
            final b = winBase + w * 128 + start;
            var energy = 0.0;
            for (var k = 0; k < len; k++) {
              final st = _randomState;
              final nx =
                  (st * 0x660d + (((st * 0x19) & 0xffff) << 16) + 1013904223) &
                  0xffffffff;
              _randomState = nx;
              final v = nx.toSigned(32).toDouble();
              coef[b + k] = v;
              energy += v * v;
              quant[b + k] = 0;
            }
            final scale = ch.sf[idx] / math.sqrt(energy);
            for (var k = 0; k < len; k++) {
              coef[b + k] *= scale;
            }
          }
        } else {
          final cb = _t.codebooks[bt - 1];
          final gain = ch.sf[idx];
          final vals = cb.vals;
          final vlc = cb.vlc;
          for (var w = 0; w < gLen; w++) {
            final b = winBase + w * 128 + start;
            if (cb.quad) {
              for (var k = 0; k < len; k += 4) {
                final s4 = r.vlc(vlc) * 4;
                for (var d = 0; d < 4; d++) {
                  var q = vals[s4 + d];
                  if (cb.unsigned && q != 0 && r.read1() == 1) q = -q;
                  quant[b + k + d] = q;
                  coef[b + k + d] = q == 0
                      ? 0.0
                      : (q < 0 ? -pow43[-q] : pow43[q]) * gain;
                }
              }
            } else {
              for (var k = 0; k < len; k += 2) {
                final s2 = r.vlc(vlc) * 2;
                var q0 = vals[s2], q1 = vals[s2 + 1];
                if (cb.unsigned) {
                  final n0 = q0 != 0 && r.read1() == 1;
                  final n1 = q1 != 0 && r.read1() == 1;
                  if (cb.escape) {
                    if (q0 == 16) q0 = _escape(r);
                    if (q1 == 16) q1 = _escape(r);
                  }
                  if (n0) q0 = -q0;
                  if (n1) q1 = -q1;
                }
                quant[b + k] = q0;
                quant[b + k + 1] = q1;
                coef[b + k] = q0 == 0
                    ? 0.0
                    : (q0 < 0 ? -pow43[-q0] : pow43[q0]) * gain;
                coef[b + k + 1] = q1 == 0
                    ? 0.0
                    : (q1 < 0 ? -pow43[-q1] : pow43[q1]) * gain;
              }
            }
          }
        }
      }
      winBase += gLen * 128;
    }
  }

  int _escape(_Bits r) {
    stats.escapes++;
    var n = 4;
    while (r.read1() == 1) {
      n++;
      if (n > 12) throw const FormatException('AAC: bad escape');
    }
    return (1 << n) + r.read(n);
  }

  void _applyMs(_Element e) {
    final c0 = e.ch[0], c1 = e.ch[1];
    final ics = c0.ics;
    final off = ics.swbOffset;
    final a = c0.coef, b = c1.coef;
    var idx = 0;
    var base = 0;
    for (var g = 0; g < ics.numWindowGroups; g++) {
      for (var i = 0; i < ics.maxSfb; i++, idx++) {
        if (e.msMask[idx] != 0 &&
            c0.bandType[idx] < _btNoise &&
            c1.bandType[idx] < _btNoise) {
          stats.msBands++;
          for (var w = 0; w < ics.groupLen[g]; w++) {
            final s = base + w * 128;
            for (var k = s + off[i]; k < s + off[i + 1]; k++) {
              final l = a[k], r = b[k];
              a[k] = l + r;
              b[k] = l - r;
            }
          }
        }
      }
      base += ics.groupLen[g] * 128;
    }
  }

  void _applyIntensity(_Element e, int msPresent) {
    final c0 = e.ch[0], c1 = e.ch[1];
    final ics = c1.ics;
    final off = ics.swbOffset;
    var idx = 0;
    var base = 0;
    for (var g = 0; g < ics.numWindowGroups; g++) {
      var i = 0;
      while (i < ics.maxSfb) {
        final bt = c1.bandType[idx];
        final runEnd = c1.runEnd[idx];
        if (bt == _btIntensity || bt == _btIntensity2) {
          for (; i < runEnd; i++, idx++) {
            stats.intensityBands++;
            var c = -1 + 2 * (c1.bandType[idx] - 14);
            if (msPresent != 0) c *= 1 - 2 * e.msMask[idx];
            final scale = c * c1.sf[idx];
            for (var w = 0; w < ics.groupLen[g]; w++) {
              final s = base + w * 128;
              for (var k = s + off[i]; k < s + off[i + 1]; k++) {
                c1.coef[k] = c0.coef[k] * scale;
              }
            }
          }
        } else {
          idx += runEnd - i;
          i = runEnd;
        }
      }
      base += ics.groupLen[g] * 128;
    }
  }

  void _applyTns(_Channel ch) {
    final ics = ch.ics;
    final mmm = math.min(ics.tnsMaxBands, ics.maxSfb);
    final coef = ch.coef;
    final lpc = _lpc;
    for (var w = 0; w < ics.numWindows; w++) {
      var bottom = ics.numSwb;
      for (var f = 0; f < ch.tnsNFilt[w]; f++) {
        final fi = w * 4 + f;
        final top = bottom;
        bottom = math.max(0, top - ch.tnsLength[fi]);
        final order = ch.tnsOrder[fi];
        if (order == 0) continue;
        stats.tnsFilters++;
        for (var i = 0; i < order; i++) {
          final rc = ch.tnsCoef[fi * 20 + i];
          lpc[i] = rc;
          for (var j = 0; j < (i + 1) >> 1; j++) {
            final fv = lpc[j];
            final bv = lpc[i - 1 - j];
            lpc[j] = fv + rc * bv;
            lpc[i - 1 - j] = bv + rc * fv;
          }
        }
        var start = ics.swbOffset[math.min(bottom, mmm)];
        final end = ics.swbOffset[math.min(top, mmm)];
        final size = end - start;
        if (size <= 0) continue;
        int inc;
        if (ch.tnsDir[fi] != 0) {
          inc = -1;
          start = end - 1;
        } else {
          inc = 1;
        }
        start += w * 128;
        for (var m = 0; m < size; m++, start += inc) {
          var acc = coef[start];
          final lim = m < order ? m : order;
          for (var i = 1; i <= lim; i++) {
            acc -= coef[start - i * inc] * lpc[i - 1];
          }
          coef[start] = acc;
        }
      }
    }
  }

  void _spectralToSample(_Channel ch) {
    if (ch.tnsPresent) _applyTns(ch);
    _imdctAndWindowing(ch);
  }

  void _imdctAndWindowing(_Channel ch) {
    final ics = ch.ics;
    final t = _t;
    final input = ch.coef;
    final out = ch.out;
    final saved = ch.saved;
    final buf = _buf;
    final temp = _temp;
    final swin = ics.kb0 == 1 ? t.kbd128 : t.sine128;
    final lwinPrev = ics.kb1 == 1 ? t.kbd1024 : t.sine1024;
    final swinPrev = ics.kb1 == 1 ? t.kbd128 : t.sine128;

    if (ics.winSeq0 == _eightShort) {
      for (var i = 0; i < 1024; i += 128) {
        t.imdctShort.half(input, i, buf, i);
      }
    } else {
      t.imdctLong.half(input, 0, buf, 0);
    }

    if ((ics.winSeq1 == _onlyLong || ics.winSeq1 == _longStop) &&
        (ics.winSeq0 == _onlyLong || ics.winSeq0 == _longStart)) {
      _fmulWindow(out, 0, saved, 0, buf, 0, lwinPrev, 512);
    } else {
      out.setRange(0, 448, saved);
      if (ics.winSeq0 == _eightShort) {
        _fmulWindow(out, 448, saved, 448, buf, 0, swinPrev, 64);
        _fmulWindow(out, 448 + 128, buf, 64, buf, 128, swin, 64);
        _fmulWindow(out, 448 + 256, buf, 128 + 64, buf, 256, swin, 64);
        _fmulWindow(out, 448 + 384, buf, 256 + 64, buf, 384, swin, 64);
        _fmulWindow(temp, 0, buf, 384 + 64, buf, 512, swin, 64);
        out.setRange(448 + 512, 1024, temp);
      } else {
        _fmulWindow(out, 448, saved, 448, buf, 0, swinPrev, 64);
        out.setRange(576, 1024, buf, 64);
      }
    }

    if (ics.winSeq0 == _eightShort) {
      saved.setRange(0, 64, temp, 64);
      _fmulWindow(saved, 64, buf, 512 + 64, buf, 640, swin, 64);
      _fmulWindow(saved, 192, buf, 640 + 64, buf, 768, swin, 64);
      _fmulWindow(saved, 320, buf, 768 + 64, buf, 896, swin, 64);
      saved.setRange(448, 512, buf, 896 + 64);
    } else if (ics.winSeq0 == _longStart) {
      saved.setRange(0, 448, buf, 512);
      saved.setRange(448, 512, buf, 896 + 64);
    } else {
      saved.setRange(0, 512, buf, 512);
    }
  }
}
