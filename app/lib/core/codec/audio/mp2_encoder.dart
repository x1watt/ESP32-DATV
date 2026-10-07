// MPEG audio Layer II encoder (ISO/IEC 11172-3 and the ISO/IEC 13818-3
// low sampling frequency extension), pure Dart.
//
// Supported: MPEG-1 at 32/44.1/48 kHz and MPEG-2 LSF at 16/22.05/24 kHz,
// mono or stereo (independent channels), CRC off, padding for the
// 44.1/22.05 kHz families. Bit allocation is driven by a simplified
// psychoacoustic model (FFT based, Bark spreading, tonality dependent
// masking offset, absolute threshold of hearing), similar in spirit to
// ISO model 1.
//
// The numeric tables (analysis window, allocation tables, quantizer classes)
// are the normative tables from ISO/IEC 11172-3 / 13818-3.

import 'dart:math' as math;
import 'dart:typed_data';

/// Samples per channel in one Layer II frame (both MPEG-1 and MPEG-2 LSF).
const int mp2FrameSamples = 1152;

/// Delay in samples introduced by the analysis plus synthesis filterbank.
/// A decoder's output lags the encoder input by this many samples
/// (same value FFmpeg reports as initial padding for its mp2 encoder).
const int mp2CodecDelaySamples = 481;

const List<int> _bitratesMpeg1 = [
  0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, //
];
const List<int> _bitratesLsf = [
  0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, //
];

/// Encoder for MPEG-1/2 Layer II audio ("mp2").
class Mp2Encoder {
  /// Creates an encoder. [sampleRate] must be one of 16000, 22050, 24000,
  /// 32000, 44100, 48000; [channels] 1 or 2; [bitrateKbps] a Layer II
  /// bitrate valid for that MPEG version (see [validBitrates]).
  Mp2Encoder(this.sampleRate, this.channels, this.bitrateKbps) {
    if (channels != 1 && channels != 2) {
      throw ArgumentError.value(channels, 'channels', 'must be 1 or 2');
    }
    switch (sampleRate) {
      case 44100:
        _lsf = false;
        _freqIndex = 0;
      case 48000:
        _lsf = false;
        _freqIndex = 1;
      case 32000:
        _lsf = false;
        _freqIndex = 2;
      case 22050:
        _lsf = true;
        _freqIndex = 0;
      case 24000:
        _lsf = true;
        _freqIndex = 1;
      case 16000:
        _lsf = true;
        _freqIndex = 2;
      default:
        throw ArgumentError.value(sampleRate, 'sampleRate', 'not a Layer II rate');
    }
    if (!validBitrates(sampleRate, channels).contains(bitrateKbps)) {
      throw ArgumentError.value(
        bitrateKbps,
        'bitrateKbps',
        'not valid for $sampleRate Hz, $channels ch (valid: ${validBitrates(sampleRate, channels)})',
      );
    }
    _bitrateIndex = (_lsf ? _bitratesLsf : _bitratesMpeg1).indexOf(bitrateKbps);

    // Frame size in bytes: 144 * bitrate / fs, fractional part handled by
    // the padding slot.
    final num = 144000 * bitrateKbps;
    _slots = num ~/ sampleRate;
    _padIncr = num % sampleRate;

    int table;
    if (_lsf) {
      table = 4;
    } else {
      final chRate = bitrateKbps ~/ channels;
      if ((sampleRate == 48000 && chRate >= 56) || (chRate >= 56 && chRate <= 80)) {
        table = 0;
      } else if (sampleRate != 48000 && chRate >= 96) {
        table = 1;
      } else if (sampleRate != 32000 && chRate <= 48) {
        table = 2;
      } else {
        table = 3;
      }
    }
    _sblimit = _sblimitTable[table];
    final alloc = _allocTables[table];
    _nbal = Int32List(_sblimit);
    _allocQ = List<Int32List>.generate(_sblimit, (_) => Int32List(16));
    var j = 0;
    for (var sb = 0; sb < _sblimit; sb++) {
      final nb = alloc[j];
      _nbal[sb] = nb;
      for (var b = 1; b < (1 << nb); b++) {
        _allocQ[sb][b] = alloc[j + b];
      }
      j += 1 << nb;
    }

    _hist = List<Float64List>.generate(channels, (_) => Float64List(_histLen));
    _sb = List<Float64List>.generate(channels, (_) => Float64List(36 * 32));
    _scf = List<Int32List>.generate(channels, (_) => Int32List(32 * 3));
    _scfsi = List<Int32List>.generate(channels, (_) => Int32List(32));
    _smr = List<Float64List>.generate(channels, (_) => Float64List(32));
    _alloc = List<Int32List>.generate(channels, (_) => Int32List(32));
    // Soft bandwidth target: with few bits per channel it is better to code
    // fewer subbands with more precision than many with 3-level quantizers.
    // Subbands above the target get their SMR lowered progressively.
    var side = 32;
    for (var sb = 0; sb < _sblimit; sb++) {
      side += _nbal[sb] * channels;
    }
    final perCh = (_slots * 8 - side) / channels;
    _bwTarget = (perCh / _bitsPerBandTarget).floor().clamp(4, _sblimit);
    _pending = Int16List(mp2FrameSamples * channels);
    _psy = _PsyModel(sampleRate);
  }

