import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class WsService extends ChangeNotifier {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  final Map<String, List<void Function(Map<String, dynamic>)>> _handlers = {};

  bool _connected = false;
  bool _shouldReconnect = true;
  int _reconnectDelay = 1000;
  static const _maxReconnectDelay = 30000;
  static const _heartbeatInterval = Duration(seconds: 20);
  static const _staleThreshold = Duration(seconds: 50);
  // A handshake that neither completes nor errors (common when a mobile network
  // switch black-holes the old route) would otherwise hang for the OS timeout
  // with no recovery logic armed at all.
  static const _connectTimeout = Duration(seconds: 15);
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  Timer? _watchdogTimer;
  Timer? _connectTimer;
  Timer? _resumeProbeTimer;
  static const _resumeProbeTimeout = Duration(seconds: 8);
  DateTime? _lastMessageAt;
  String? _url;

  // Auth-rejection heuristic: a token the server refuses produces connections
  // that die before a single message arrives. After a few in a row, we ask the
  // owner (HomeScreen) to probe the REST API and distinguish "token dead"
  // from "server down".
  int _rejectedStreak = 0;
  bool _gotMessageThisAttempt = false;
  bool _rejectionProbeFired = false;
  static const _rejectionStreakThreshold = 3;

  /// Fired (once per streak) after several consecutive connections closed
  /// without receiving any message. Call [resetRejectionProbe] to allow it to
  /// fire again after another streak.
  void Function()? onRepeatedRejections;

  /// Consecutive reconnect attempts since the last successful message,
  /// surfaced in the connection banner.
  int _reconnectAttempts = 0;

  bool get connected => _connected;
  int get reconnectAttempts => _reconnectAttempts;

  void connect(String url) {
    _url = url;
    _shouldReconnect = true;
    _rejectedStreak = 0;
    _reconnectAttempts = 0;
    _rejectionProbeFired = false;
    _doConnect();
  }

  void _doConnect() {
    if (_url == null) return;
    // Clean up old subscription and channel before creating new one
    _subscription?.cancel();
    _subscription = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _stopHeartbeat();
    // A resume probe against the socket we are replacing is meaningless now.
    _resumeProbeTimer?.cancel();
    _resumeProbeTimer = null;
    _gotMessageThisAttempt = false;
    _connectTimer?.cancel();
    _connectTimer = Timer(_connectTimeout, _onConnectTimeout);
    try {
      _channel = WebSocketChannel.connect(Uri.parse(_url!));
      _subscription = _channel!.stream.listen(
        (data) {
          _lastMessageAt = DateTime.now();
          _gotMessageThisAttempt = true;
          _connectTimer?.cancel();
          _connectTimer = null;
          _rejectedStreak = 0;
          _rejectionProbeFired = false;
          _reconnectAttempts = 0;
          if (!_connected) {
            _connected = true;
            _reconnectDelay = 1000;
            _startHeartbeat();
            _dispatch('_connected', {});
            notifyListeners();
          }
          try {
            final msg = jsonDecode(data as String) as Map<String, dynamic>;
            _dispatch(msg['type'] as String, msg);
          } catch (e) {
            debugPrint('WS parse error: $e');
          }
        },
        onDone: _onConnectionLost,
        onError: (e) => _onConnectionLost(),
      );
    } catch (e) {
      debugPrint('WS connect error: $e');
      _noteFailedAttempt();
      _scheduleReconnect();
    }
  }

  void _onConnectionLost() {
    _connectTimer?.cancel();
    _connectTimer = null;
    _resumeProbeTimer?.cancel();
    _resumeProbeTimer = null;
    _connected = false;
    _stopHeartbeat();
    _noteFailedAttempt();
    _dispatch('_disconnected', {});
    notifyListeners();
    _scheduleReconnect();
  }

  /// The socket produced neither a message nor an error within
  /// [_connectTimeout] — tear it down and retry rather than sitting in a
  /// zombie state where `connected` is false and every send() is dropped.
  void _onConnectTimeout() {
    _connectTimer = null;
    if (_gotMessageThisAttempt) return;
    debugPrint('WS connect timeout: no data within ${_connectTimeout.inSeconds}s');
    _subscription?.cancel();
    _subscription = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    final wasConnected = _connected;
    _connected = false;
    _stopHeartbeat();
    _noteFailedAttempt();
    if (wasConnected) _dispatch('_disconnected', {});
    notifyListeners();
    _scheduleReconnect();
  }

  void _noteFailedAttempt() {
    if (_gotMessageThisAttempt) return;
    _rejectedStreak++;
    if (_rejectedStreak >= _rejectionStreakThreshold && !_rejectionProbeFired) {
      _rejectionProbeFired = true;
      onRepeatedRejections?.call();
    }
  }

  /// Allow [onRepeatedRejections] to fire again after another failure streak
  /// (called when a probe finds the session still valid / server unreachable).
  void resetRejectionProbe() {
    _rejectedStreak = 0;
    _rejectionProbeFired = false;
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _watchdogTimer?.cancel();
    _lastMessageAt = DateTime.now();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      if (_connected) send('heartbeat');
    });
    _watchdogTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      final last = _lastMessageAt;
      if (last == null) return;
      if (DateTime.now().difference(last) > _staleThreshold) {
        debugPrint('WS watchdog: stale connection, forcing reconnect');
        forceReconnect();
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
  }

  void forceReconnect() {
    if (_url == null) return;
    _stopHeartbeat();
    _subscription?.cancel();
    _subscription = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    if (_connected) {
      _connected = false;
      _dispatch('_disconnected', {});
      notifyListeners();
    }
    _reconnectDelay = 1000;
    _reconnectTimer?.cancel();
    _doConnect();
  }

  /// User-initiated "retry now" from the connection banner: skip the current
  /// backoff wait and reconnect immediately.
  void retryNow() {
    if (_url == null || _connected) return;
    forceReconnect();
  }

  /// Reconnect only if the link is actually down or has gone quiet. Used on app
  /// resume: tearing down a healthy socket there would drop every server-side
  /// shell and screen stream on every app switch.
  void reconnectIfStale() {
    if (_url == null) return;
    if (!_connected) {
      forceReconnect();
      return;
    }
    final last = _lastMessageAt;
    if (last == null ||
        DateTime.now().difference(last) > _staleThreshold) {
      forceReconnect();
      return;
    }
    // Looks healthy, but a socket can die silently while the app is
    // backgrounded. Poke the server and give it a short window to answer —
    // waiting for the 50 s watchdog would leave the UI claiming "connected"
    // while every message vanishes.
    final probeSentAt = DateTime.now();
    send('heartbeat');
    _resumeProbeTimer?.cancel();
    _resumeProbeTimer = Timer(_resumeProbeTimeout, () {
      _resumeProbeTimer = null;
      final latest = _lastMessageAt;
      if (latest == null || latest.isBefore(probeSentAt)) {
        debugPrint('WS resume probe unanswered, reconnecting');
        forceReconnect();
      }
    });
  }

  void _scheduleReconnect() {
    if (!_shouldReconnect) return;
    _reconnectAttempts++;
    // The attempt count is part of what the banner shows, and callers notify
    // before scheduling — publish the new value so the banner isn't a step behind.
    notifyListeners();
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: _reconnectDelay), () {
      _doConnect();
    });
    _reconnectDelay = (_reconnectDelay * 2).clamp(1000, _maxReconnectDelay);
  }

  void send(String type, [Map<String, dynamic> payload = const {}]) {
    // Capture the channel locally so it can't be nulled out from under us
    // by a concurrent disconnect between the guard and the add().
    final channel = _channel;
    if (channel == null || !_connected) return;
    try {
      final msg = jsonEncode({'type': type, 'payload': payload});
      channel.sink.add(msg);
    } catch (e) {
      debugPrint('WS send error: $e');
      // Tear the dead socket down here rather than waiting for onDone, which
      // may lag or never fire — and which would otherwise re-run this whole
      // disconnect path a second time.
      _subscription?.cancel();
      _subscription = null;
      try {
        _channel?.sink.close();
      } catch (_) {}
      _channel = null;
      _connectTimer?.cancel();
      _connectTimer = null;
      _connected = false;
      _stopHeartbeat();
      _dispatch('_disconnected', {});
      notifyListeners();
      _scheduleReconnect();
    }
  }

  void on(String type, void Function(Map<String, dynamic>) callback) {
    _handlers.putIfAbsent(type, () => []).add(callback);
  }

  void off(String type, [void Function(Map<String, dynamic>)? callback]) {
    if (callback == null) {
      _handlers.remove(type);
    } else {
      _handlers[type]?.remove(callback);
    }
  }

  void _dispatch(String type, Map<String, dynamic> msg) {
    final cbs = _handlers[type];
    if (cbs == null) return;
    for (final cb in List.of(cbs)) {
      try {
        cb(msg);
      } catch (e) {
        debugPrint('Handler error: $e');
      }
    }
  }

  void disconnect() {
    _shouldReconnect = false;
    _reconnectTimer?.cancel();
    _connectTimer?.cancel();
    _connectTimer = null;
    _resumeProbeTimer?.cancel();
    _resumeProbeTimer = null;
    _stopHeartbeat();
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    _connected = false;
    _rejectedStreak = 0;
    _reconnectAttempts = 0;
    _rejectionProbeFired = false;
    notifyListeners();
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}
