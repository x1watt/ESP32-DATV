import 'package:flutter/material.dart';

import '../core/dvb/dvbs2.dart';
import '../core/esp/tx_config.dart';
import 'app_controller.dart';
import 'widgets.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    final cfg = c.config;
    final locked = c.transmitting;
    final isS2 = cfg.standard == Standard.dvbs2;
    return AbsorbPointer(
      absorbing: locked,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (locked) const InfoBanner('Settings are locked while transmitting.'),
          Section(title: 'Radio', children: [
            NumberField(
              label: 'Frequency (MHz)',
              value: cfg.freqMhz,
              decimals: 3,
              help: '13 cm band, 2300 to 2450 MHz',
              onChanged: (v) => c.update(cfg.copyWith(freqMhz: v)),
            ),
            NumberField(
              label: 'Crystal error (ppm)',
              value: cfg.ppm,
              decimals: 2,
              signed: true,
              help: 'Measured error of your board\'s 40 MHz crystal',
              onChanged: (v) => c.update(cfg.copyWith(ppm: v)),
            ),
            LabeledSlider(
              label: 'Amplitude',
              value: (cfg.amp == 0 ? (cfg.effectiveMod == Dvbs2Mod.qpsk ? 300 : 420) : cfg.amp).toDouble(),
              min: 1,
              max: 480,
              divisions: 479,
              display: (v) => '${v.round()}${cfg.amp == 0 ? ' (auto)' : ''}',
              onChanged: (v) => c.update(cfg.copyWith(amp: v.round())),
              trailing: TextButton(onPressed: () => c.update(cfg.copyWith(amp: 0)), child: const Text('Auto')),
            ),
            LabeledSlider(
              label: 'IF offset (x symbol rate)',
              value: cfg.ifm.toDouble(),
              min: -6,
              max: 6,
              divisions: 12,
              display: (v) => v.round().toString(),
              onChanged: (v) => c.update(cfg.copyWith(ifm: v.round())),
            ),
          ]),
          Section(title: 'Modulation', children: [
            SegmentedButton<Standard>(
              segments: const [
                ButtonSegment(value: Standard.dvbs, label: Text('DVB-S')),
                ButtonSegment(value: Standard.dvbs2, label: Text('DVB-S2')),
              ],
              selected: {cfg.standard},
              onSelectionChanged: (s) => c.update(cfg.copyWith(standard: s.first)),
            ),
            if (isS2)
              Dropdown<Dvbs2Mod>(
                label: 'Constellation',
                value: cfg.mod,
                items: {for (final m in Dvbs2Mod.values) m: m.label},
                onChanged: (m) => c.update(cfg.copyWith(mod: m)),
              ),
            SymbolRateField(
              value: cfg.baud,
              onChanged: (v) => c.update(cfg.copyWith(baud: v)),
            ),
            Dropdown<String>(
              label: 'FEC',
              value: cfg.fec,
              items: {for (final f in cfg.fecChoices) f: f},
              onChanged: (f) => c.update(cfg.copyWith(fec: f)),
            ),
            if (isS2) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Short frames (16200 bits)'),
                value: cfg.shortFrames,
                onChanged: (v) => c.update(cfg.copyWith(shortFrames: v)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Pilots'),
                value: cfg.pilots,
                onChanged: (v) => c.update(cfg.copyWith(pilots: v)),
              ),
            ],
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Invert spectrum (Q to -Q)'),
              value: cfg.invert,
              onChanged: (v) => c.update(cfg.copyWith(invert: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Swap I and Q'),
              value: cfg.swapIq,
              onChanged: (v) => c.update(cfg.copyWith(swapIq: v)),
            ),
          ]),
          Section(title: 'Stream', children: [
            TextSetting(
              label: 'Service name',
              value: c.serviceName,
              onChanged: (v) => c.updateStream(() => c.serviceName = v),
            ),
            TextSetting(
              label: 'Provider',
              value: c.provider,
              onChanged: (v) => c.updateStream(() => c.provider = v),
            ),
            Dropdown<int>(
              label: 'Maximum picture width',
              value: c.width,
              items: const {160: '160', 320: '320', 480: '480', 640: '640', 854: '854', 960: '960', 1280: '1280'},
              onChanged: (v) => c.updateStream(() => c.width = v),
            ),
            NumberField(
              label: 'Video bit rate (kb/s, 0 = from capacity)',
              value: c.videoKbps.toDouble(),
              decimals: 0,
              onChanged: (v) => c.updateStream(() => c.videoKbps = v.round()),
            ),
            Dropdown<String>(
              label: 'Encoder speed',
              value: c.preset,
              items: const {'fast': 'Fast', 'medium': 'Better quality (slower)'},
              onChanged: (v) => c.updateStream(() => c.preset = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Audio'),
              value: c.audio,
              onChanged: (v) => c.updateStream(() => c.audio = v),
            ),
            NumberField(
              label: 'Stop after (seconds, 0 = never)',
              value: cfg.seconds.toDouble(),
              decimals: 0,
              onChanged: (v) => c.update(cfg.copyWith(seconds: v.round())),
            ),
          ]),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Advanced'),
            children: [
              NumberField(
                label: 'DAC samples per symbol (0 = automatic)',
                value: cfg.sps.toDouble(),
                decimals: 0,
                onChanged: (v) => c.update(cfg.copyWith(sps: v.round())),
              ),
              NumberField(
                label: 'ESP buffer target in byte pairs (0 = automatic)',
                value: cfg.target.toDouble(),
                decimals: 0,
                onChanged: (v) => c.update(cfg.copyWith(target: v.round())),
              ),
              const SizedBox(height: 8),
              Text('I/Q calibration', style: Theme.of(context).textTheme.titleSmall),
              NumberField(
                label: 'DC offset I (DAC codes)',
                value: cfg.cal.dcI,
                decimals: 3,
                signed: true,
                onChanged: (v) => c.update(cfg.copyWith(cal: _cal(cfg.cal, dcI: v))),
              ),
              NumberField(
                label: 'DC offset Q (DAC codes)',
                value: cfg.cal.dcQ,
                decimals: 3,
                signed: true,
                onChanged: (v) => c.update(cfg.copyWith(cal: _cal(cfg.cal, dcQ: v))),
              ),
              NumberField(
                label: 'Q gain (0.7 to 1.3)',
                value: cfg.cal.iqGain,
                decimals: 5,
                onChanged: (v) => c.update(cfg.copyWith(cal: _cal(cfg.cal, iqGain: v))),
              ),
              NumberField(
                label: 'Q phase (degrees)',
                value: cfg.cal.iqPhaseDeg,
                decimals: 3,
                signed: true,
                onChanged: (v) => c.update(cfg.copyWith(cal: _cal(cfg.cal, iqPhaseDeg: v))),
              ),
              Wrap(spacing: 8, children: [
                OutlinedButton(
                    onPressed: () => c.update(cfg.copyWith(cal: Calibration.example)),
                    child: const Text('Example calibration')),
                OutlinedButton(
                    onPressed: () => c.update(cfg.copyWith(cal: Calibration.none)), child: const Text('No calibration')),
              ]),
              const SizedBox(height: 8),
            ],
          ),
          PlanCard(c: c),
        ],
      ),
    );
  }

  static Calibration _cal(Calibration o, {double? dcI, double? dcQ, double? iqGain, double? iqPhaseDeg}) => Calibration(
        dcI: dcI ?? o.dcI,
        dcQ: dcQ ?? o.dcQ,
        iqGain: iqGain ?? o.iqGain,
        iqPhaseDeg: iqPhaseDeg ?? o.iqPhaseDeg,
      );
}