  final int sampleRate;
  final int channels;
  final int bitrateKbps;

  /// Bitrates (kbit/s) allowed for the given rate and channel count.
  /// MPEG-1 Layer II forbids some bitrate/mode combinations (ISO 11172-3
  /// 2.4.2.3): mono above 192 and stereo at 32/48/56/80.
  static List<int> validBitrates(int sampleRate, int channels) {
    const lsfRates = [16000, 22050, 24000];
    const m1Rates = [32000, 44100, 48000];
    if (lsfRates.contains(sampleRate)) return _bitratesLsf.sublist(1);
    if (!m1Rates.contains(sampleRate)) return const [];
    return _bitratesMpeg1.sublist(1).where((b) {
      if (channels == 1) return b <= 192;
      return b != 32 && b != 48 && b != 56 && b != 80;
    }).toList();
  }

  late final bool _lsf;
  late final int _freqIndex;
  late final int _bitrateIndex;
  late final int _slots;
  late final int _padIncr;
  int _padAcc = 0;
  late final int _sblimit;
  late final Int32List _nbal;
  late final List<Int32List> _allocQ;

  // Input history per channel: 480 samples of filter memory + one frame.
  static const int _histLen = 480 + mp2FrameSamples;
  late final List<Float64List> _hist;
  late final List<Float64List> _sb; // [36][32] subband samples per channel
  late final List<Int32List> _scf; // [32][3]
  late final List<Int32List> _scfsi;
  late final List<Float64List> _smr;
  late final List<Int32List> _alloc;
  late final _PsyModel _psy;
  late final int _bwTarget;
  static const double _bitsPerBandTarget = 90.0;
  static const double _tiltDbPerBand = 6.0;

  /// Subbands below this index are favoured by the allocator (soft
  /// bandwidth limit derived from the bitrate per channel).
  int get bandwidthTargetSubbands => _bwTarget;

  late final Int16List _pending;
  int _pendingFrames = 0;
  int _framesEncoded = 0;

  /// Nominal frame length in bytes (without the optional padding byte).
  int get frameBytes => _slots;

  /// Frame duration in microseconds, rounded to the nearest microsecond.
  /// For exact timestamps use frame index * [mp2FrameSamples] / [sampleRate].
  int get frameDurationUs => (mp2FrameSamples * 1000000 / sampleRate).round();

  /// True when the stream is MPEG-2 LSF (16/22.05/24 kHz).
  bool get isLsf => _lsf;

  /// Number of subbands that can carry bits at this rate (bandwidth is
  /// about sblimit * sampleRate / 64).
  int get sblimit => _sblimit;

  /// Frames produced so far.
  int get framesEncoded => _framesEncoded;

  /// Encodes interleaved 16-bit PCM. Input is buffered internally; every
  /// complete group of 1152 samples per channel yields one frame.
  List<Uint8List> encode(Int16List interleaved) {
    final out = <Uint8List>[];
    final total = interleaved.length ~/ channels;
    var pos = 0;
    while (pos < total) {
      final take = math.min(total - pos, mp2FrameSamples - _pendingFrames);
      _pending.setRange(_pendingFrames * channels, (_pendingFrames + take) * channels, interleaved, pos * channels);
      _pendingFrames += take;
      pos += take;
      if (_pendingFrames == mp2FrameSamples) {
        out.add(_encodeFrame());
        _pendingFrames = 0;
      }
    }
    return out;
  }

  /// Encodes any buffered samples followed by enough silence to push the
  /// filterbank delay ([mp2CodecDelaySamples]) out, padded to whole frames.
  List<Uint8List> flush() {
    final out = <Uint8List>[];
    if (_pendingFrames == 0 && _framesEncoded == 0) return out;
    var remaining = _pendingFrames + mp2CodecDelaySamples;
    while (remaining > 0) {
      final fill = mp2FrameSamples - _pendingFrames;
      _pending.fillRange(_pendingFrames * channels, mp2FrameSamples * channels, 0);
      remaining -= mp2FrameSamples;
      _pendingFrames += fill;
      out.add(_encodeFrame());
      _pendingFrames = 0;
    }
    return out;
  }

