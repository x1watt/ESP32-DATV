import 'dart:math' as math;
import 'dart:typed_data';

/// In-place radix-2 complex FFT of interleaved re/im data (n = power of two).
class Fft {
  Fft(this.n) : _cos = Float64List(n ~/ 2), _sin = Float64List(n ~/ 2), _rev = Int32List(n) {
    assert(n & (n - 1) == 0);
    for (var i = 0; i < n ~/ 2; i++) {
      _cos[i] = math.cos(2 * math.pi * i / n);
      _sin[i] = -math.sin(2 * math.pi * i / n);
    }
    final bits = n.bitLength - 1;
    for (var i = 0; i < n; i++) {
      var r = 0, x = i;
      for (var b = 0; b < bits; b++) {
        r = (r << 1) | (x & 1);
        x >>= 1;
      }
      _rev[i] = r;
    }
  }

  final int n;
  final Float64List _cos, _sin;
  final Int32List _rev;

  void transform(Float64List d) {
    for (var i = 0; i < n; i++) {
      final j = _rev[i];
      if (j > i) {
        final tr = d[2 * i], ti = d[2 * i + 1];
        d[2 * i] = d[2 * j];
        d[2 * i + 1] = d[2 * j + 1];
        d[2 * j] = tr;
        d[2 * j + 1] = ti;
      }
    }
    for (var size = 2; size <= n; size <<= 1) {
      final half = size >> 1, step = n ~/ size;
      for (var start = 0; start < n; start += size) {
        for (var k = 0; k < half; k++) {
          final wr = _cos[k * step], wi = _sin[k * step];
          final a = 2 * (start + k), b = 2 * (start + k + half);
          final xr = d[b] * wr - d[b + 1] * wi, xi = d[b] * wi + d[b + 1] * wr;
          d[b] = d[a] - xr;
          d[b + 1] = d[a + 1] - xi;
          d[a] += xr;
          d[a + 1] += xi;
        }
      }
    }
  }
}

/// Averaged power spectrum (Welch, Hann window, 50 % overlap) of a burst, DC in the middle,
/// in dB relative to full scale per bin.
Float32List welchSpectrumDb(Float32List iq, int nfft) {
  final f = Fft(nfft);
  final win = Float64List(nfft);
  var wsum = 0.0;
  for (var i = 0; i < nfft; i++) {
    win[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / nfft);
    wsum += win[i] * win[i];
  }
  final acc = Float64List(nfft);
  final buf = Float64List(2 * nfft);
  final n = iq.length ~/ 2;
  var segs = 0;
  for (var s = 0; s + nfft <= n; s += nfft ~/ 2) {
    for (var i = 0; i < nfft; i++) {
      buf[2 * i] = iq[2 * (s + i)] * win[i];
      buf[2 * i + 1] = iq[2 * (s + i) + 1] * win[i];
    }
    f.transform(buf);
    for (var i = 0; i < nfft; i++) {
      acc[i] += buf[2 * i] * buf[2 * i] + buf[2 * i + 1] * buf[2 * i + 1];
    }
    segs++;
  }
  final out = Float32List(nfft);
  for (var i = 0; i < nfft; i++) {
    final p = acc[(i + nfft ~/ 2) % nfft] / (segs == 0 ? 1 : segs) / (wsum * nfft);
    out[i] = 10 * math.log(p + 1e-20) / math.ln10;
  }
  return out;
}
