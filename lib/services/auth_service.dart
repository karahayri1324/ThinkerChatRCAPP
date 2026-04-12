import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

class AuthService extends ChangeNotifier {
  static const _tokenKey = 'access_token';
  static const _usernameKey = 'username';
  static const _serverUrlKey = 'server_url';

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  String? _token;
  String? _username;
  String? _serverUrl;
  String? _pendingToken;
  bool _isLoggedIn = false;

  String? get token => _token;
  String? get username => _username;
  String? get serverUrl => _serverUrl;
  bool get isLoggedIn => _isLoggedIn;

  Future<void> init() async {
    _token = await _storage.read(key: _tokenKey);
    _username = await _storage.read(key: _usernameKey);
    _serverUrl = await _storage.read(key: _serverUrlKey);
    _isLoggedIn = _token != null;
    notifyListeners();
  }

  Future<void> setServerUrl(String url) async {
    // Normalize URL
    url = url.trim();
    if (url.endsWith('/')) url = url.substring(0, url.length - 1);
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    _serverUrl = url;
    await _storage.write(key: _serverUrlKey, value: url);
    notifyListeners();
  }

  String get _baseUrl => _serverUrl ?? '';

  String get wsUrl {
    if (_serverUrl == null) return '';
    final uri = Uri.parse(_serverUrl!);
    final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
    return '$scheme://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}/ws/client?token=${Uri.encodeComponent(_token ?? '')}';
  }

  Future<Map<String, dynamic>> login(String username, String password) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/api/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'username': username, 'password': password}),
    );
    final data = jsonDecode(resp.body) as Map<String, dynamic>;

    if (resp.statusCode != 200) {
      return {'success': false, 'error': data['error'] ?? 'Login failed'};
    }

    if (data['requires_2fa'] == true) {
      _pendingToken = data['pending_token'] as String?;
      return {'success': true, 'requires_2fa': true};
    }

    await _saveSession(data['access_token'] as String, data['username'] as String);
    return {'success': true, 'requires_2fa': false};
  }

  Future<Map<String, dynamic>> verify2FA(String code) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/api/login/2fa'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'pending_token': _pendingToken, 'code': code}),
    );
    final data = jsonDecode(resp.body) as Map<String, dynamic>;

    if (resp.statusCode != 200) {
      return {'success': false, 'error': data['error'] ?? 'Verification failed'};
    }

    await _saveSession(data['access_token'] as String, data['username'] as String);
    return {'success': true};
  }

  Future<void> _saveSession(String token, String username) async {
    _token = token;
    _username = username;
    _isLoggedIn = true;
    await _storage.write(key: _tokenKey, value: token);
    await _storage.write(key: _usernameKey, value: username);
    notifyListeners();
  }

  Future<void> logout() async {
    _token = null;
    _username = null;
    _pendingToken = null;
    _isLoggedIn = false;
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _usernameKey);
    notifyListeners();
  }

  Map<String, String> get authHeaders => {
        'Content-Type': 'application/json',
        if (_token != null) 'Authorization': 'Bearer $_token',
      };

  Future<Map<String, dynamic>> _safePost(String endpoint, Map<String, dynamic> body) async {
    try {
      final resp = await http.post(
        Uri.parse('$_baseUrl$endpoint'),
        headers: authHeaders,
        body: jsonEncode(body),
      );
      try {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        if (resp.statusCode != 200) {
          return {'success': false, 'error': data['error'] ?? 'Request failed'};
        }
        return {...data, 'success': true};
      } catch (_) {
        return {'success': false, 'error': 'Invalid server response'};
      }
    } catch (e) {
      return {'success': false, 'error': 'Connection error'};
    }
  }

  Future<Map<String, dynamic>> _safeGet(String endpoint) async {
    try {
      final resp = await http.get(
        Uri.parse('$_baseUrl$endpoint'),
        headers: authHeaders,
      );
      try {
        return jsonDecode(resp.body) as Map<String, dynamic>;
      } catch (_) {
        return {'error': 'Invalid server response'};
      }
    } catch (e) {
      return {'error': 'Connection error'};
    }
  }

  Future<Map<String, dynamic>> changePassword(String oldPw, String newPw) async {
    return _safePost('/api/change-password', {'old_password': oldPw, 'new_password': newPw});
  }

  Future<Map<String, dynamic>> get2FAStatus() async {
    return _safeGet('/api/2fa/status');
  }

  Future<Map<String, dynamic>> setup2FA() async {
    return _safePost('/api/2fa/setup', {});
  }

  Future<Map<String, dynamic>> enable2FA(String code) async {
    return _safePost('/api/2fa/enable', {'code': code});
  }

  Future<Map<String, dynamic>> disable2FA(String password) async {
    return _safePost('/api/2fa/disable', {'password': password});
  }
}
