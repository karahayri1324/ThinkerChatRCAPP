import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// Result of probing the server to see whether the stored token is still valid.
enum SessionValidity { valid, invalid, unreachable }

class AuthService extends ChangeNotifier {
  static const _tokenKey = 'access_token';
  static const _usernameKey = 'username';
  static const _serverUrlKey = 'server_url';

  static const _httpTimeout = Duration(seconds: 12);
  static const _loginTimeout = Duration(seconds: 20);

  /// Hardened storage. On Android, EncryptedSharedPreferences avoids the legacy
  /// keystore-wrapped path that intermittently fails to decrypt (returning null
  /// and silently logging the user out). On iOS, first_unlock lets the token be
  /// read when the app starts right after a reboot, before first unlock events
  /// settle.
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  /// Pre-1.1.0 storage location (default options), read once for migration so
  /// existing logins survive the storage hardening.
  final FlutterSecureStorage _legacyStorage = const FlutterSecureStorage();

  String? _token;
  String? _username;
  String? _serverUrl;
  String? _pendingToken;
  bool _isLoggedIn = false;
  bool _migratedFromLegacy = false;
  bool _authRejectionHandled = false;

  /// One-shot message for the login screen ("Session expired..."), set when the
  /// server rejects the stored token.
  String? _sessionNotice;

  /// Invoked (at most once per session) when the server rejects our token, so
  /// the app root can drop the WS and return to the login screen.
  void Function()? onSessionExpired;

  String? get token => _token;
  String? get username => _username;
  String? get serverUrl => _serverUrl;
  bool get isLoggedIn => _isLoggedIn;

  /// Token expiry when the token is a JWT with an `exp` claim, else null.
  DateTime? get tokenExpiry => _token == null ? null : decodeJwtExpiry(_token!);

  /// Device clocks drift. Only treat a JWT as locally expired once it is past
  /// due by more than this, so a fast phone clock can't throw away a token the
  /// server would still have accepted.
  static const _clockSkewAllowance = Duration(minutes: 10);

  /// Logged in AND (token is opaque, or its JWT expiry is still in the future
  /// allowing for clock skew).
  bool get hasValidSession {
    if (!_isLoggedIn || _token == null) return false;
    final exp = tokenExpiry;
    return exp == null ||
        exp.isAfter(DateTime.now().subtract(_clockSkewAllowance));
  }

  String? consumeSessionNotice() {
    final msg = _sessionNotice;
    _sessionNotice = null;
    return msg;
  }

  /// Load the persisted session. Never throws: a flaky secure-storage read must
  /// degrade to "not logged in", not a stuck splash screen.
  Future<void> init() async {
    try {
      _token = await _readRobust(_tokenKey);
      _username = await _readRobust(_usernameKey);
      _serverUrl = await _readRobust(_serverUrlKey);
      _isLoggedIn = _token != null;
      if (_migratedFromLegacy && _token != null) {
        // Re-persist under the hardened options and clear the legacy copies.
        await _persistSession(deleteLegacy: true);
      }
    } catch (e) {
      debugPrint('Auth init error: $e');
      _isLoggedIn = _token != null;
    }
    _authRejectionHandled = false;
    notifyListeners();
  }

