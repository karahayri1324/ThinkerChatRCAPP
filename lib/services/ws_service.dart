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
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  Timer? _watchdogTimer;
  DateTime? _lastMessageAt;
  String? _url;

  bool get connected => _connected;

  void connect(String url) {
    _url = url;
    _shouldReconnect = true;
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
    try {
      _channel = WebSocketChannel.connect(Uri.parse(_url!));
      _subscription = _channel!.stream.listen(
        (data) {
          _lastMessageAt = DateTime.now();
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
        onDone: () {
          _connected = false;
          _stopHeartbeat();
          _dispatch('_disconnected', {});
          notifyListeners();
          _scheduleReconnect();
        },
        onError: (e) {
          _connected = false;
          _stopHeartbeat();
          _dispatch('_disconnected', {});
          notifyListeners();
          _scheduleReconnect();
        },
      );
    } catch (e) {
      debugPrint('WS connect error: $e');
      _scheduleReconnect();
    }
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

  void _scheduleReconnect() {
    if (!_shouldReconnect) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: _reconnectDelay), () {
      _doConnect();
    });
    _reconnectDelay = (_reconnectDelay * 2).clamp(1000, _maxReconnectDelay);
  }

  void send(String type, [Map<String, dynamic> payload = const {}]) {
    if (_channel == null || !_connected) return;
    try {
      final msg = jsonEncode({'type': type, 'payload': payload});
      _channel!.sink.add(msg);
    } catch (e) {
      debugPrint('WS send error: $e');
      _connected = false;
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
    _stopHeartbeat();
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    _connected = false;
    notifyListeners();
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}
