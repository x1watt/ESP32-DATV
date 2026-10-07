// Streaming sample rate converter (Kaiser windowed sinc, polyphase) and
// channel layout helpers for interleaved 16-bit PCM.

import 'dart:math' as math;
import 'dart:typed_data';

import '../frame.dart';

/// Stateful, streaming rational resampler.
///
/// Output sample n corresponds exactly to input time n * inRate / outRate,
/// so there is no group delay offset: the output is time aligned with the
/// input. The converter needs [lookaheadFrames] input frames of lookahead,
/// which [flush] supplies as zeros at end of stream.
///
/// The anti alias / anti image low-pass has its passband up to 90 percent
/// and its stopband from 100 percent of the lower Nyquist frequency, with
/// a Kaiser window designed for [stopbandDb] attenuation (default 100 dB).
class Resampler {
  Resampler(this.inRate, this.outRate, this.channels, {double stopbandDb = 100.0, double passband = 0.90}) {
    if (inRate <= 0 || outRate <= 0) throw ArgumentError('rates must be positive');
    if (channels < 1) throw ArgumentError.value(channels, 'channels');
    final g = _gcd(inRate, outRate);
    _up = outRate ~/ g;
    _down = inRate ~/ g;
    // Phase table resolution: exact for reasonable ratios, otherwise a
    // fine table with linear interpolation between phases.
    _exact = _up <= 4096;
    _phases = _exact ? _up : 2048;

    // Cutoff relative to the input sample rate (cycles per input sample).
    final lowNyq = 0.5 * math.min(1.0, outRate / inRate);
    final fPass = passband * lowNyq;
    final fStop = lowNyq;
    final fc = 0.5 * (fPass + fStop);
    final dw = 2 * math.pi * (fStop - fPass);
    final a = stopbandDb;
    final beta = a > 50 ? 0.1102 * (a - 8.7) : (a >= 21 ? 0.5842 * math.pow(a - 21, 0.4) + 0.07886 * (a - 21) : 0.0);
    final order = ((a - 8) / (2.285 * dw)).ceil();
    final halfWidth = order / 2.0; // in input samples
    _half = halfWidth.ceil() + 1;
    // Rounded up to a multiple of 4 for the unrolled inner loop; the extra
    // taps fall outside the window and are zero.
    _taps = (2 * _half + 3) & ~3;
    // Coefficients: for phase p (fraction f = p / phases), tap d covers
    // input index i + d - (half - 1), u = f - (d - (half - 1)).
    final i0b = _besselI0(beta);
    final nPh = _phases + (_exact ? 0 : 1);
    _coef = Float64List(nPh * _taps);
    for (var p = 0; p < nPh; p++) {
      final f = p / _phases;
      var sum = 0.0;
      for (var d = 0; d < _taps; d++) {
        final u = f - (d - (_half - 1));
        double v;
        if (u.abs() >= halfWidth) {
          v = 0.0;
        } else {
          final x = u / halfWidth;
          final win = _besselI0(beta * math.sqrt(1 - x * x)) / i0b;
          final arg = 2 * fc * u;
          final sinc = arg == 0 ? 1.0 : math.sin(math.pi * arg) / (math.pi * arg);
          v = 2 * fc * sinc * win;
        }
        _coef[p * _taps + d] = v;
        sum += v;
      }
      // Normalize every phase to unity DC gain.
      for (var d = 0; d < _taps; d++) {
        _coef[p * _taps + d] /= sum;
      }
    }
    // Input buffer per channel: (half - 1) zeros of history before t=0.
    _buf = List<Float64List>.generate(channels, (_) => Float64List(4096));
    _bufLen = _half - 1;
  }

  final int inRate;
  final int outRate;
  final int channels;

  late final int _up;
  late final int _down;
  late final bool _exact;
  late final int _phases;
  late final int _half;
  late final int _taps;
  late final Float64List _coef;

  late List<Float64List> _buf;
  int _bufLen = 0; // valid samples in _buf
  int _bufBase = 0; // absolute input index of _buf[half - 1] position offset
  int _inCount = 0; // total input frames received
  int _outCount = 0; // total output frames produced
  int? _firstPtsUs;
  bool _flushed = false;