  Uint8List _encodeFrame() {
    final nch = channels;
    // Shift history and append the new frame.
    for (var ch = 0; ch < nch; ch++) {
      final h = _hist[ch];
      h.setRange(0, 480, h, mp2FrameSamples);
      for (var i = 0; i < mp2FrameSamples; i++) {
        h[480 + i] = _pending[i * nch + ch] * (1.0 / 32768.0);
      }
      _analysis(h, _sb[ch]);
      _scaleFactors(_sb[ch], _scf[ch], _scfsi[ch]);
      _psy.compute(h, _sb[ch], _scf[ch], _sblimit, _smr[ch]);
      final smr = _smr[ch];
      for (var sb = _bwTarget; sb < _sblimit; sb++) {
        smr[sb] -= _tiltDbPerBand * (sb - _bwTarget + 1);
      }
    }

    var padding = 0;
    _padAcc += _padIncr;
    if (_padAcc >= sampleRate) {
      _padAcc -= sampleRate;
      padding = 1;
    }
    final frameLen = _slots + padding;
    _allocate(frameLen * 8);

    final w = _BitWriter(frameLen);
    w.put(0xfff, 12);
    w.put(_lsf ? 0 : 1, 1);
    w.put(2, 2); // layer II
    w.put(1, 1); // no CRC
    w.put(_bitrateIndex, 4);
    w.put(_freqIndex, 2);
    w.put(padding, 1);
    w.put(0, 1); // private
    w.put(nch == 2 ? 0 : 3, 2); // stereo or single channel
    w.put(0, 2); // mode extension
    w.put(0, 1); // copyright
    w.put(1, 1); // original
    w.put(0, 2); // emphasis

    final sbl = _sblimit;
    for (var sb = 0; sb < sbl; sb++) {
      for (var ch = 0; ch < nch; ch++) {
        w.put(_alloc[ch][sb], _nbal[sb]);
      }
    }
    for (var sb = 0; sb < sbl; sb++) {
      for (var ch = 0; ch < nch; ch++) {
        if (_alloc[ch][sb] != 0) w.put(_scfsi[ch][sb], 2);
      }
    }
    for (var sb = 0; sb < sbl; sb++) {
      for (var ch = 0; ch < nch; ch++) {
        if (_alloc[ch][sb] == 0) continue;
        final s = _scf[ch];
        switch (_scfsi[ch][sb]) {
          case 0:
            w.put(s[sb * 3], 6);
            w.put(s[sb * 3 + 1], 6);
            w.put(s[sb * 3 + 2], 6);
          case 1:
          case 3:
            w.put(s[sb * 3], 6);
            w.put(s[sb * 3 + 2], 6);
          case 2:
            w.put(s[sb * 3], 6);
        }
      }
    }

    // Quantize and write samples: 3 parts x 4 granules x 3 samples.
    final q = Int32List(3);
    for (var part = 0; part < 3; part++) {
      for (var gr = 0; gr < 4; gr++) {
        final t0 = part * 12 + gr * 3;
        for (var sb = 0; sb < sbl; sb++) {
          for (var ch = 0; ch < nch; ch++) {
            final b = _alloc[ch][sb];
            if (b == 0) continue;
            final qi = _allocQ[sb][b];
            final steps = _quantSteps[qi];
            final inv = _scaleInv[_scf[ch][sb * 3 + part]];
            final sbs = _sb[ch];
            for (var m = 0; m < 3; m++) {
              final x = sbs[(t0 + m) * 32 + sb] * inv;
              var v = ((x + 1.0) * steps * 0.5).floor();
              if (v < 0) v = 0;
              if (v >= steps) v = steps - 1;
              q[m] = v;
            }
            final bits = _quantBits[qi];
            if (bits < 0) {
              w.put(q[0] + steps * (q[1] + steps * q[2]), -bits);
            } else {
              w.put(q[0], bits);
              w.put(q[1], bits);
              w.put(q[2], bits);
            }
          }
        }
      }
    }
    w.finish();
    _framesEncoded++;
    return w.bytes; // remaining bits are zero (ancillary data)
  }

  // Polyphase analysis filterbank: 36 blocks of 32 subband samples.
  void _analysis(Float64List h, Float64List out) {
    final y = _y;
    final t = _t;
    final win = _window;
    final dct = _dct;
    for (var blk = 0; blk < 36; blk++) {
      // X[n] = h[newest - n]; history index never goes negative because
      // newest - 511 >= 0 for blk >= 0 (480 + 31 - 511 = 0).
      final newest = 480 + blk * 32 + 31;
      for (var i = 0; i < 64; i++) {
        final n = newest - i;
        y[i] =
            h[n] * win[i] +
            h[n - 64] * win[i + 64] +
            h[n - 128] * win[i + 128] +
            h[n - 192] * win[i + 192] +
            h[n - 256] * win[i + 256] +
            h[n - 320] * win[i + 320] +
            h[n - 384] * win[i + 384] +
            h[n - 448] * win[i + 448];
      }
      t[0] = y[16];
      for (var i = 1; i <= 16; i++) {
        t[i] = y[i + 16] + y[16 - i];
      }
      for (var i = 17; i < 32; i++) {
        t[i] = y[i + 16] - y[80 - i];
      }
      // S[k] = sum_i t[i] cos((2k+1) i pi / 64). Since the row for 31-k is
      // the row for k with odd terms negated, compute even and odd halves.
      final ob = blk * 32;
      for (var k = 0; k < 16; k++) {
        var e = 0.0, o = 0.0;
        final row = k * 32;
        for (var i = 0; i < 32; i += 2) {
          e += dct[row + i] * t[i];
          o += dct[row + i + 1] * t[i + 1];
        }
        out[ob + k] = e + o;
        out[ob + 31 - k] = e - o;
      }
    }
  }

