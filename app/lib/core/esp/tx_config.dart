/// Transmit settings and everything derived from them: samples per symbol, the actual
/// symbol rate, TS capacity, the stream budget and the firmware command line.
///
/// Port of the logic in `host/tx_dvbs.py` (auto_sps*, output_baud, budget tiers).
library;

import 'dart:math' as math;

import '../dvb/dvbs.dart';
import '../dvb/dvbs2.dart';

const int cpuHz = 160000000;
const int _p8MinPeriod = 75;
const int _a16MinPeriod = 80;

/// The 13 cm amateur band the firmware allows (MHz).
const double bandMinMhz = 2300.0;
const double bandMaxMhz = 2450.0;

const List<int> symbolRatePresets = [33000, 66000, 125000, 250000, 333000, 500000, 1000000];

enum Standard { dvbs, dvbs2 }

class Calibration {
  const Calibration({this.dcI = 0, this.dcQ = 0, this.iqGain = 1.0, this.iqPhaseDeg = 0.0});

  /// The example calibration of `host/cal.json` (measured on the author's board).
  static const example = Calibration(dcI: -1.401, dcQ: 2.938, iqGain: 0.99944, iqPhaseDeg: 0.079);
  static const none = Calibration();

  final double dcI, dcQ, iqGain, iqPhaseDeg;

  Map<String, Object> toJson() => {'dcI': dcI, 'dcQ': dcQ, 'iqGain': iqGain, 'iqPhaseDeg': iqPhaseDeg};

  static Calibration fromJson(Map<String, dynamic> j) => Calibration(
        dcI: (j['dcI'] as num?)?.toDouble() ?? 0,
        dcQ: (j['dcQ'] as num?)?.toDouble() ?? 0,
        iqGain: (j['iqGain'] as num?)?.toDouble() ?? 1,
        iqPhaseDeg: (j['iqPhaseDeg'] as num?)?.toDouble() ?? 0,
      );
}

class TxConfig {
  const TxConfig({
    this.freqMhz = 2402.0,
    this.baud = 1000000,
    this.standard = Standard.dvbs,
    this.mod = Dvbs2Mod.qpsk,
    this.fec = '1/2',
    this.shortFrames = false,
    this.pilots = false,
    this.ppm = 0.0,
    this.amp = 0,
    this.ifm = 0,
    this.sps = 0,
    this.target = 0,
    this.invert = false,
    this.swapIq = false,
    this.cal = Calibration.example,
    this.seconds = 0,
  });

  final double freqMhz;
  final int baud;
  final Standard standard;
  final Dvbs2Mod mod;
  final String fec;
  final bool shortFrames, pilots;
  final double ppm;

  /// DAC amplitude 1..480; 0 = 300 for QPSK, 420 for 8PSK / 16APSK.
  final int amp;

  /// Centre = LO + ifm * baud (-6..6).
  final int ifm;

  /// Samples per symbol; 0 = automatic.
  final int sps;

  /// ESP ring fill target in pairs of bytes; 0 = automatic.
  final int target;
  final bool invert, swapIq;
  final Calibration cal;

  /// Stop after this many seconds; 0 = until stopped.
  final int seconds;

  Dvbs2Mod get effectiveMod => standard == Standard.dvbs ? Dvbs2Mod.qpsk : mod;

  List<String> get fecChoices =>
      standard == Standard.dvbs ? dvbsFecRates : dvbs2Rates(effectiveMod, short: shortFrames);

  TxConfig copyWith({
    double? freqMhz,
    int? baud,
    Standard? standard,
    Dvbs2Mod? mod,
    String? fec,
    bool? shortFrames,
    bool? pilots,
    double? ppm,
    int? amp,
    int? ifm,
    int? sps,
    int? target,
    bool? invert,
    bool? swapIq,
    Calibration? cal,
    int? seconds,
  }) {
    final c = TxConfig(
      freqMhz: freqMhz ?? this.freqMhz,
      baud: baud ?? this.baud,
      standard: standard ?? this.standard,
      mod: mod ?? this.mod,
      fec: fec ?? this.fec,
      shortFrames: shortFrames ?? this.shortFrames,
      pilots: pilots ?? this.pilots,
      ppm: ppm ?? this.ppm,
      amp: amp ?? this.amp,
      ifm: ifm ?? this.ifm,
      sps: sps ?? this.sps,
      target: target ?? this.target,
      invert: invert ?? this.invert,
      swapIq: swapIq ?? this.swapIq,
      cal: cal ?? this.cal,
      seconds: seconds ?? this.seconds,
    );
    // keep the code rate valid for the new standard / modulation / frame
    if (!c.fecChoices.contains(c.fec)) return c.copyWith(fec: c.fecChoices.first);
    return c;
  }

