import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class TerminalHistoryService {
  static const _historyKey = 'terminal_history';
  static const _maxShells = 10;
  static const _maxLinesPerShell = 500;

  /// Save terminal output for a shell
  static Future<void> saveOutput(String shellId, String data) async {
    final prefs = await SharedPreferences.getInstance();
    final history = _loadMap(prefs);

    final existing = history[shellId] ?? '';
    // Append new data, cap total lines
    final combined = existing + data;
    final lines = combined.split('\n');
    final trimmed = lines.length > _maxLinesPerShell
        ? lines.sublist(lines.length - _maxLinesPerShell).join('\n')
        : combined;
    history[shellId] = trimmed;

    // Cap total shells stored
    if (history.length > _maxShells) {
      final oldestKeys = history.keys.toList()
        ..sort()
        ..removeRange(_maxShells, history.length);
      history.removeWhere((k, _) => !oldestKeys.contains(k));
    }

    await prefs.setString(_historyKey, jsonEncode(history));
  }

  /// Get saved terminal history for a shell
  static Future<String?> getOutput(String shellId) async {
    final prefs = await SharedPreferences.getInstance();
    final history = _loadMap(prefs);
    return history[shellId];
  }

  /// Get all saved shell IDs
  static Future<List<String>> getSavedShellIds() async {
    final prefs = await SharedPreferences.getInstance();
    final history = _loadMap(prefs);
    return history.keys.toList()..sort();
  }

  /// Clear history for a shell
  static Future<void> clearShell(String shellId) async {
    final prefs = await SharedPreferences.getInstance();
    final history = _loadMap(prefs);
    history.remove(shellId);
    await prefs.setString(_historyKey, jsonEncode(history));
  }

  /// Clear all history
  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_historyKey);
  }

  static Map<String, String> _loadMap(SharedPreferences prefs) {
    final raw = prefs.getString(_historyKey);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      return {};
    }
  }
}