  static final Float64List _y = Float64List(64);
  static final Float64List _t = Float64List(32);

  void _scaleFactors(Float64List sbs, Int32List scf, Int32List scfsi) {
    for (var sb = 0; sb < _sblimit; sb++) {
      for (var part = 0; part < 3; part++) {
        var vmax = 0.0;
        for (var k = 0; k < 12; k++) {
          final v = sbs[(part * 12 + k) * 32 + sb].abs();
          if (v > vmax) vmax = v;
        }
        int idx;
        if (vmax < 1e-9) {
          idx = 62;
        } else {
          idx = (3.0 * (1.0 - math.log(vmax) / math.ln2)).floor();
          if (idx < 0) idx = 0;
          if (idx > 62) idx = 62;
          while (idx > 0 && _scaleTab[idx] < vmax) {
            idx--;
          }
          while (idx < 62 && _scaleTab[idx + 1] >= vmax) {
            idx++;
          }
        }
        scf[sb * 3 + part] = idx;
      }
      // Transmission pattern selection (ISO 11172-3 table C.4).
      final s0 = scf[sb * 3], s1 = scf[sb * 3 + 1], s2 = scf[sb * 3 + 2];
      final d1 = _diffClass(s0 - s1), d2 = _diffClass(s1 - s2);
      var a = s0, b = s1, c = s2;
      int code;
      switch (d1 * 5 + d2) {
        case 0:
        case 4:
        case 19:
        case 20:
        case 24:
          code = 0;
        case 1:
        case 2:
        case 21:
        case 22:
          code = 3;
          c = b;
        case 3:
        case 23:
          code = 3;
          b = c;
        case 5:
        case 9:
        case 14:
          code = 1;
          b = a;
        case 6:
        case 7:
        case 10:
        case 11:
        case 12:
          code = 2;
          b = a;
          c = a;
        case 13:
        case 18:
          code = 2;
          a = c;
          b = c;
        case 15:
        case 16:
        case 17:
          code = 2;
          a = b;
          c = b;
        case 8:
          code = 2;
          if (a > c) a = c;
          b = a;
          c = a;
        default:
          code = 0;
      }
      scf[sb * 3] = a;
      scf[sb * 3 + 1] = b;
      scf[sb * 3 + 2] = c;
      scfsi[sb] = code;
    }
  }

  static int _diffClass(int d) {
    if (d <= -3) return 0;
    if (d < 0) return 1;
    if (d == 0) return 2;
    if (d < 3) return 3;
    return 4;
  }

  // Greedy allocation: repeatedly give one more step to the subband with
  // the worst mask-to-noise ratio until the frame is full.
  void _allocate(int maxBits) {
    final nch = channels;
    final sbl = _sblimit;
    var used = 32; // header
    for (var sb = 0; sb < sbl; sb++) {
      used += _nbal[sb] * nch;
    }
    final status = _status;
    for (var ch = 0; ch < nch; ch++) {
      final a = _alloc[ch];
      for (var sb = 0; sb < 32; sb++) {
        a[sb] = 0;
        // Bands with no signal at all are never coded.
        status[ch * 32 + sb] =
            (sb < sbl && _scf[ch][sb * 3] < 62) ||
                (sb < sbl && _scf[ch][sb * 3 + 1] < 62) ||
                (sb < sbl && _scf[ch][sb * 3 + 2] < 62)
            ? 0
            : 2;
      }
    }
    while (true) {
      var best = -1;
      var bestVal = -1e30;
      for (var ch = 0; ch < nch; ch++) {
        final a = _alloc[ch];
        final smr = _smr[ch];
        for (var sb = 0; sb < sbl; sb++) {
          if (status[ch * 32 + sb] == 2) continue;
          final b = a[sb];
          final snr = b == 0 ? 0.0 : _quantSnr[_allocQ[sb][b]];
          final nmr = smr[sb] - snr;
          if (nmr > bestVal) {
            bestVal = nmr;
            best = ch * 32 + sb;
          }
        }
      }
      if (best < 0) break;
      final ch = best >> 5, sb = best & 31;
      final b = _alloc[ch][sb];
      int incr;
      if (b == 0) {
        incr = 2 + _nbScf[_scfsi[ch][sb]] * 6 + _groupBits(_allocQ[sb][1]);
      } else {
        incr = _groupBits(_allocQ[sb][b + 1]) - _groupBits(_allocQ[sb][b]);
      }
      if (used + incr <= maxBits) {
        used += incr;
        _alloc[ch][sb] = b + 1;
        if (b + 1 == (1 << _nbal[sb]) - 1) status[best] = 2;
      } else {
        status[best] = 2;
      }
    }
  }