  Map<String, Object> toJson() => {
        'freqMhz': freqMhz,
        'baud': baud,
        'standard': standard.name,
        'mod': mod.name,
        'fec': fec,
        'shortFrames': shortFrames,
        'pilots': pilots,
        'ppm': ppm,
        'amp': amp,
        'ifm': ifm,
        'sps': sps,
        'target': target,
        'invert': invert,
        'swapIq': swapIq,
        'cal': cal.toJson(),
        'seconds': seconds,
      };

  static TxConfig fromJson(Map<String, dynamic> j) {
    const d = TxConfig();
    return TxConfig(
      freqMhz: (j['freqMhz'] as num?)?.toDouble() ?? d.freqMhz,
      baud: (j['baud'] as num?)?.toInt() ?? d.baud,
      standard: Standard.values.asNameMap()[j['standard']] ?? d.standard,
      mod: Dvbs2Mod.values.asNameMap()[j['mod']] ?? d.mod,
      fec: j['fec'] as String? ?? d.fec,
      shortFrames: j['shortFrames'] as bool? ?? d.shortFrames,
      pilots: j['pilots'] as bool? ?? d.pilots,
      ppm: (j['ppm'] as num?)?.toDouble() ?? d.ppm,
      amp: (j['amp'] as num?)?.toInt() ?? d.amp,
      ifm: (j['ifm'] as num?)?.toInt() ?? d.ifm,
      sps: (j['sps'] as num?)?.toInt() ?? d.sps,
      target: (j['target'] as num?)?.toInt() ?? d.target,
      invert: j['invert'] as bool? ?? d.invert,
      swapIq: j['swapIq'] as bool? ?? d.swapIq,
      cal: j['cal'] is Map ? Calibration.fromJson((j['cal'] as Map).cast<String, dynamic>()) : d.cal,
      seconds: (j['seconds'] as num?)?.toInt() ?? d.seconds,
    ).copyWith();
  }
}

class ConfigError implements Exception {
  ConfigError(this.message);
  final String message;
  @override
  String toString() => message;
}

int _pyRound(double x) {
  // Python's round(): halves go to the even neighbour
  final r = x.roundToDouble();
  if ((x - x.truncateToDouble()).abs() == 0.5) {
    final f = x.floorToDouble();
    return (f % 2 == 0 ? f : f + 1).toInt();
  }
  return r.toInt();
}

int autoSpsQpsk(int baud) {
  if (baud == 1000000) return 8;
  (double, int)? best;
  for (final period in [20, 24]) {
    final sps = _pyRound(cpuHz / (period * baud));
    if (sps >= 16 && sps <= 232) {
      final err = (cpuHz / (period * sps) / baud - 1).abs();
      if (err <= 0.01 && (best == null || err < best.$1 - 1e-9)) best = (err, sps);
    }
  }
  if (best != null) return best.$2;
  return baud * 16 <= 4000000 ? 16 : (baud * 8 <= 4000000 ? 8 : 4);
}

int autoSps16apsk(int baud) {
  if (baud == 1000000) return 8;
  if (baud < 2000 || baud > 500000) {
    throw ConfigError('16APSK: symbol rate must be 2000 .. 500000 Bd or 1000000 Bd');
  }
  final s = _pyRound(cpuHz / (20 * baud));
  if (s >= 16 && s <= 24 && (cpuHz / (20 * s) / baud - 1).abs() <= 0.01) return s;
  for (var sps = 24; sps > 3; sps--) {
    if (cpuHz ~/ (baud * sps) >= _a16MinPeriod) return sps;
  }
  throw ConfigError('16APSK: no sample rate fits the firmware timing budget');
}

int autoSps8psk(int baud) {
  if (baud == 1000000) return 8;
  final s = _pyRound(cpuHz / (20 * baud));
  if (s >= 16 && s <= 64 && (cpuHz / (20 * s) / baud - 1).abs() <= 0.01) return s;
  for (var sps = 64; sps > 15; sps--) {
    if (cpuHz ~/ (baud * sps) >= _p8MinPeriod) return sps;
  }
  throw ConfigError('8PSK: symbol rate must be 1000000, ${cpuHz ~/ 20 ~/ 64} .. ${cpuHz ~/ 20 ~/ 16} Bd, '
      'or below that down to about 10000 Bd');
}

