import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../engine/engine.dart';
import '../platform/capture/media_source.dart';
import 'app_controller.dart';
import 'widgets.dart';

class TransmitPage extends StatelessWidget {
  const TransmitPage({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    final tx = c.transmitting;
    final ready = c.board == BoardState.datv && c.planError == null;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Section(title: 'Source', children: [
        AbsorbPointer(
          absorbing: tx,
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (k, label, icon) in const [
              (SourceKind.file, 'Video file', Icons.movie),
              (SourceKind.camera, 'Camera', Icons.videocam),
              (SourceKind.screen, 'Screen', Icons.screen_share),
              (SourceKind.testPattern, 'Test pattern', Icons.grid_on),
              (SourceKind.nullPackets, 'Null packets', Icons.blur_on),
              (SourceKind.carrier, 'Carrier only', Icons.graphic_eq),
            ])
              ChoiceChip(
                avatar: Icon(icon, size: 18),
                label: Text(label),
                selected: c.sourceKind == k,
                onSelected: (_) => c.updateStream(() => c.sourceKind = k),
              ),
          ]),
        ),
        Text(_sourceHelp[c.sourceKind]!, style: Theme.of(context).textTheme.bodyMedium),
        if (c.sourceKind == SourceKind.testPattern)
          _PatternTextField(c: c),
        if (c.sourceKind == SourceKind.file)
          Row(children: [
            Expanded(child: Text(c.filePath ?? 'No file chosen', overflow: TextOverflow.ellipsis)),
            OutlinedButton(
              onPressed: tx
                  ? null
                  : () async {
                      final f = await openFile(acceptedTypeGroups: const [
                        XTypeGroup(label: 'Video', extensions: ['mp4', 'm4v', 'mov', 'ts']),
                      ]);
                      if (f != null) c.updateStream(() => c.filePath = f.path);
                    },
              child: const Text('Choose...'),
            ),
          ]),
        if (c.sourceKind == SourceKind.camera)
          _DevicePicker(
            label: 'Camera',
            devices: c.cameras,
            value: c.camera,
            enabled: !tx,
            onChanged: (d) => c.updateStream(() => c.camera = d),
          ),
        if (c.sourceKind == SourceKind.screen)
          _DevicePicker(
            label: 'Screen',
            devices: c.screens,
            value: c.screen,
            enabled: !tx,
            onChanged: (d) => c.updateStream(() => c.screen = d),
          ),
        if (c.sourceKind == SourceKind.camera || c.sourceKind == SourceKind.screen) ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Microphone sound'),
            value: c.micOn && c.audio,
            onChanged: tx ? null : (v) => c.updateStream(() {
                  c.micOn = v;
                  if (v) c.audio = true;
                }),
          ),
          if (c.micOn && c.audio)
            _DevicePicker(
              label: 'Microphone',
              devices: c.mics,
              value: c.mic,
              enabled: !tx,
              onChanged: (d) => c.updateStream(() => c.mic = d),
            ),
        ],
      ]),
      Row(children: [
        if (!tx)
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: ready && !c.starting ? c.start : null,
            icon: const Icon(Icons.sensors),
            label: const Text('Start transmitting'),
          )
        else
          FilledButton.icon(onPressed: c.stop, icon: const Icon(Icons.stop), label: const Text('Stop')),
        const SizedBox(width: 12),
        Expanded(
          child: Text(c.board != BoardState.datv
              ? 'Connect a board with the DATV firmware first (Device page).'
              : c.planError ?? '${c.config.freqMhz.toStringAsFixed(3)} MHz, ${c.plan!.label}'),
        ),
      ]),
      const SizedBox(height: 16),
      if (c.message != null) InfoBanner(c.message!, error: c.messageIsError),
      if (c.status != null) _StatusCard(s: c.status!, preview: c.preview, tx: tx),
      const SizedBox(height: 8),
      const Text('Only transmit on frequencies your amateur licence allows, and use an output filter: '
          'the DAC produces images next to the signal.'),
    ]);
  }
}

class _DevicePicker extends StatelessWidget {
  const _DevicePicker({required this.label, required this.devices, required this.value, required this.enabled, required this.onChanged});
  final String label;
  final List<CaptureDevice> devices;
  final CaptureDevice? value;
  final bool enabled;
  final ValueChanged<CaptureDevice> onChanged;