  static final Int32List _status = Int32List(64);

  static int _groupBits(int qi) {
    final b = _quantBits[qi];
    return 12 * (b < 0 ? -b : 3 * b);
  }
}

/// Simplified psychoacoustic model producing per-subband signal-to-mask
/// ratios in dB.
class _PsyModel {
  _PsyModel(this.fs) {
    const n = _fftN;
    _re = Float64List(n);
    _im = Float64List(n);
    _hann = Float64List(n);
    for (var i = 0; i < n; i++) {
      _hann[i] = 0.5 - 0.5 * math.cos(2 * math.pi * (i + 0.5) / n);
    }
    _cos = Float64List(n ~/ 2);
    _sin = Float64List(n ~/ 2);
    for (var i = 0; i < n ~/ 2; i++) {
      _cos[i] = math.cos(2 * math.pi * i / n);
      _sin[i] = -math.sin(2 * math.pi * i / n);
    }
    _rev = Int32List(n);
    for (var i = 0, j = 0; i < n; i++) {
      _rev[i] = j;
      var bit = n >> 1;
      while (j & bit != 0) {
        j ^= bit;
        bit >>= 1;
      }
      j |= bit;
    }
    const lines = n ~/ 2 + 1;
    _power = Float64List(lines);
    _thr = Float64List(lines);
    _ath = Float64List(lines);
    _lineBark = Float64List(lines);
    _part = Int32List(lines);
    var maxPart = 0;
    for (var k = 0; k < lines; k++) {
      final f = k * fs / n;
      final z = 13 * math.atan(0.00076 * f) + 3.5 * math.atan(math.pow(f / 7500, 2));
      _lineBark[k] = z;
      final p = (z * 3).floor();
      _part[k] = p;
      if (p > maxPart) maxPart = p;
      // Absolute threshold of hearing (Terhardt), in dB SPL with full scale
      // sine at 96 dB. Clamped so extreme highs do not dominate.
      final fk = math.max(f, 20.0) / 1000.0;
      var ath = 3.64 * math.pow(fk, -0.8) - 6.5 * math.exp(-0.6 * math.pow(fk - 3.3, 2)) + 1e-3 * math.pow(fk, 4);
      if (ath > 90) ath = 90;
      _ath[k] = math.pow(10, (ath - 96 + _norm) / 10).toDouble();
    }
    _nPart = maxPart + 1;
    _pE = Float64List(_nPart);
    _pMax = Float64List(_nPart);
    _pCnt = Int32List(_nPart);
    _pBark = Float64List(_nPart);
    _pOff = Float64List(_nPart);
    _pThr = Float64List(_nPart);
    for (var k = 0; k < lines; k++) {
      _pCnt[_part[k]]++;
      _pBark[_part[k]] += _lineBark[k];
    }
    for (var p = 0; p < _nPart; p++) {
      if (_pCnt[p] > 0) _pBark[p] /= _pCnt[p];
    }
    // Spreading matrix (Schroeder), linear power.
    _spread = Float64List(_nPart * _nPart);
    for (var i = 0; i < _nPart; i++) {
      for (var j = 0; j < _nPart; j++) {
        final dz = _pBark[i] - _pBark[j]; // maskee - masker
        final x = dz + 0.474;
        var db = 15.81 + 7.5 * x - 17.5 * math.sqrt(1 + x * x);
        if (db < -100) db = -100;
        _spread[i * _nPart + j] = math.pow(10, db / 10).toDouble();
      }
    }
    _sprNorm = Float64List(_nPart);
    for (var i = 0; i < _nPart; i++) {
      var s = 0.0;
      for (var j = 0; j < _nPart; j++) {
        if (_pCnt[j] > 0) s += _spread[i * _nPart + j];
      }
      _sprNorm[i] = 1.0 / s;
    }
  }

  static const int _fftN = 1024;
  // Normalization so that the power of a full scale sine peak is about
  // 96 dB in the internal scale: |X|^2 for amplitude 1 with Hann is (N/4)^2.
  static final double _norm = 20 * math.log(_fftN / 4) / math.ln10;

