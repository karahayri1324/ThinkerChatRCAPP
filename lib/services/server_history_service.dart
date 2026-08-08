import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class ServerProfile {
  final String url;
  final String username;
  final DateTime lastUsed;

  const ServerProfile({
    required this.url,
    required this.username,
    required this.lastUsed,
  });

  Map<String, dynamic> toJson() => {
        'url': url,
        'username': username,
        'last_used': lastUsed.toIso8601String(),
      };

  static ServerProfile? fromJson(Map<String, dynamic> json) {
    final url = json['url'];
    if (url is! String || url.isEmpty) return null;
    return ServerProfile(
      url: url,
      username: json['username'] as String? ?? '',
      lastUsed:
          DateTime.tryParse(json['last_used'] as String? ?? '') ?? DateTime(2000),
    );
  }
}

/// Remembers recently used relay servers (URL + username, never passwords) so
/// the login screen can offer one-tap selection between saved servers.
class ServerHistoryService {
  static const _key = 'server_profiles';
  static const _maxProfiles = 8;

  static Future<List<ServerProfile>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final profiles = list
          .whereType<Map<String, dynamic>>()
          .map(ServerProfile.fromJson)
          .whereType<ServerProfile>()
          .toList();
      profiles.sort((a, b) => b.lastUsed.compareTo(a.lastUsed));
      return profiles;
    } catch (_) {
      return [];
    }
  }

  /// Record a successful login against a server (upserts by URL).
  static Future<void> record(String url, String username) async {
    final profiles = await load();
    profiles.removeWhere((p) => p.url == url);
    profiles.insert(
      0,
      ServerProfile(url: url, username: username, lastUsed: DateTime.now()),
    );
    if (profiles.length > _maxProfiles) {
      profiles.removeRange(_maxProfiles, profiles.length);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode([for (final p in profiles) p.toJson()]));
  }

  static Future<void> remove(String url) async {
    final profiles = await load()
      ..removeWhere((p) => p.url == url);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode([for (final p in profiles) p.toJson()]));
  }
}
