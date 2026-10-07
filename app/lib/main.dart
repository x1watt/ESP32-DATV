import 'package:flutter/material.dart';

import 'ui/app_controller.dart';
import 'ui/device_page.dart';
import 'ui/settings_page.dart';
import 'ui/transmit_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final c = AppController();
  c.init();
  runApp(DatvApp(c: c));
}

class DatvApp extends StatelessWidget {
  const DatvApp({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'ESP32-DATV',
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        darkTheme: ThemeData(colorSchemeSeed: Colors.indigo, brightness: Brightness.dark, useMaterial3: true),
        home: Home(c: c),
      );
}

class Home extends StatefulWidget {
  const Home({super.key, required this.c});
  final AppController c;

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int _tab = 0;

  @override
  void dispose() {
    widget.c.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.c,
        builder: (context, _) {
          final c = widget.c;
          final pages = [DevicePage(c: c), SettingsPage(c: c), TransmitPage(c: c)];
          const dests = [
            (Icons.usb, 'Device'),
            (Icons.tune, 'Settings'),
            (Icons.sensors, 'Transmit'),
          ];
          final wide = MediaQuery.sizeOf(context).width >= 720;
          final title = Row(children: [
            const Text('ESP32-DATV'),
            const Spacer(),
            if (c.transmitting)
              Chip(
                avatar: const Icon(Icons.sensors, color: Colors.white, size: 18),
                label: const Text('ON AIR', style: TextStyle(color: Colors.white)),
                backgroundColor: Colors.red.shade700,
              ),
          ]);
          final body = SafeArea(
            child: Center(
              child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1000), child: pages[_tab]),
            ),
          );
          if (wide) {
            return Scaffold(
              appBar: AppBar(title: title),
              body: Row(children: [
                NavigationRail(
                  selectedIndex: _tab,
                  labelType: NavigationRailLabelType.all,
                  onDestinationSelected: (i) => setState(() => _tab = i),
                  destinations: [for (final (i, l) in dests) NavigationRailDestination(icon: Icon(i), label: Text(l))],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ]),
            );
          }
          return Scaffold(
            appBar: AppBar(title: title),
            body: body,
            bottomNavigationBar: NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (i) => setState(() => _tab = i),
              destinations: [for (final (i, l) in dests) NavigationDestination(icon: Icon(i), label: l)],
            ),
          );
        },
      );
}