  /// Filter length per output sample, in input samples.
  int get tapsPerPhase => _taps;

  /// Input frames of lookahead needed before an output can be computed.
  int get lookaheadFrames => _taps - _half + 1;

  /// Converts interleaved samples; returns whatever output is ready.
  Int16List process(Int16List interleaved) {
    if (_flushed) throw StateError('process after flush');
    final n = interleaved.length ~/ channels;
    _append(interleaved, n);
    _inCount += n;
    return _produce(false);
  }

  /// Ends the stream: emits the remaining output so that the total output
  /// length is ceil(inputFrames * outRate / inRate).
  Int16List flush() {
    if (_flushed) return Int16List(0);
    _flushed = true;
    final z = _taps - _half + 1;
    _append(Int16List(z * channels), z);
    return _produce(true);
  }

  /// Convenience wrapper that keeps timestamps: the first block's ptsUs is
  /// the origin, later outputs are stamped from the output sample count.
  PcmBlock processBlock(PcmBlock block) {
    if (block.sampleRate != inRate || block.channels != channels) {
      throw ArgumentError(
        'block format ${block.sampleRate}/${block.channels} '
        'does not match $inRate/$channels',
      );
    }
    _firstPtsUs ??= block.ptsUs;
    final pts = _firstPtsUs! + (_outCount * 1000000) ~/ outRate;
    return PcmBlock(process(block.samples), outRate, channels, ptsUs: pts);
  }

  /// Flushes and wraps the tail in a PcmBlock.
  PcmBlock flushBlock() {
    final pts = (_firstPtsUs ?? 0) + (_outCount * 1000000) ~/ outRate;
    return PcmBlock(flush(), outRate, channels, ptsUs: pts);
  }

  void _append(Int16List src, int n) {
    if (_bufLen + n > _buf[0].length) {
      var cap = _buf[0].length;
      while (cap < _bufLen + n) {
        cap *= 2;
      }
      for (var c = 0; c < channels; c++) {
        final nb = Float64List(cap);
        nb.setRange(0, _bufLen, _buf[c]);
        _buf[c] = nb;
      }
    }
    const s = 1.0 / 32768.0;
    for (var c = 0; c < channels; c++) {
      final b = _buf[c];
      var j = c;
      for (var i = 0; i < n; i++) {
        b[_bufLen + i] = src[j] * s;
        j += channels;
      }
    }
    _bufLen += n;
  }

