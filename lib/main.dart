import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'screens/picture_screen.dart';
import 'screens/sensors_screen.dart';
import 'screens/settings.dart';
import 'services/experimental_build.dart';
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
          // Mock top bar: OUTRIDE wordmark (RIDE in purple) + a
          // SIMULATED / LIVE pill. No subtitle — the mock has none.
          title: ListenableBuilder(
            listenable: _state,
            builder: (context, _) {
              final simulated = _state.settings.simulatedMode;
              return Row(
                children: [
                  RichText(
                    text: TextSpan(
                      style: OutrideType.section(20).copyWith(
                        color: OutrideColors.onDark,
                        letterSpacing: 1,
                        fontWeight: FontWeight.w800,
                      ),
                      children: const [
                        TextSpan(text: 'OUT'),
                        TextSpan(
                          text: 'RIDE',
                          style: TextStyle(color: OutrideColors.purple),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  // EXPERIMENTAL build pill (branch-only, build-time
                  // constant — never toggleable off). It answers "is
                  // this the experimental build?"; the SIMULATED/LIVE
                  // pill beside it answers "is sensing simulated?".
                  // The two must never be merged into one. The pill
                  // cluster scales down as a unit on narrow phones
                  // (the two pills plus the wordmark overflowed a
                  // 360 px bar by 81 px) instead of overflowing.
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (kIsExperimentalBuild) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 7),
                              decoration: BoxDecoration(
                                color:
                                    OutrideColors.amber.withAlpha(38),
                                border: Border.all(
                                    color: OutrideColors.amber
                                        .withAlpha(128)),
                                borderRadius:
                                    BorderRadius.circular(999),
                              ),
                              child: const Text(
                                'EXPERIMENTAL',
                                style: TextStyle(
                                  color: OutrideColors.amber,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1.5,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 7),
                            decoration: BoxDecoration(
                              color: OutrideColors.purpleDeep,
                              border: Border.all(
                                  color: OutrideColors.purpleStrong),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              simulated ? 'SIMULATED' : 'LIVE',
                              style: const TextStyle(
                                color: Color(0xFFE9D5FF),
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 2,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
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