/// The symbol rate the firmware actually produces.
double outputBaud(int baud, int sps, Dvbs2Mod mod) {
  final sampleHz = baud * sps;
  final period = (cpuHz + sampleHz ~/ 2) ~/ sampleHz;
  if (mod == Dvbs2Mod.psk8 && period != 20 && sps >= 16 && sps <= 64 && cpuHz ~/ sampleHz >= _p8MinPeriod) {
    return baud.toDouble();
  }
  if (mod == Dvbs2Mod.apsk16 && period != 20 && sps >= 4 && sps <= 24 && cpuHz ~/ sampleHz >= _a16MinPeriod) {
    return baud.toDouble();
  }
  final generic = (mod == Dvbs2Mod.psk8 && sps >= 16 && sps <= 64 && period == 20) ||
      (mod == Dvbs2Mod.qpsk && sps >= 16 && sps <= 232 && (period == 20 || period == 24)) ||
      (mod == Dvbs2Mod.apsk16 && sps >= 16 && sps <= 24 && period == 20);
  if (generic && cpuHz ~/ baud == period * sps) return baud.toDouble();
  return cpuHz / (period * sps);
}

/// Video / audio / PSI budget for a channel (tiers of `host/tx_dvbs.py`).
class StreamBudget {
  const StreamBudget({
    required this.muxRate,
    required this.audioKbps,
    required this.audioChannels,
    required this.audioRate,
    required this.fps,
    required this.patPeriod,
    required this.maxWidth,
    required this.videoBitrate,
  });

  final int muxRate;
  final int audioKbps, audioChannels, audioRate;
  final int fps;
  final double patPeriod;
  final int maxWidth;
  final int videoBitrate;

  int get pcrPeriodMs => audioKbps > 50 ? 40 : 100;

  static StreamBudget forCapacity(double cap, {int width = 640, int videoKbps = 0, bool audio = true}) {
    final mux = (cap * 0.965).truncate();
    int aud, ach, ar, fps, w;
    double pat;
    if (mux >= 600000) {
      (aud, ach, ar, fps, pat, w) = (96, 2, 48000, 25, 0.2, width);
    } else if (mux >= 200000) {
      (aud, ach, ar, fps, pat, w) = (32, 1, 24000, 15, 0.5, math.min(width, 320));
    } else {
      (aud, ach, ar, fps, pat, w) = (mux < 40000 ? 8 : 16, 1, 16000, 10, 1.0, math.min(width, 160));
    }
    if (!audio) aud = 0;
    final psi = (3 * 188 * 8 / pat).truncate();
    final vb = videoKbps > 0 ? videoKbps * 1000 : ((mux - aud * 1000 - psi) * 0.88).truncate();
    return StreamBudget(
      muxRate: mux,
      audioKbps: aud,
      audioChannels: ach,
      audioRate: ar,
      fps: fps,
      patPeriod: pat,
      maxWidth: w,
      videoBitrate: vb,
    );
  }
}

/// Everything the transmitter needs, computed from a [TxConfig].
class TxPlan {
  TxPlan._(this.config, this.sps, this.amp, this.target, this.baudAct, this.capacity, this.ifHz, this.khz,
      this.warnings);

