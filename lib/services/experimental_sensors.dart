import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whether sensors still in testing (Fetch, Spectrum) are shown in the
/// Sensors list. Defaults OFF — experimental instruments stay hidden
/// until the operator opts in from Settings. Persisted in
/// SharedPreferences so the choice survives restarts.
///
/// Lives outside AppState on purpose: the setting is UI-only and must
/// never touch detection, sensing, fleet, or mesh state. The Settings
/// switch and the Sensors list both listen to this one object.
class ExperimentalSensors extends ChangeNotifier {
  static const String _prefsKey = 'outride_experimental_sensors_v1';

  bool _shown = false;
  bool _loaded = false;

  /// True once the persisted value has been read (or defaulted).
  bool get loaded => _loaded;

  /// Whether experimental sensors are shown. False until [load]
  /// completes — the list starts hidden, never flashing in.
  bool get shown => _shown;

  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _shown = prefs.getBool(_prefsKey) ?? false;
    } catch (_) {
      // A storage failure is not fatal: the default (hidden) stands
      // for this session and the list still works.
      _shown = false;
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> set(bool value) async {
    if (_shown == value) return;
    _shown = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKey, value);
    } catch (_) {
      // Preference loss is not fatal: the in-memory value still
      // drives this session's list.
    }
  }
}

/// App-wide instance. Loaded once from main() before runApp.
final experimentalSensors = ExperimentalSensors();
