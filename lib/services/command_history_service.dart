import 'package:shared_preferences/shared_preferences.dart';

/// Persistent history of commands sent from the terminal input bar,
/// navigable with the up/down arrows next to the field.
class CommandHistoryService {
  static const _key = 'command_history';
  static const _maxEntries = 50;

  final List<String> _entries = [];
  int _cursor = -1; // -1 = not navigating (below the newest entry)

  List<String> get entries => List.unmodifiable(_entries);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _entries
      ..clear()
      ..addAll(prefs.getStringList(_key) ?? const []);
    _cursor = -1;
  }

  /// Record a submitted command (most recent last). Consecutive duplicates and
  /// blank commands are skipped. Resets navigation.
  Future<void> add(String command) async {
    final cmd = command.trim();
    _cursor = -1;
    if (cmd.isEmpty) return;
    if (_entries.isNotEmpty && _entries.last == cmd) return;
    _entries.remove(cmd); // re-adding moves it to the newest slot
    _entries.add(cmd);
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, _entries);
  }

  /// Step back in history (older). Returns null when there is nothing older.
  String? previous() {
    if (_entries.isEmpty) return null;
    if (_cursor == -1) {
      _cursor = _entries.length - 1;
    } else if (_cursor > 0) {
      _cursor--;
    }
    return _entries[_cursor];
  }

  /// Step forward in history (newer). Returns '' once past the newest entry
  /// (caller should clear the input), or null when not navigating.
  String? next() {
    if (_cursor == -1) return null;
    if (_cursor < _entries.length - 1) {
      _cursor++;
      return _entries[_cursor];
    }
    _cursor = -1;
    return '';
  }

  void resetCursor() => _cursor = -1;

  Future<void> clear() async {
    _entries.clear();
    _cursor = -1;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