  factory TxPlan.of(TxConfig c) {
    if (c.freqMhz < bandMinMhz || c.freqMhz > bandMaxMhz) {
      throw ConfigError('Transmission only in the 13 cm band (2300..2450 MHz)');
    }
    if (c.baud < 2000 || c.baud > 1000000) throw ConfigError('Symbol rate must be 2000 .. 1000000 Bd');
    final mod = c.effectiveMod;
    if (!c.fecChoices.contains(c.fec)) throw ConfigError('FEC ${c.fec} not available here');
    final amp = c.amp > 0 ? c.amp : (mod == Dvbs2Mod.qpsk ? 300 : 420);
    if (amp > 480) throw ConfigError('Amplitude must be 1..480');
    if (c.ifm.abs() > 6) throw ConfigError('IF offset must be -6..6');
    if (mod == Dvbs2Mod.apsk16 && (c.baud < 2000 || c.baud > 500000)) autoSps16apsk(c.baud);
    final sps = c.sps > 0
        ? c.sps
        : switch (mod) {
            Dvbs2Mod.apsk16 => autoSps16apsk(c.baud),
            Dvbs2Mod.psk8 => autoSps8psk(c.baud),
            Dvbs2Mod.qpsk => autoSpsQpsk(c.baud),
          };
    final a16s8 = mod == Dvbs2Mod.apsk16 && c.baud == 1000000;
    if (a16s8 && sps != 8) throw ConfigError('16APSK at 1 MS/s requires 8 samples per symbol');
    final target = c.target > 0
        ? c.target
        : (mod == Dvbs2Mod.psk8 && sps == 8)
            ? 6000
            : mod == Dvbs2Mod.apsk16
                ? (a16s8 ? 7000 : 2500)
                : 3000;
    final baudAct = outputBaud(c.baud, sps, mod);
    final warnings = <String>[];
    if (mod != Dvbs2Mod.qpsk && baudAct > 460000 && baudAct < 1000000) {
      warnings.add('${mod.label} at ${(baudAct / 1e3).round()} kBd needs ${(baudAct / 2e3).round()} kB/s '
          'over USB: watch the ESP buffer, lower the symbol rate if it runs dry');
    }
    if ((baudAct / c.baud - 1).abs() > 0.01) {
      warnings.add('$sps samples per symbol give ${baudAct.toStringAsFixed(1)} Bd, not ${c.baud}');
    }
    if (amp > 430) warnings.add('Amplitude above about 430 compresses the output (more out-of-band emission)');
    final cap = c.standard == Standard.dvbs2
        ? dvbs2TsRate(baudAct, c.fec, mod, short: c.shortFrames, pilots: c.pilots)
        : dvbsTsRate(baudAct, c.fec);
    final ifHz = _pyRound(c.ifm * baudAct);
    final khz = _pyRound((c.freqMhz * 1e6 - ifHz) / 1000 / (1 + c.ppm * 1e-6));
    // the same band check as the firmware (main.c, tx_qpsk_lut)
    final halfBw = baudAct * 1.35 / 2;
    final ifh = c.ifm * baudAct;
    final sigLo = khz * 1000.0 + math.min(ifh, 0) - halfBw;
    final sigHi = khz * 1000.0 + math.max(ifh, 0) + halfBw;
    if (sigLo < bandMinMhz * 1e6 || sigHi > bandMaxMhz * 1e6) {
      throw ConfigError('The occupied band ${(sigLo / 1e6).toStringAsFixed(3)}..${(sigHi / 1e6).toStringAsFixed(3)} MHz '
          'leaves the 13 cm band (2300..2450 MHz)');
    }
    return TxPlan._(c, sps, amp, target, baudAct, cap, ifHz, khz, warnings);
  }

  final TxConfig config;
  final int sps, amp, target;
  final double baudAct;

  /// Useful TS bit rate.
  final double capacity;
  final int ifHz, khz;
  final List<String> warnings;

  Dvbs2Mod get mod => config.effectiveMod;
  bool get a16s8 => mod == Dvbs2Mod.apsk16 && config.baud == 1000000;
  bool get bits3 => mod == Dvbs2Mod.psk8 && sps == 8;
  double get occupiedHz => baudAct * 1.35;

  /// (min_todo, max_chunk) in pairs, as in tx_dvbs.py.
  (int, int) get chunking => a16s8 ? (400, 4096) : (sps == 8 && mod == Dvbs2Mod.psk8) ? (400, 2048) : (32, 1024);

  String get label {
    final c = config;
    final std = c.standard == Standard.dvbs2
        ? 'DVB-S2 ${mod.label} ${c.shortFrames ? 'short' : 'normal'}${c.pilots ? ', pilots' : ''}'
        : 'DVB-S';
    return '$std FEC ${c.fec}';
  }

  /// The firmware command line (without the newline).
  String get command {
    final c = config;
    final secs = c.seconds > 0 ? c.seconds + 30 : 86400;
    final cmd = switch (mod) { Dvbs2Mod.psk8 => 'PSK8T', Dvbs2Mod.apsk16 => 'A16T', Dvbs2Mod.qpsk => 'QPSKT' };
    final gam = mod == Dvbs2Mod.apsk16 ? ' ${_pyRound(100 * apsk16Gamma[c.fec]!)}' : '';
    final dc4i = _pyRound(16 * c.cal.dcI), dc4q = _pyRound(16 * c.cal.dcQ);
    final gq = _pyRound(c.cal.iqGain * 1e4), ph = _pyRound(c.cal.iqPhaseDeg * 1e3);
    return '$cmd ${(khz / 1000).toStringAsFixed(3)} ${c.baud} $sps $amp $secs ${c.ifm} $target $dc4i $dc4q $gq $ph$gam';
  }

  /// The spectrum centre from the LO the ESP reports.
  double centreHz(double loHz) => loHz * (1 + config.ppm * 1e-6) + ifHz;

  StreamBudget budget({int width = 640, int videoKbps = 0, bool audio = true}) =>
      StreamBudget.forCapacity(capacity, width: width, videoKbps: videoKbps, audio: audio);
}
