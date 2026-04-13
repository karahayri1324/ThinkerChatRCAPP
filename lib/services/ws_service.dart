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
  Timer? _reconnectTimer;
  String? _url;

  bool get connected => _connected;

  void connect(String url) {
    _url = url;
    _shouldReconnect = true;
    _doConnect();
  }

  void _doConnect() {
    if (_url == null) return;
    // Clean up old subscription before creating new one
    _subscription?.cancel();
    _subscription = null;
    try {
      _channel = WebSocketChannel.connect(Uri.parse(_url!));
      _subscription = _channel!.stream.listen(
        (data) {
          if (!_connected) {
            _connected = true;
            _reconnectDelay = 1000;
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
          _dispatch('_disconnected', {});
          notifyListeners();
          _scheduleReconnect();
        },
        onError: (e) {
          _connected = false;
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
