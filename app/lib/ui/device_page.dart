import 'package:flutter/material.dart';

import '../core/esp/transport.dart';
import 'app_controller.dart';
import 'widgets.dart';

class DevicePage extends StatelessWidget {
  const DevicePage({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    final busy = c.board == BoardState.connecting || c.board == BoardState.flashing || c.transmitting;
    final connected = c.session != null;
    final fw = c.firmware;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Section(title: 'Board', children: [
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              key: ValueKey('${c.ports.length}${c.selectedPort?.id}'),
              initialValue: c.selectedPort?.id,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'USB port', border: OutlineInputBorder()),
              items: [
                for (final p in c.ports)
                  DropdownMenuItem(value: p.id, child: Text(_portLabel(p), overflow: TextOverflow.ellipsis)),
              ],
              onChanged: busy || connected ? null : (id) => c.selectPort(c.ports.firstWhere((p) => p.id == id)),
            ),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: busy || connected ? null : c.refreshPorts,
            icon: const Icon(Icons.refresh),
          ),
        ]),
        if (c.ports.isEmpty) const Text('No serial port found. Connect the ESP32-C3 with a USB-C data cable.'),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (!connected)
            FilledButton.icon(
              onPressed: busy || c.selectedPort == null ? null : c.connect,
              icon: const Icon(Icons.usb),
              label: const Text('Connect and check'),
            )
          else ...[
            OutlinedButton.icon(
              onPressed: busy ? null : c.disconnect,
              icon: const Icon(Icons.usb_off),
              label: const Text('Disconnect'),
            ),
            if (c.board == BoardState.noAnswer)
              OutlinedButton.icon(
                onPressed: busy ? null : c.identifyChip,
                icon: const Icon(Icons.memory),
                label: const Text('Identify chip (restarts the board)'),
              ),
          ],
        ]),
        _BoardStatus(c: c),
      ]),
      Section(title: 'Firmware', children: [
        Text(fw == null ? 'No firmware bundled.' : 'Bundled DATV firmware ${fw.describe}'),
        if (c.flashProgress != null) ...[
          LinearProgressIndicator(value: c.flashProgress),
          Text('${c.flashStage ?? ''} ${(100 * (c.flashProgress ?? 0)).toStringAsFixed(0)} %'),
        ],
        Wrap(spacing: 8, children: [
          FilledButton.tonalIcon(
            onPressed: !connected || busy || fw == null ? null : () => _confirmFlash(context),
            icon: const Icon(Icons.system_update_alt),
            label: Text(c.board == BoardState.datv ? 'Reinstall firmware' : 'Install firmware'),
          ),
        ]),
        const Text('Flashing uses the ESP32-C3 ROM bootloader over the same USB cable. If it does not answer, '
            'hold BOOT, tap RESET (or replug), release BOOT and try again.'),
      ]),
      if (c.message != null) InfoBanner(c.message!, error: c.messageIsError),
    ]);
  }

  static String _portLabel(PortInfo p) {
    final what = p.isEspressif ? 'Espressif USB JTAG/serial' : (p.product ?? 'serial port');
    return '${p.name}  ($what${p.serial != null ? ', ${p.serial}' : ''})';
  }

  Future<void> _confirmFlash(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Install the DATV firmware?'),
        content: Text('This overwrites the program on the board connected to ${c.selectedPort?.name}. '
            'Make sure this is the ESP32-C3 you want to use as the transmitter.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Install')),
        ],
      ),
    );
    if (ok == true) await c.flash();
  }
}

class _BoardStatus extends StatelessWidget {
  const _BoardStatus({required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (IconData icon, Color color, String text) = switch (c.board) {
      BoardState.disconnected => (Icons.circle_outlined, cs.outline, 'Not connected'),
      BoardState.connecting => (Icons.hourglass_top, cs.primary, 'Checking the board...'),
      BoardState.flashing => (Icons.system_update_alt, cs.primary, 'Installing the firmware...'),
      BoardState.datv => (Icons.check_circle, Colors.green, 'Valid DATV firmware: ${c.boardLine ?? ''}'),
      BoardState.noAnswer => (Icons.help_outline, Colors.orange, 'No answer from the DATV firmware. If this is your '
          'ESP32-C3, install the firmware below; "Identify chip" checks the chip type first.'),
      BoardState.bareC3 => (Icons.warning_amber, Colors.orange, 'ESP32-C3 found, but without the DATV firmware. Install it below.'),
      BoardState.unknown => (Icons.help_outline, cs.error, 'No answer from the DATV firmware or the ESP32-C3 bootloader. '
          'This may not be an ESP32-C3, or it needs a reset.'),
    };
    return Row(children: [
      Icon(icon, color: color),
      const SizedBox(width: 8),
      Expanded(child: Text(text)),
    ]);
  }
}