  @override
  Widget build(BuildContext context) {
    if (devices.isEmpty) return Text('No $label found.');
    return DropdownButtonFormField<String>(
      key: ValueKey('$label${devices.length}${value?.id}'),
      initialValue: devices.any((d) => d.id == value?.id) ? value!.id : devices.first.id,
      isExpanded: true,
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      items: [for (final d in devices) DropdownMenuItem(value: d.id, child: Text(d.name, overflow: TextOverflow.ellipsis))],
      onChanged: enabled ? (id) => onChanged(devices.firstWhere((d) => d.id == id)) : null,
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.s, required this.preview, required this.tx});
  final TxStatus s;
  final Preview? preview;
  final bool tx;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String)>[
      if (s.centreHz > 0) ('Centre', '${(s.centreHz / 1e6).toStringAsFixed(6)} MHz'),
      if (s.baud > 0) ('Symbol rate', '${s.baud.toStringAsFixed(1)} Bd'),
      if (s.capacity > 0) ('TS capacity', '${(s.capacity / 1000).toStringAsFixed(1)} kb/s'),
      ('ESP buffer', '${s.fillMin}..${s.fillMax} of ${s.target} pairs, underruns ${s.under}'),
      ('USB', '${s.kBps.toStringAsFixed(1)} kB/s, ${s.secs.toStringAsFixed(0)} s'),
      ('TS packets', '${s.muxData} data, ${s.muxNull} null${s.muxLate > 0 ? ', ${s.muxLate} late' : ''}'),
      if (s.encW > 0)
        ('Encoder', '${s.encW}x${s.encH}, ${s.encFps.toStringAsFixed(1)} fps, ${s.encKbps.toStringAsFixed(0)} kb/s, '
            'QP ${s.encQp}${s.encDropped > 0 ? ', ${s.encDropped} frames dropped' : ''}'),
      if (s.fileInfo != null) ('File', s.fileInfo!),
      if (s.startLine != null) ('ESP', s.startLine!),
      if (s.endSummary != null) ('Finished', s.endSummary!),
      if (s.error != null) ('Error', s.error!),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(builder: (context, box) {
          final info = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tx ? 'On air' : 'Last transmission', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              for (final (k, v) in rows) KeyValue(k, v),
            ],
          );
          final pv = preview == null ? null : _PreviewImage(p: preview!);
          if (pv == null) return info;
          if (box.maxWidth > 700) {
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: info),
              const SizedBox(width: 16),
              SizedBox(width: 320, child: pv),
            ]);
          }
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [pv, const SizedBox(height: 12), info]);
        }),
      ),
    );
  }
}

class _PreviewImage extends StatefulWidget {
  const _PreviewImage({required this.p});
  final Preview p;

  @override
  State<_PreviewImage> createState() => _PreviewImageState();
}

class _PreviewImageState extends State<_PreviewImage> {
  ui.Image? _img;
  Preview? _for;

  @override
  void didUpdateWidget(covariant _PreviewImage old) {
    super.didUpdateWidget(old);
    _decode();
  }

  @override
  void initState() {
    super.initState();
    _decode();
  }

  void _decode() {
    final p = widget.p;
    if (identical(p, _for)) return;
    _for = p;
    ui.decodeImageFromPixels(p.rgba, p.width, p.height, ui.PixelFormat.rgba8888, (img) {
      if (!mounted) {
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
  Widget build(BuildContext context) {
    final img = _img;
    if (img == null) return const SizedBox(height: 180);
    return AspectRatio(
      aspectRatio: img.width / img.height,
      child: RawImage(image: img, fit: BoxFit.contain),
    );
  }
}

const Map<SourceKind, String> _sourceHelp = {
  SourceKind.file: 'Sends a video file from disk, looped. A .ts file goes out unchanged at its own bit rate, '
      'so it must fit the channel. An .mp4 with H.264 video and AAC sound is sent as it is when it fits the '
      'channel, otherwise the app decodes it and re-encodes it to the size, frame rate and bit rate the '
      'channel allows.',
  SourceKind.camera: 'Sends the live picture of a camera, scaled to fit the channel, with the microphone sound '
      'if enabled below.',
  SourceKind.screen: 'Sends what is on a screen (a monitor of this computer), scaled to fit the channel, with '
      'the microphone sound if enabled below. On Linux this needs an X11 session.',
  SourceKind.testPattern: 'Sends colour bars with a moving square, a running clock and an 800 Hz tone. Handy '
      'to check the receiver and the picture quality. The text you type below appears in the middle of the '
      'picture and can be changed while on air (for example your callsign).',
  SourceKind.nullPackets: 'Sends a valid DVB signal that carries only empty (null) transport packets: no '
      'picture and no sound. Use it to lock a receiver, measure the spectrum or tune the frequency and '
      'crystal correction.',
  SourceKind.carrier: 'Sends an unmodulated carrier at the centre frequency, without any DVB coding. Use it '
      'to measure the frequency error of the board (crystal ppm) or the output power.',
};

/// The text for the test pattern; changes are sent to the encoder while typing.
class _PatternTextField extends StatefulWidget {
  const _PatternTextField({required this.c});
  final AppController c;

  @override
  State<_PatternTextField> createState() => _PatternTextFieldState();
}

class _PatternTextFieldState extends State<_PatternTextField> {
  late final TextEditingController _t = TextEditingController(text: widget.c.patternText);

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _t,
        minLines: 1,
        maxLines: 3,
        maxLength: 120,
        decoration: const InputDecoration(
          labelText: 'Text in the middle of the picture',
          hintText: 'e.g. your callsign',
          border: OutlineInputBorder(),
        ),
        onChanged: widget.c.setPatternText,
      );
}