  /// Read a key with retries (secure storage can transiently throw or return
  /// null right after boot / under keystore contention), falling back to the
  /// legacy storage location for values written by older app versions.
  Future<String?> _readRobust(String key) async {
    var definitivelyAbsent = false;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final value = await _storage.read(key: key);
        if (value != null) return value;
        definitivelyAbsent = true;
        break;
      } catch (e) {
        debugPrint('Secure storage read "$key" attempt ${attempt + 1}: $e');
        await Future.delayed(Duration(milliseconds: 100 * (attempt + 1)));
      }
    }
    // Only consult the legacy store when the hardened one answered "no such
    // key". If it merely kept throwing, a stale legacy value could otherwise
    // overwrite a perfectly good hardened token during migration.
    if (!definitivelyAbsent) return null;
    try {
      final legacy = await _legacyStorage.read(key: key);
      if (legacy != null) {
        _migratedFromLegacy = true;
        return legacy;
      }
    } catch (e) {
      debugPrint('Legacy storage read "$key": $e');
    }
    return null;
  }

  Future<void> _writeRobust(String key, String value) async {
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await _storage.write(key: key, value: value);
        return;
      } catch (e) {
        lastError = e;
        await Future.delayed(const Duration(milliseconds: 150));
      }
    }
    debugPrint('Secure storage write "$key" failed: $lastError');
  }

  Future<void> _persistSession({bool deleteLegacy = false}) async {
    if (_token != null) await _writeRobust(_tokenKey, _token!);
    if (_username != null) await _writeRobust(_usernameKey, _username!);
    if (_serverUrl != null) await _writeRobust(_serverUrlKey, _serverUrl!);
    if (deleteLegacy) {
      for (final key in const [_tokenKey, _usernameKey, _serverUrlKey]) {
        try {
          await _legacyStorage.delete(key: key);
        } catch (_) {}
      }
      _migratedFromLegacy = false;
    }
  }

  /// Normalize a server URL (trim, strip trailing slashes, default to https).
  /// Throws [FormatException] with a user-friendly message on invalid input.
  static String normalizeServerUrl(String url) {
    url = url.trim();
    if (url.isEmpty) {
      throw const FormatException('Please enter a server URL');
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    // Strip trailing slashes from the authority/path only — doing it before the
    // scheme check would turn a bare "http://" into "https://http:".
    final scheme = url.startsWith('https://') ? 'https://' : 'http://';
    var rest = url.substring(scheme.length);
    while (rest.endsWith('/')) {
      rest = rest.substring(0, rest.length - 1);
    }
    final normalized = '$scheme$rest';
    final uri = Uri.tryParse(normalized);
    if (uri == null || uri.host.isEmpty || uri.host.contains(' ')) {
      throw const FormatException('Invalid server URL');
    }
    return normalized;
  }

  /// Build the WS endpoint from a normalized server URL, preserving any path
  /// prefix (e.g. a relay behind https://host/relay must yield
  /// wss://host/relay/ws/client, not wss://host/ws/client).
  static String buildWsUrl(String serverUrl, String? token) {
    final uri = Uri.parse(serverUrl);
    final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
    var path = uri.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return '$scheme://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}'
        '$path/ws/client?token=${Uri.encodeComponent(token ?? '')}';
  }

  /// Decode the `exp` claim of a JWT. Returns null for opaque/malformed tokens
  /// (which are then treated as non-expiring).
  static DateTime? decodeJwtExpiry(String token) {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    try {
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      ) as Map<String, dynamic>;
      final exp = payload['exp'];
      if (exp is! num) return null;
      return DateTime.fromMillisecondsSinceEpoch((exp * 1000).toInt());
    } catch (_) {
      return null;
    }
  }

  Future<void> setServerUrl(String url) async {
    _serverUrl = normalizeServerUrl(url);
    await _writeRobust(_serverUrlKey, _serverUrl!);
    notifyListeners();
  }

  String get _baseUrl => _serverUrl ?? '';

  String get wsUrl {
    if (_serverUrl == null) return '';
    return buildWsUrl(_serverUrl!, _token);
  }

  Future<Map<String, dynamic>> login(String username, String password) async {
    final http.Response resp;
    try {
      resp = await http
          .post(
            Uri.parse('$_baseUrl/api/login'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'username': username, 'password': password}),
          )
          .timeout(_loginTimeout);
    } on TimeoutException {
      return {'success': false, 'error': 'Server did not respond'};
    } catch (_) {
      return {'success': false, 'error': 'Connection error'};
    }
    final Map<String, dynamic> data;
    try {
      data = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      return {'success': false, 'error': 'Invalid server response'};
    }

    if (resp.statusCode != 200) {
      return {'success': false, 'error': data['error'] ?? 'Login failed'};
    }

    if (data['requires_2fa'] == true) {
      _pendingToken = data['pending_token'] as String?;
      return {'success': true, 'requires_2fa': true};
    }

    if (data['access_token'] is! String) {
      return {'success': false, 'error': 'Invalid server response'};
    }
    await _saveSession(
        data['access_token'] as String, data['username'] as String? ?? username);
    return {'success': true, 'requires_2fa': false};
  }

  Future<Map<String, dynamic>> verify2FA(String code) async {
    final http.Response resp;
    try {
      resp = await http
          .post(
            Uri.parse('$_baseUrl/api/login/2fa'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'pending_token': _pendingToken, 'code': code}),
          )
          .timeout(_loginTimeout);
    } on TimeoutException {
      return {'success': false, 'error': 'Server did not respond'};
    } catch (_) {
      return {'success': false, 'error': 'Connection error'};
    }
    final Map<String, dynamic> data;
    try {
      data = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      return {'success': false, 'error': 'Invalid server response'};
    }

    if (resp.statusCode != 200) {
      return {'success': false, 'error': data['error'] ?? 'Verification failed'};
    }

    if (data['access_token'] is! String) {
      return {'success': false, 'error': 'Invalid server response'};
    }
    await _saveSession(data['access_token'] as String,
        data['username'] as String? ?? _username ?? '');
    return {'success': true};
  }

  Future<void> _saveSession(String token, String username) async {
    _token = token;
    _username = username;
    _isLoggedIn = true;
    _sessionNotice = null;
    _authRejectionHandled = false;
    await _persistSession(deleteLegacy: true);
    notifyListeners();
  }

  /// The server told us our token is no longer valid (401, or repeated WS
  /// rejections). Clear the token but keep server URL + username so the user
  /// only has to re-enter the password.
  ///
  /// [expectedToken] guards against a slow verdict landing after the user has
  /// already signed in again: if the current token is no longer the one the
  /// caller was judging, the verdict is stale and must be ignored.
  Future<void> markSessionExpired(
      {String notice = 'Your session has expired. Please log in again.',
      String? expectedToken}) async {
    if (expectedToken != null && expectedToken != _token) return;
    if (_authRejectionHandled) return;
    _authRejectionHandled = true;
    _token = null;
    _pendingToken = null;
    _isLoggedIn = false;
    _sessionNotice = notice;
    try {
      await _storage.delete(key: _tokenKey);
      await _legacyStorage.delete(key: _tokenKey);
    } catch (_) {}
    notifyListeners();
    onSessionExpired?.call();
  }

  /// Explicit user-initiated sign-out: unlike [markSessionExpired] this also
  /// forgets who was signed in.
  Future<void> logout() async {
    _token = null;
    _username = null;
    _pendingToken = null;
    _isLoggedIn = false;
    _sessionNotice = null;
    _authRejectionHandled = false;
    try {
      await _storage.delete(key: _tokenKey);
      await _storage.delete(key: _usernameKey);
      await _legacyStorage.delete(key: _tokenKey);
      await _legacyStorage.delete(key: _usernameKey);
    } catch (_) {}
    notifyListeners();
  }

  /// Probe whether the stored token is still accepted by the server. Used when
  /// the WS keeps being rejected: distinguishes "token dead" (-> re-login) from
  /// "server down" (-> keep retrying quietly).
  Future<SessionValidity> validateSession() async {
    if (_token == null || _serverUrl == null) return SessionValidity.invalid;
    try {
      final resp = await http
          .get(Uri.parse('$_baseUrl/api/2fa/status'), headers: authHeaders)
          .timeout(_httpTimeout);
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        return SessionValidity.invalid;
      }
      if (resp.statusCode == 200) return SessionValidity.valid;
      return SessionValidity.unreachable;
    } catch (_) {
      return SessionValidity.unreachable;
    }
  }

  Map<String, String> get authHeaders => {
        'Content-Type': 'application/json',
        if (_token != null) 'Authorization': 'Bearer $_token',
      };

  /// [expireOn401] must be false for endpoints that take the user's password:
  /// servers commonly answer 401 for "wrong current password", and treating
  /// that as session expiry would throw away a perfectly valid token.
  Future<Map<String, dynamic>> _safePost(
      String endpoint, Map<String, dynamic> body,
      {bool expireOn401 = true}) async {
    final tokenAtRequest = _token;
    try {
      final resp = await http
          .post(
            Uri.parse('$_baseUrl$endpoint'),
            headers: authHeaders,
            body: jsonEncode(body),
          )
          .timeout(_httpTimeout);
      if (resp.statusCode == 401 && expireOn401) {
        markSessionExpired(expectedToken: tokenAtRequest);
        return {'success': false, 'error': 'Session expired'};
      }
      try {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        if (resp.statusCode != 200) {
          return {'success': false, 'error': data['error'] ?? 'Request failed'};
        }
        return {...data, 'success': true};
      } catch (_) {
        return {'success': false, 'error': 'Invalid server response'};
      }
    } on TimeoutException {
      return {'success': false, 'error': 'Server did not respond'};
    } catch (e) {
      return {'success': false, 'error': 'Connection error'};
    }
  }

  Future<Map<String, dynamic>> _safeGet(String endpoint) async {
    final tokenAtRequest = _token;
    try {
      final resp = await http
          .get(Uri.parse('$_baseUrl$endpoint'), headers: authHeaders)
          .timeout(_httpTimeout);
      if (resp.statusCode == 401) {
        markSessionExpired(expectedToken: tokenAtRequest);
        return {'error': 'Session expired'};
      }
      try {
        return jsonDecode(resp.body) as Map<String, dynamic>;
      } catch (_) {
        return {'error': 'Invalid server response'};
      }
    } on TimeoutException {
      return {'error': 'Server did not respond'};
    } catch (e) {
      return {'error': 'Connection error'};
    }
  }

  Future<Map<String, dynamic>> changePassword(String oldPw, String newPw) async {
    return _safePost('/api/change-password',
        {'old_password': oldPw, 'new_password': newPw},
        expireOn401: false);
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
    return _safePost('/api/2fa/disable', {'password': password},
        expireOn401: false);
  }
}
