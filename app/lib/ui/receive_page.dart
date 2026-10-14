import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../engine/engine.dart';
import 'app_controller.dart';
import 'widgets.dart';

class ReceivePage extends StatelessWidget {
  const ReceivePage({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    final rx = c.receiving;
    final canStart = c.board == BoardState.datv && !c.transmitting;
    final f = c.rxFrame;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Section(title: 'Receiver', children: [
        const Text('The ESP32-C3 cannot receive continuously: it records short bursts (1 ms at 16 MS/s, or '
            '0.2 ms at 80 MS/s, about eight per second). That is enough to see a signal, measure its level, '
            'frequency and quality, and show its constellation, but not to decode the video.'),
        Row(children: [
          Expanded(
            child: NumberField(
              label: 'Signal frequency (MHz)',
              value: c.rxSignalMhz,
              decimals: 3,
              help: '2200 to 2800 MHz',
              onChanged: (v) {
                c.rxSignalMhz = v.clamp(2200.5, 2799.5);
                c.rxSettingsChanged();
              },
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: NumberField(
              label: 'Symbol rate (S/s, QPSK)',
              value: c.rxBaud.toDouble(),
              help: 'for the constellation and MER',
              onChanged: (v) {
                c.rxBaud = v.round().clamp(10000, 2000000);
                c.rxSettingsChanged();
              },
            ),
          ),
        ]),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 16, label: Text('16 MS/s, 1 ms bursts')),
            ButtonSegment(value: 80, label: Text('80 MS/s, wide')),
          ],
          selected: {c.rxRate},
          onSelectionChanged: (s) {
            c.rxRate = s.first;
            c.rxSettingsChanged();
          },
        ),
        Row(children: [
          const SizedBox(width: 150, child: Text('Gain')),
          Switch(
            value: c.rxGain < 0,
            onChanged: (auto) {
              c.rxGain = auto ? -1 : math.min(60, c.rxGainMax);
              c.rxSettingsChanged();
            },
          ),
          const SizedBox(width: 8),
          Text(c.rxGain < 0 ? 'Automatic' : 'Manual'),
          if (c.rxGain >= 0)
            Expanded(
              child: Slider(
                value: c.rxGain.toDouble().clamp(0, c.rxGainMax.toDouble()),
                min: 0,
                max: c.rxGainMax.toDouble(),
                divisions: c.rxGainMax,
                label: '${c.rxGain}',
                onChanged: (v) {
                  c.rxGain = v.round();
                  c.rxSettingsChanged();
                },
              ),
            ),
        ]),
        Row(children: [
          if (!rx)
            FilledButton.icon(
              onPressed: canStart ? c.startRx : null,
              icon: const Icon(Icons.radar),
              label: const Text('Start receiving'),
            )
          else
            FilledButton.icon(onPressed: c.stopRx, icon: const Icon(Icons.stop), label: const Text('Stop')),
          const SizedBox(width: 12),
          Expanded(
            child: Text(c.board != BoardState.datv
                ? 'Connect a board with the DATV firmware first (Device page).'
                : c.transmitting
                    ? 'The board is transmitting.'
                    : 'LO ${(c.rxSignalMhz - AppController.rxOffsetHz / 1e6).toStringAsFixed(3)} MHz, '
                        'signal expected 500 kHz above it'),
          ),
        ]),
      ]),
      if (c.message != null) InfoBanner(c.message!, error: c.messageIsError),
      if (f != null) ...[
        Section(title: 'Spectrum', children: [
          SizedBox(
            height: 220,
            child: CustomPaint(
              painter: _SpectrumPainter(c.rxAverage, f.sampleRate, f.loHz, c.rxSignalMhz * 1e6, c.rxBaud * 1.35,
                  Theme.of(context).colorScheme),
            ),
          ),
          SizedBox(height: 140, child: _Waterfall(rows: c.rxWaterfall)),
        ]),
        LayoutBuilder(builder: (context, box) {
          final stats = _Stats(c: c, f: f);
          final con = SizedBox(
            width: 260,
            height: 260,
            child: CustomPaint(painter: _ConstellationPainter(c.rxConstellation, Theme.of(context).colorScheme)),
          );
          final card = Section(title: 'Signal', children: [
            if (box.maxWidth > 640)
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [con, const SizedBox(width: 16), Expanded(child: stats)])
            else ...[Center(child: con), stats],
          ]);
          return card;
        }),
      ],
    ]);
  }
}

class _Stats extends StatelessWidget {
  const _Stats({required this.c, required this.f});
  final AppController c;
  final RxFrame f;

  @override
  Widget build(BuildContext context) {
    String db(double v) => v.isNaN ? '-' : '${v.toStringAsFixed(1)} dB';
    final centre = c.rxCentreAvg;
    final err = centre - c.rxSignalMhz * 1e6;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      KeyValue('Level', '${f.levelDbfs.toStringAsFixed(1)} dBFS, gain index ${f.gain}'),
      KeyValue('SNR', db(c.rxSnrAvg)),
      KeyValue('MER', db(c.rxMerAvg)),
      KeyValue('Signal', c.rxSignalSeen ? 'present in the last burst' : 'not found in the last burst (SNR under 3 dB)'),
      KeyValue('Signal centre', centre.isNaN
          ? '-'
          : '${(centre / 1e6).toStringAsFixed(4)} MHz (${err >= 0 ? '+' : ''}${(err / 1e3).toStringAsFixed(1)} kHz, '
              '${(err / centre * 1e6).toStringAsFixed(1)} ppm)'),
      KeyValue('Bursts', '${f.bursts} (${c.rxSignalBursts} with the signal), ${f.burstsPerSecond.toStringAsFixed(1)} per second'
          '${f.crcErrors > 0 ? ', ${f.crcErrors} damaged' : ''}'),
      const SizedBox(height: 8),
      Text('The frequency error includes both crystals (transmitter and this board). With an accurate '
          'transmitter it is the correction this board needs.', style: Theme.of(context).textTheme.bodySmall),
    ]);
  }
}