  final int fs;
  late final Float64List _re, _im, _hann, _cos, _sin;
  late final Int32List _rev;
  late final Float64List _power, _thr, _ath, _lineBark;
  late final Int32List _part;
  late final int _nPart;
  late final Float64List _pE, _pMax, _pBark, _pOff, _pThr, _spread, _sprNorm;
  late final Int32List _pCnt;
  final Float64List _lsb = Float64List(32);
  static const double energyWeight = 0.5;

  void compute(Float64List h, Float64List sbs, Int32List scf, int sblimit, Float64List smr) {
    const n = _fftN;
    final reL = _re,
        imL = _im,
        hannL = _hann,
        revL = _rev,
        powerL = _power,
        pEL = _pE,
        pMaxL = _pMax,
        pCntL = _pCnt,
        pBarkL = _pBark,
        pOffL = _pOff,
        pThrL = _pThr,
        spreadL = _spread,
        sprNormL = _sprNorm,
        partL = _part,
        thrL = _thr,
        athL = _ath,
        lsbL = _lsb;
    final nPart = _nPart;
    // Subband frame corresponds to input delayed by ~256 samples; center
    // the FFT on that: history index 480 is frame start.
    const start = 480 + 576 - 256 - n ~/ 2;
    for (var i = 0; i < n; i++) {
      reL[revL[i]] = h[start + i] * hannL[i];
      imL[revL[i]] = 0.0;
    }
    _fft();
    const lines = n ~/ 2 + 1;
    for (var k = 0; k < lines; k++) {
      powerL[k] = reL[k] * reL[k] + imL[k] * imL[k] + 1e-20;
    }
    // Partition energies and tonality.
    pEL.fillRange(0, nPart, 0.0);
    pMaxL.fillRange(0, nPart, 0.0);
    for (var k = 1; k < lines; k++) {
      final p = partL[k];
      final e = powerL[k];
      pEL[p] += e;
      if (e > pMaxL[p]) pMaxL[p] = e;
    }
    for (var p = 0; p < nPart; p++) {
      // Peakiness over a neighbourhood of partitions: tonal if one line
      // dominates the local mean.
      var e = 0.0, c = 0, mx = 0.0;
      for (var q = math.max(0, p - 1); q <= math.min(nPart - 1, p + 1); q++) {
        e += pEL[q];
        c += pCntL[q];
        if (pMaxL[q] > mx) mx = pMaxL[q];
      }
      double tonal;
      if (c < 4 || e <= 0) {
        tonal = 0.5;
      } else {
        final r = 10 * math.log(mx / (e / c)) / math.ln10;
        tonal = ((r - 3) / 12).clamp(0.0, 1.0);
      }
      final z = pBarkL[p];
      final offDb = tonal * (14.5 + z) + (1 - tonal) * 5.5;
      pOffL[p] = math.pow(10, -offDb / 10).toDouble();
    }
    for (var i = 0; i < nPart; i++) {
      var s = 0.0;
      final row = i * nPart;
      for (var j = 0; j < nPart; j++) {
        final e = pEL[j];
        if (e > 0) s += e * pOffL[j] * spreadL[row + j];
      }
      // Normalize by the spreading sum so a flat spectrum is masked at
      // exactly its level minus the offset; then convert to per line.
      pThrL[i] = pCntL[i] > 0 ? s * sprNormL[i] / pCntL[i] : 0.0;
    }
    for (var k = 0; k < lines; k++) {
      final t = pThrL[partL[k]];
      thrL[k] = t > athL[k] ? t : athL[k];
    }
    // Per subband SMR.
    const linesPerSb = n ~/ 64; // 16 lines per subband
    for (var sb = 0; sb < 32; sb++) {
      if (sb >= sblimit) {
        smr[sb] = -1000;
        continue;
      }
      var maxP = 0.0, minT = 1e30;
      final k0 = sb * linesPerSb, k1 = k0 + linesPerSb;
      for (var k = k0; k < k1 && k < lines; k++) {
        if (powerL[k] > maxP) maxP = powerL[k];
        if (thrL[k] < minT) minT = thrL[k];
      }
      // Level from the scale factor (largest of three), as in model 1.
      final idx = math.min(scf[sb * 3], math.min(scf[sb * 3 + 1], scf[sb * 3 + 2]));
      final scfLevel = _scaleTab[idx];
      final scfDb = 20 * math.log(scfLevel * n / 4) / math.ln10 - 10;
      final fftDb = 10 * math.log(maxP) / math.ln10;
      final lsb = math.max(fftDb, scfDb);
      smr[sb] = lsb - 10 * math.log(minT) / math.ln10;
      lsbL[sb] = lsb;
    }
    // Energy weighting: bias bits toward the strongest subbands. Pure NMR
    // allocation spreads bits evenly over weak high bands, which at low
    // bitrates costs more in low band precision than it gains.
    var lmax = -1e9;
    for (var sb = 0; sb < sblimit; sb++) {
      if (lsbL[sb] > lmax) lmax = lsbL[sb];
    }
    for (var sb = 0; sb < sblimit; sb++) {
      smr[sb] += energyWeight * (lsbL[sb] - lmax);
    }
  }