/// The derived values: actual symbol rate, bandwidth, capacity, budget, command.
class PlanCard extends StatelessWidget {
  const PlanCard({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    final err = c.planError;
    if (err != null) {
      return Card(
        color: Theme.of(context).colorScheme.errorContainer,
        child: Padding(padding: const EdgeInsets.all(16), child: Text(err)),
      );
    }
    final p = c.plan!;
    final b = p.budget(width: c.width, videoKbps: c.videoKbps, audio: c.audio);
    String k(num v) => (v / 1000).toStringAsFixed(1);
    final rows = <(String, String)>[
      ('Mode', p.label),
      ('Symbol rate', '${p.baudAct.toStringAsFixed(p.baudAct % 1 == 0 ? 0 : 1)} Bd, ${p.sps} samples per symbol'),
      ('Occupied bandwidth', '${k(p.occupiedHz)} kHz (roll-off 0.35)'),
      ('TS capacity', '${k(p.capacity)} kb/s'),
      ('Video', b.videoBitrate < 6000 ? 'too little capacity for video' : '${k(b.videoBitrate)} kb/s, up to ${b.maxWidth} px wide, ${b.fps} fps'),
      ('Audio', b.audioKbps == 0 ? 'off' : 'MPEG Layer II ${b.audioKbps} kb/s, ${b.audioRate} Hz, ${b.audioChannels == 1 ? 'mono' : 'stereo'}'),
      ('Command', p.command),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Result', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final (a, v) in rows) KeyValue(a, v),
            for (final w in p.warnings) Padding(padding: const EdgeInsets.only(top: 6), child: Text('Note: $w')),
          ],
        ),
      ),
    );
  }
}

class SymbolRateField extends StatelessWidget {
  const SymbolRateField({super.key, required this.value, required this.onChanged});
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final preset = symbolRatePresets.contains(value);
    return Row(children: [
      Expanded(
        child: Dropdown<int>(
          label: 'Symbol rate',
          value: preset ? value : -1,
          items: {
            for (final r in symbolRatePresets) r: r >= 1000000 ? '${r ~/ 1000000} MS/s' : '${r ~/ 1000} kS/s',
            -1: 'Custom',
          },
          onChanged: (v) => onChanged(v == -1 ? value : v),
        ),
      ),
      const SizedBox(width: 12),
      SizedBox(
        width: 140,
        child: NumberField(
          label: 'S/s',
          value: value.toDouble(),
          decimals: 0,
          onChanged: (v) => onChanged(v.round()),
        ),
      ),
    ]);
  }
}