  Int16List _produce(bool last) {
    // Output n sits at input time t = n * down / up. Its integer part i and
    // phase p; it needs buffer indexes [i - bufBase .. i - bufBase + taps).
    final totalOut = last ? ((_inCount * _up + _down - 1) ~/ _down) : -1;
    final nch = channels;
    final bound = (_bufLen * _up) ~/ _down + 2;
    final ready = Float64List(bound * nch);
    var r = 0;
    var n = _outCount;
    while (true) {
      if (last && n >= totalOut) break;
      final num = n * _down;
      final i = num ~/ _up;
      final rel = i - _bufBase; // buffer index of first tap
      if (rel + _taps > _bufLen) break;
      final rem = num - i * _up;
      final coef = _coef;
      final taps = _taps;
      if (_exact) {
        final base = rem * taps;
        if (nch == 2) {
          final b0 = _buf[0], b1 = _buf[1];
          var a0 = 0.0, a1 = 0.0, c0 = 0.0, c1 = 0.0;
          for (var d = 0; d < taps; d += 4) {
            final k0 = coef[base + d], k1 = coef[base + d + 1];
            final k2 = coef[base + d + 2], k3 = coef[base + d + 3];
            final j = rel + d;
            a0 += k0 * b0[j] + k1 * b0[j + 1];
            a1 += k2 * b0[j + 2] + k3 * b0[j + 3];
            c0 += k0 * b1[j] + k1 * b1[j + 1];
            c1 += k2 * b1[j + 2] + k3 * b1[j + 3];
          }
          ready[r++] = a0 + a1;
          ready[r++] = c0 + c1;
        } else {
          for (var c = 0; c < nch; c++) {
            final b = _buf[c];
            var a0 = 0.0, a1 = 0.0, a2 = 0.0, a3 = 0.0;
            for (var d = 0; d < taps; d += 4) {
              final j = rel + d;
              a0 += coef[base + d] * b[j];
              a1 += coef[base + d + 1] * b[j + 1];
              a2 += coef[base + d + 2] * b[j + 2];
              a3 += coef[base + d + 3] * b[j + 3];
            }
            ready[r++] = (a0 + a1) + (a2 + a3);
          }
        }
      } else {
        final fp = rem * _phases / _up;
        final p0 = fp.floor();
        final w1 = fp - p0;
        final w0 = 1 - w1;
        final b0 = p0 * taps, b1 = b0 + taps;
        for (var c = 0; c < nch; c++) {
          final b = _buf[c];
          var acc = 0.0;
          for (var d = 0; d < taps; d++) {
            acc += (w0 * coef[b0 + d] + w1 * coef[b1 + d]) * b[rel + d];
          }
          ready[r++] = acc;
        }
      }
      n++;
    }
    final produced = n - _outCount;
    _outCount = n;
    // Drop input that no future output needs.
    final nextI = (n * _down) ~/ _up;
    final drop = nextI - _bufBase;
    if (drop > 0 && drop <= _bufLen) {
      for (var c = 0; c < nch; c++) {
        _buf[c].setRange(0, _bufLen - drop, _buf[c], drop);
      }
      _bufLen -= drop;
      _bufBase += drop;
    }
    final out = Int16List(produced * nch);
    for (var k = 0; k < out.length; k++) {
      final v = (ready[k] * 32768.0).round();
      out[k] = v > 32767 ? 32767 : (v < -32768 ? -32768 : v);
    }
    return out;
  }

  static int _gcd(int a, int b) {
    while (b != 0) {
      final t = a % b;
      a = b;
      b = t;
    }
    return a;
  }

  static double _besselI0(double x) {
    var sum = 1.0, term = 1.0;
    final q = x * x / 4;
    for (var k = 1; k < 200; k++) {
      term *= q / (k * k);
      sum += term;
      if (term < sum * 1e-17) break;
    }
    return sum;
  }
}

/// Channel layout helpers for interleaved 16-bit PCM.
class ChannelMixer {
  ChannelMixer._();

  /// Averages all channels into one (rounded, no clipping possible).
  static Int16List toMono(Int16List interleaved, int channels) {
    if (channels == 1) return interleaved;
    final n = interleaved.length ~/ channels;
    final out = Int16List(n);
    for (var i = 0; i < n; i++) {
      var s = 0;
      for (var c = 0; c < channels; c++) {
        s += interleaved[i * channels + c];
      }
      out[i] = (s / channels).round();
    }
    return out;
  }

  /// Duplicates a mono signal into both stereo channels.
  static Int16List monoToStereo(Int16List mono) {
    final out = Int16List(mono.length * 2);
    for (var i = 0; i < mono.length; i++) {
      out[2 * i] = mono[i];
      out[2 * i + 1] = mono[i];
    }
    return out;
  }

  /// Converts between channel counts: N to 1 averages, 1 to N duplicates,
  /// N to 2 (N > 2) keeps the first two channels (front left/right in
  /// FFmpeg order; AAC 5.1 order puts center first, callers that care
  /// should remap before).
  static Int16List convert(Int16List interleaved, int from, int to) {
    if (from == to) return interleaved;
    if (to == 1) return toMono(interleaved, from);
    final n = interleaved.length ~/ from;
    final out = Int16List(n * to);
    for (var i = 0; i < n; i++) {
      for (var c = 0; c < to; c++) {
        out[i * to + c] = from == 1 ? interleaved[i] : interleaved[i * from + (c < from ? c : from - 1)];
      }
    }
    return out;
  }

  /// PcmBlock variant of [convert].
  static PcmBlock convertBlock(PcmBlock b, int to) =>
      PcmBlock(convert(b.samples, b.channels, to), b.sampleRate, to, ptsUs: b.ptsUs);
}