  void _fft() {
    const n = _fftN;
    final re = _re, im = _im, cosT = _cos, sinT = _sin;
    for (var size = 2; size <= n; size <<= 1) {
      final half = size >> 1;
      final step = n ~/ size;
      for (var i = 0; i < n; i += size) {
        for (var j = 0; j < half; j++) {
          final wr = cosT[j * step], wi = sinT[j * step];
          final a = i + j, b = a + half;
          final tr = re[b] * wr - im[b] * wi;
          final ti = re[b] * wi + im[b] * wr;
          re[b] = re[a] - tr;
          im[b] = im[a] - ti;
          re[a] += tr;
          im[a] += ti;
        }
      }
    }
  }
}

class _BitWriter {
  _BitWriter(int len) : bytes = Uint8List(len);
  final Uint8List bytes;
  int _pos = 0; // byte position
  int _acc = 0; // pending bits, at most 7 + 16 < 32
  int _n = 0;

  /// Writes [nbits] (at most 16) bits MSB first.
  void put(int value, int nbits) {
    _acc = (_acc << nbits) | (value & ((1 << nbits) - 1));
    _n += nbits;
    while (_n >= 8) {
      _n -= 8;
      bytes[_pos++] = (_acc >> _n) & 0xff;
    }
    _acc &= (1 << _n) - 1;
  }

  /// Flushes a partial byte (zero padded).
  void finish() {
    if (_n > 0) bytes[_pos++] = (_acc << (8 - _n)) & 0xff;
    _n = 0;
    _acc = 0;
  }
}

// ---------------------------------------------------------------------------
// Tables

/// Scale factor values 2^(1 - i/3).
final Float64List _scaleTab = Float64List.fromList(
  List<double>.generate(64, (i) => math.pow(2.0, 1.0 - i / 3.0).toDouble()),
);
final Float64List _scaleInv = Float64List.fromList(List<double>.generate(64, (i) => 1.0 / _scaleTab[i]));

/// 32x32 cosine matrix cos((2k+1) i pi / 64).
final Float64List _dct = () {
  final m = Float64List(32 * 32);
  for (var k = 0; k < 32; k++) {
    for (var i = 0; i < 32; i++) {
      m[k * 32 + i] = math.cos((2 * k + 1) * i * math.pi / 64);
    }
  }
  return m;
}();

/// Full 512-tap analysis window C[i] built from the half window.
final Float64List _window = () {
  final w = Float64List(512);
  for (var i = 0; i < 257; i++) {
    var v = _halfWindow[i] / (65536.0 * 32.0);
    w[i] = v;
    if (i & 63 != 0) v = -v;
    if (i != 0) w[512 - i] = v;
  }
  return w;
}();

const List<int> _sblimitTable = [27, 30, 8, 12, 30];

const List<int> _quantSteps = [
  3, 5, 7, 9, 15, 31, 63, 127, 255, 511, 1023, 2047, 4095, 8191, 16383, 32767, 65535, //
];

/// Bits per sample; negative means three samples grouped in that many bits.
const List<int> _quantBits = [
  -5, -7, 3, -10, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, //
];

/// SNR in dB for each quantizer class (ISO 11172-3 table C.5).
const List<double> _quantSnr = [
  7.00, 11.00, 16.00, 20.84, 25.28, 31.59, 37.75, 43.84, 49.89, 55.93, //
  61.96, 67.98, 74.01, 80.03, 86.05, 92.01, 98.01,
];

/// Number of transmitted scale factors per scfsi code.
const List<int> _nbScf = [3, 2, 1, 2];

/// Layer II allocation tables in compact form: for each subband, the number
/// of allocation bits nb followed by 2^nb - 1 quantizer class indexes (one
/// per nonzero allocation value, entry 0 is unused).
const List<List<int>> _allocTables = [_alloc1, _alloc1, _alloc3, _alloc3, _alloc4];

const List<int> _alloc1 = [
  4, 0, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, //
  4, 0, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
  4, 0, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
  4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16,
  4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16,
  4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16,
  4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16,
  4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16,
  4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16,
  4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16,
  4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16,
  3, 0, 1, 2, 3, 4, 5, 16,
  3, 0, 1, 2, 3, 4, 5, 16,
  3, 0, 1, 2, 3, 4, 5, 16,
  3, 0, 1, 2, 3, 4, 5, 16,
  3, 0, 1, 2, 3, 4, 5, 16,
  3, 0, 1, 2, 3, 4, 5, 16,
  3, 0, 1, 2, 3, 4, 5, 16,
  3, 0, 1, 2, 3, 4, 5, 16,
  3, 0, 1, 2, 3, 4, 5, 16,
  3, 0, 1, 2, 3, 4, 5, 16,
  3, 0, 1, 2, 3, 4, 5, 16,
  3, 0, 1, 2, 3, 4, 5, 16,
  2, 0, 1, 16,
  2, 0, 1, 16,
  2, 0, 1, 16,
  2, 0, 1, 16,
  2, 0, 1, 16,
  2, 0, 1, 16,
  2, 0, 1, 16,
];

