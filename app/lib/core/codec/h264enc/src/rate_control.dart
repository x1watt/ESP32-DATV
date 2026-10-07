// Constant bitrate control with a VBV style buffer model.
//
// The buffer models the encoder output queue drained at a constant rate. A
// frame of b bits is admitted only when fill + b <= buffer size, which is the
// decoder underflow (encoder overflow) guarantee the transport muxer relies
// on.
//
// The transport mux has no headroom, so the controller is deliberately
// conservative: its internal model drains at [rateMargin] times the nominal
// rate and its buffer is at most [maxBufferSeconds] of the nominal rate (and
// never larger than vbvBits). Since bits emitted up to any time are bounded
// by the drained budget plus the buffer size, the average over 10 s stays
// at or below the target and any 2 s window stays within about 9% of it.

import 'dart:math' as math;
import 'dart:typed_data';

double qpToQstep(double qp) => 0.625 * math.pow(2.0, qp / 6.0);

double qstepToQp(double qs) => 6.0 * math.log(qs / 0.625) / math.ln2;

class RateController {
  RateController({
    required this.bitrate,
    required this.fps,
    required this.vbvBits,
    required this.qpMin,
    required this.qpMax,
    required this.gopFrames,
    required this.mbRows,
  })  : bitsPerFrame = bitrate / fps,
        drainPerFrame = rateMargin * bitrate / fps,
        bufferBits = math.min(vbvBits.toDouble(), maxBufferSeconds * bitrate),
        _rowCplx = Float64List(mbRows),
        _rowCum = Float64List(mbRows + 1);

  final int bitrate;
  final int fps;
  final int vbvBits;
  final int qpMin, qpMax;
  final int gopFrames;
  final int mbRows;
  final double bitsPerFrame;

  /// Fraction of the nominal rate the internal model drains per second.
  static const double rateMargin = 0.96;

  /// Largest internal buffer in seconds of the nominal rate.
  static const double maxBufferSeconds = 0.25;

  /// Bits drained from the model buffer per nominal frame interval.
  final double drainPerFrame;

  /// Drain for the current frame: the pts distance to the previous frame
  /// times the rate, clamped to [0.25, 1] nominal frame intervals. Frames
  /// arriving faster than the configured fps therefore get less budget each,
  /// and a frame never gets more than bitrate / fps on average.
  double _drain = 0;
  int _lastPts = 0;
  bool _havePts = false;

  void _updateDrain(int ptsUs) {
    var frac = 1.0;
    if (_havePts && ptsUs > _lastPts) {
      frac = (ptsUs - _lastPts) * fps / 1e6;
      if (frac < 0.25) frac = 0.25;
      if (frac > 1.0) frac = 1.0;
    }
    _lastPts = ptsUs;
    _havePts = true;
    _drain = drainPerFrame * frac;
  }

  /// Effective buffer size in bits (<= vbvBits).
  final double bufferBits;

  /// Encoder buffer occupancy in bits after the last drain.
  double fill = 0;

  /// Highest occupancy seen right after adding a frame (for tests/stats).
  double peakFill = 0;

  // Model: bits = k * complexity / qstep.
  double _kI = 0.9;
  double _kP = 0.45;
  bool _haveI = false, _haveP = false;
  double _lastQpP = -1;
  double _lastQpI = -1;

  final Float64List _rowCplx;
  final Float64List _rowCum;
  double _target = 0;
  int _frameQp = 26;
  int _lastRowQp = 26;

  /// Largest frame (in bits) that can be emitted now without overflow.
  int get maxFrameBits => (bufferBits - fill).floor();

  int get frameQp => _frameQp;
  double get targetBits => _target;

  /// Fill level the controller steers to between I frames.
  double get _fillTarget => bufferBits * 0.2;

