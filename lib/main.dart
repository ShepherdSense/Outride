import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'screens/picture_screen.dart';
import 'screens/sensors_screen.dart';
import 'screens/settings.dart';
import 'services/experimental_sensors.dart';
import 'state/app_state.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Drone tab video (media_kit/libmpv). Required before any Player
  // is constructed; a no-op cost when the tab is never opened.
  MediaKit.ensureInitialized();
  // Experimental-sensors list filter (Settings switch): load the
  // persisted choice before the first frame so the Sensors list
  // starts in the right state, never flashing in.
  unawaited(experimentalSensors.load());
  runApp(const OutrideApp());
}

/// Outride — dark-mode-only companion app for a Silvus StreamCaster
/// mesh-radio tripwire.
class OutrideApp extends StatefulWidget {
  const OutrideApp({super.key});

  @override
  State<OutrideApp> createState() => _OutrideAppState();
}

class _OutrideAppState extends State<OutrideApp> {
  final AppState _state = AppState();
  int _tab = 0;

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = buildDarkTheme();
    return MaterialApp(
      title: 'Outride',
      theme: theme,
      darkTheme: theme,
      // Dark mode first, always: there is no light theme by design.
      themeMode: ThemeMode.dark,
      home: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('OUTRIDE',
                  style: OutrideType.section(16).copyWith(
                    color: OutrideColors.onDark,
                    letterSpacing: 5,
                    fontWeight: FontWeight.w700,
                  )),
              Text('RF MESH SENSING OBSERVATORY',
                  style: OutrideType.section(9)),
            ],
          ),
        ),
        // Three destinations, not eight: one watch view (Picture),
        // one instrument list (Sensors), and Settings. Every old tab
        // still exists — the instruments live one tap away under
        // Sensors, opened unchanged. Fleet join is an action, not a
        // destination: Picture fleet chip + Settings Fleet section.
        body: _tab == 0
            ? PictureScreen(state: _state)
            : _tab == 1
                ? SensorsScreen(state: _state)
                : SettingsScreen(state: _state),
        bottomNavigationBar: BottomNavigationBar(
          // Three destinations: fixed type keeps every label visible
          // (the shifting default would hide unselected labels).
          type: BottomNavigationBarType.fixed,
          currentIndex: _tab,
          onTap: (i) => setState(() => _tab = i),
          items: const [
            BottomNavigationBarItem(
                icon: Icon(Icons.radar), label: 'Picture'),
            BottomNavigationBarItem(
                icon: Icon(Icons.tune), label: 'Sensors'),
            BottomNavigationBarItem(
                icon: Icon(Icons.settings), label: 'Settings'),
          ],
        ),
      ),
    );
  }
}