const List<int> _alloc3 = [
  4, 0, 1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, //
  4, 0, 1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
  3, 0, 1, 3, 4, 5, 6, 7,
  3, 0, 1, 3, 4, 5, 6, 7,
  3, 0, 1, 3, 4, 5, 6, 7,
  3, 0, 1, 3, 4, 5, 6, 7,
  3, 0, 1, 3, 4, 5, 6, 7,
  3, 0, 1, 3, 4, 5, 6, 7,
  3, 0, 1, 3, 4, 5, 6, 7,
  3, 0, 1, 3, 4, 5, 6, 7,
  3, 0, 1, 3, 4, 5, 6, 7,
  3, 0, 1, 3, 4, 5, 6, 7,
];

const List<int> _alloc4 = [
  4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, //
  4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
  4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
  4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
  3, 0, 1, 3, 4, 5, 6, 7,
  3, 0, 1, 3, 4, 5, 6, 7,
  3, 0, 1, 3, 4, 5, 6, 7,
  3, 0, 1, 3, 4, 5, 6, 7,
  3, 0, 1, 3, 4, 5, 6, 7,
  3, 0, 1, 3, 4, 5, 6, 7,
  3, 0, 1, 3, 4, 5, 6, 7,
  2, 0, 1, 3,
  2, 0, 1, 3,
  2, 0, 1, 3,
  2, 0, 1, 3,
  2, 0, 1, 3,
  2, 0, 1, 3,
  2, 0, 1, 3,
  2, 0, 1, 3,
  2, 0, 1, 3,
  2, 0, 1, 3,
  2, 0, 1, 3,
  2, 0, 1, 3,
  2, 0, 1, 3,
  2, 0, 1, 3,
  2, 0, 1, 3,
  2, 0, 1, 3,
  2, 0, 1, 3,
  2, 0, 1, 3,
  2, 0, 1, 3,
];

/// First half (257 values) of the window D[i] = 32 * C[i], scaled by 2^16.
const List<int> _halfWindow = [
  0, -1, -1, -1, -1, -1, -1, -2, //
  -2, -2, -2, -3, -3, -4, -4, -5,
  -5, -6, -7, -7, -8, -9, -10, -11,
  -13, -14, -16, -17, -19, -21, -24, -26,
  -29, -31, -35, -38, -41, -45, -49, -53,
  -58, -63, -68, -73, -79, -85, -91, -97,
  -104, -111, -117, -125, -132, -139, -147, -154,
  -161, -169, -176, -183, -190, -196, -202, -208,
  213, 218, 222, 225, 227, 228, 228, 227,
  224, 221, 215, 208, 200, 189, 177, 163,
  146, 127, 106, 83, 57, 29, -2, -36,
  -72, -111, -153, -197, -244, -294, -347, -401,
  -459, -519, -581, -645, -711, -779, -848, -919,
  -991, -1064, -1137, -1210, -1283, -1356, -1428, -1498,
  -1567, -1634, -1698, -1759, -1817, -1870, -1919, -1962,
  -2001, -2032, -2057, -2075, -2085, -2087, -2080, -2063,
  2037, 2000, 1952, 1893, 1822, 1739, 1644, 1535,
  1414, 1280, 1131, 970, 794, 605, 402, 185,
  -45, -288, -545, -814, -1095, -1388, -1692, -2006,
  -2330, -2663, -3004, -3351, -3705, -4063, -4425, -4788,
  -5153, -5517, -5879, -6237, -6589, -6935, -7271, -7597,
  -7910, -8209, -8491, -8755, -8998, -9219, -9416, -9585,
  -9727, -9838, -9916, -9959, -9966, -9935, -9863, -9750,
  -9592, -9389, -9139, -8840, -8492, -8092, -7640, -7134,
  6574, 5959, 5288, 4561, 3776, 2935, 2037, 1082,
  70, -998, -2122, -3300, -4533, -5818, -7154, -8540,
  -9975, -11455, -12980, -14548, -16155, -17799, -19478, -21189,
  -22929, -24694, -26482, -28289, -30112, -31947, -33791, -35640,
  -37489, -39336, -41176, -43006, -44821, -46617, -48390, -50137,
  -51853, -53534, -55178, -56778, -58333, -59838, -61289, -62684,
  -64019, -65290, -66494, -67629, -68692, -69679, -70590, -71420,
  -72169, -72835, -73415, -73908, -74313, -74630, -74856, -74992,
  75038,
];