  /// Chooses the frame QP. [rowCplx] holds per macroblock row complexity.
  int startFrame(bool idr, Float64List rowCplx, int ptsUs) {
    _updateDrain(ptsUs);
    var cplx = 0.0;
    for (var r = 0; r < mbRows; r++) {
      _rowCplx[r] = rowCplx[r];
      _rowCum[r] = cplx;
      cplx += rowCplx[r];
    }
    _rowCum[mbRows] = cplx;
    final room = bufferBits - fill;
    double target;
    double qp;
    if (idr) {
      // Aim the I frame at a quality close to the recent P frames, bounded
      // by the room in the buffer.
      final maxT = room * 0.7;
      final guess = math.min(_drain * math.max(4.0, gopFrames / 6.0),
          bufferBits * 0.6);
      target = math.min(maxT, guess);
      qp = qstepToQp(_kI * cplx / math.max(target, 1));
      if (_haveP && _lastQpP >= 0) {
        final q2 = _lastQpP - 2;
        final bitsAtQ2 = _kI * cplx / qpToQstep(q2);
        if (bitsAtQ2 <= maxT) {
          qp = math.min(qp, q2);
          target = bitsAtQ2;
        } else {
          qp = math.max(qp, q2);
        }
      }
    } else {
      final d = math.max(2.0, math.min(gopFrames * 0.5, fps * 0.5));
      target = _drain + (_fillTarget - fill) / d;
      target = math.max(target, _drain * 0.25);
      target = math.min(target, room * 0.5);
      qp = qstepToQp(_kP * cplx / math.max(target, 1));
      if (_haveP && _lastQpP >= 0) {
        // Smooth frame to frame changes unless the buffer is in danger.
        final danger = fill > bufferBits * 0.5;
        final up = danger ? 6.0 : 3.0;
        qp = qp.clamp(_lastQpP - 3.0, _lastQpP + up);
      } else if (_haveI && _lastQpI >= 0) {
        qp = math.max(qp, _lastQpI);
      }
    }
    _target = math.max(target, 1);
    var q = qp.round();
    if (q < qpMin) q = qpMin;
    if (q > qpMax) q = qpMax;
    _frameQp = q;
    _lastRowQp = q;
    return q;
  }

  /// Retry after an oversized frame: raises the frame QP.
  int retry(int bits, int maxBits) {
    final over = bits / math.max(maxBits, 1);
    final step = math.max(2, (6 * math.log(over) / math.ln2).ceil() + 1);
    _frameQp = math.min(qpMax, _frameQp + step);
    _lastRowQp = _frameQp;
    _target = math.min(_target, maxBits * 0.7);
    return _frameQp;
  }

  /// QP for macroblock row [row] given the bits spent so far in the frame.
  int rowQp(int row, int bitsSoFar) {
    if (row == 0) return _frameQp;
    final total = _rowCum[mbRows];
    final frac = total > 0 ? _rowCum[row] / total : row / mbRows;
    final expected = _target * frac;
    final maxBits = maxFrameBits.toDouble();
    var delta = 0;
    final dev = (bitsSoFar - expected) / _target;
    delta = (dev * 8).round();
    if (delta < -3) delta = -3;
    if (delta > 6) delta = 6;
    var q = _frameQp + delta;
    // Smooth row to row changes.
    if (q > _lastRowQp + 2) q = _lastRowQp + 2;
    if (q < _lastRowQp - 2) q = _lastRowQp - 2;
    // Emergency brake when the frame approaches the buffer limit.
    final remainFrac = 1 - frac;
    if (bitsSoFar + _target * remainFrac > maxBits * 0.85) {
      q = math.max(q, _lastRowQp + 4);
    }
    if (bitsSoFar > maxBits * 0.75) q = qpMax;
    if (q < qpMin) q = qpMin;
    if (q > qpMax) q = qpMax;
    _lastRowQp = q;
    return q;
  }

  /// Commits a coded frame of [bits] with average QP [avgQp].
  void endFrame(int bits, double avgQp, bool idr, double cplx,
      {bool modelValid = true}) {
    fill += bits;
    if (fill > peakFill) peakFill = fill;
    fill -= _drain;
    if (fill < 0) fill = 0;
    if (!modelValid || cplx <= 0) return;
    final kObs = bits * qpToQstep(avgQp) / cplx;
    if (idr) {
      _kI = _haveI ? 0.5 * _kI + 0.5 * kObs : kObs;
      _haveI = true;
      _lastQpI = avgQp;
    } else {
      _kP = _haveP ? 0.6 * _kP + 0.4 * kObs : kObs;
      _haveP = true;
      _lastQpP = avgQp;
    }
  }
}