class _SpectrumPainter extends CustomPainter {
  _SpectrumPainter(this.avg, this.fs, this.loHz, this.signalHz, this.bandwidth, this.cs);
  final Float32List? avg;
  final double fs, loHz, signalHz, bandwidth;
  final ColorScheme cs;

  @override
  void paint(Canvas canvas, Size size) {
    final a = avg;
    if (a == null) return;
    final n = a.length;
    final db = [for (var i = 0; i < n; i++) 10 * math.log(a[i] + 1e-20) / math.ln10];
    final sorted = List<double>.from(db)..sort();
    final floor = sorted[n ~/ 10] - 5, top = sorted[n - 1] + 5;
    double y(double v) => size.height * (1 - ((v - floor) / (top - floor)).clamp(0.0, 1.0));
    final grid = Paint()..color = cs.outlineVariant;
    // band of the expected signal
    final x0 = size.width * ((signalHz - loHz - bandwidth / 2) / fs + 0.5);
    final x1 = size.width * ((signalHz - loHz + bandwidth / 2) / fs + 0.5);
    canvas.drawRect(Rect.fromLTRB(x0, 0, x1, size.height), Paint()..color = cs.primary.withValues(alpha: 0.12));
    for (var k = -4; k <= 4; k++) {
      final x = size.width * (0.5 + k / 8);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
      final tp = TextPainter(
        text: TextSpan(
            text: ((loHz + k * fs / 8) / 1e6).toStringAsFixed(fs >= 40e6 ? 0 : 1),
            style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x + 2, size.height - 12));
    }
    final path = Path();
    for (var i = 0; i < n; i++) {
      final x = size.width * i / (n - 1);
      if (i == 0) {
        path.moveTo(x, y(db[i]));
      } else {
        path.lineTo(x, y(db[i]));
      }
    }
    canvas.drawPath(path, Paint()
      ..color = cs.primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2);
    final tp = TextPainter(
      text: TextSpan(text: '${(top - floor).toStringAsFixed(0)} dB range', style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, const Offset(4, 2));
  }

  @override
  bool shouldRepaint(covariant _SpectrumPainter old) => true;
}

class _Waterfall extends StatefulWidget {
  const _Waterfall({required this.rows});
  final List<Float32List> rows;

  @override
  State<_Waterfall> createState() => _WaterfallState();
}

class _WaterfallState extends State<_Waterfall> {
  ui.Image? _img;
  int _gen = 0;

  @override
  void didUpdateWidget(covariant _Waterfall oldWidget) {
    super.didUpdateWidget(oldWidget);
    _render();
  }

  @override
  void initState() {
    super.initState();
    _render();
  }

  void _render() {
    final rows = widget.rows;
    if (rows.isEmpty) return;
    final w = rows.first.length, h = rows.length;
    final all = <double>[for (final r in rows.take(8)) ...r]..sort();
    final lo = all[all.length ~/ 10], hi = all.last;
    final px = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      final r = rows[y];
      if (r.length != w) continue;
      for (var x = 0; x < w; x++) {
        final t = ((r[x] - lo) / (hi - lo + 1e-9)).clamp(0.0, 1.0);
        final o = 4 * (y * w + x);
        px[o] = (255 * math.min(1.0, t * 1.6)).round();
        px[o + 1] = (255 * math.max(0.0, t * 1.6 - 0.6)).round();
        px[o + 2] = (255 * (t < 0.5 ? t * 1.2 : 0.6 - (t - 0.5))).round().clamp(0, 255);
        px[o + 3] = 255;
      }
    }
    final gen = ++_gen;
    ui.decodeImageFromPixels(px, w, h, ui.PixelFormat.rgba8888, (img) {
      if (!mounted || gen != _gen) {
        img.dispose();
        return;
      }
      setState(() {
        _img?.dispose();
        _img = img;
      });
    });
  }

  @override
  void dispose() {
    _img?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _img == null ? const SizedBox.shrink() : RawImage(image: _img, fit: BoxFit.fill, width: double.infinity);
}

class _ConstellationPainter extends CustomPainter {
  _ConstellationPainter(this.sets, this.cs);
  final List<Float32List> sets;
  final ColorScheme cs;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawRect(r, Paint()..color = cs.surfaceContainerHighest);
    final c = r.center;
    final scale = size.width / 3.2;
    final axis = Paint()..color = cs.outlineVariant;
    canvas.drawLine(Offset(0, c.dy), Offset(size.width, c.dy), axis);
    canvas.drawLine(Offset(c.dx, 0), Offset(c.dx, size.height), axis);
    for (final p in [const Offset(1, 1), const Offset(-1, 1), const Offset(1, -1), const Offset(-1, -1)]) {
      canvas.drawCircle(c + p * (scale / math.sqrt2), 3, Paint()..color = cs.outline);
    }
    var age = 0;
    for (final s in sets) {
      final paint = Paint()..color = cs.primary.withValues(alpha: age == 0 ? 0.9 : 0.35);
      final pts = <Offset>[];
      for (var i = 0; i + 1 < s.length; i += 2) {
        pts.add(c + Offset(s[i] * scale, -s[i + 1] * scale));
      }
      canvas.drawPoints(ui.PointMode.points, pts, paint..strokeWidth = 2.5);
      age++;
    }
    final tp = TextPainter(
      text: TextSpan(text: 'QPSK constellation', style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, const Offset(6, 4));
  }

  @override
  bool shouldRepaint(covariant _ConstellationPainter old) => true;
}
