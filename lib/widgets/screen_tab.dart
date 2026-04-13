import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/ws_service.dart';
import '../services/theme_service.dart';
import 'connection_banner.dart';

class ScreenTab extends StatefulWidget {
  const ScreenTab({super.key});

  @override
  State<ScreenTab> createState() => _ScreenTabState();
}

class _ScreenTabState extends State<ScreenTab> {
  late WsService _ws;
  bool _streaming = false;
  bool _available = false;
  bool _checking = true;
  double _fps = 15;
  double _quality = 50;
  ui.Image? _currentFrame;
  int _naturalWidth = 0;
  int _naturalHeight = 0;
  bool _decoding = false;
  bool _showControls = true;

  final TransformationController _transformCtrl = TransformationController();
  final TextEditingController _typeCtrl = TextEditingController();
  final FocusNode _typeFocusNode = FocusNode();

  late void Function(Map<String, dynamic>) _frameHandler;
  late void Function(Map<String, dynamic>) _checkHandler;
  late void Function(Map<String, dynamic>) _errorHandler;
  late void Function(Map<String, dynamic>) _connHandler;

  final GlobalKey _canvasKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _ws = context.read<WsService>();

    _frameHandler = (msg) {
      if (!mounted) return;
      final payload = msg['payload'] as Map<String, dynamic>? ?? {};
      _naturalWidth = (payload['width'] as num?)?.toInt() ?? 0;
      _naturalHeight = (payload['height'] as num?)?.toInt() ?? 0;
      if (!_decoding) {
        _decodeFrame(payload['data'] as String? ?? '');
      }
    };

    _checkHandler = (msg) {
      if (!mounted) return;
      final payload = msg['payload'] as Map<String, dynamic>? ?? {};
      setState(() {
        _available = payload['available'] == true;
        _checking = false;
      });
    };

    _errorHandler = (msg) {
      if (!mounted) return;
      setState(() => _streaming = false);
      final t = context.read<ThemeService>().current;
      final message = (msg['payload'] as Map<String, dynamic>?)?['message'] ?? 'Screen error';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message.toString()), backgroundColor: t.danger),
      );
    };

    _connHandler = (_) {
      if (mounted) {
        setState(() => _checking = true);
        _ws.send('screen_check');
      }
    };

    _ws.on('screen_frame', _frameHandler);
    _ws.on('screen_check_res', _checkHandler);
    _ws.on('screen_error', _errorHandler);
    _ws.on('_connected', _connHandler);

    if (_ws.connected) {
      _ws.send('screen_check');
    } else {
      _checking = false;
    }
  }

  Future<void> _decodeFrame(String b64data) async {
    if (b64data.isEmpty) return;
    _decoding = true;
    try {
      final bytes = base64Decode(b64data);
      final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
      final frame = await codec.getNextFrame();
      if (mounted) {
        setState(() {
          _currentFrame?.dispose();
          _currentFrame = frame.image;
        });
      } else {
        frame.image.dispose();
      }
    } catch (e) {
      debugPrint('Frame decode error: $e');
    }
    _decoding = false;
  }

  void _start() {
    if (!_ws.connected) return;
    _ws.send('screen_start', {
      'fps': _fps.toInt(),
      'quality': _quality.toInt(),
      'max_width': 1920,
    });
    setState(() => _streaming = true);
  }

  void _stop() {
    _ws.send('screen_stop');
    setState(() => _streaming = false);
  }

  Offset _toRemote(Offset local) {
    if (_naturalWidth == 0 || _naturalHeight == 0) return Offset.zero;
    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return Offset.zero;
    final canvasSize = box.size;
    if (canvasSize.width == 0 || canvasSize.height == 0) return Offset.zero;
    final matrix = _transformCtrl.value;
    try {
      final inverted = Matrix4.inverted(matrix);
      final transformed = MatrixUtils.transformPoint(inverted, local);
      final scaleX = _naturalWidth / canvasSize.width;
      final scaleY = _naturalHeight / canvasSize.height;
      return Offset(
        (transformed.dx * scaleX).clamp(0, _naturalWidth.toDouble()).roundToDouble(),
        (transformed.dy * scaleY).clamp(0, _naturalHeight.toDouble()).roundToDouble(),
      );
    } catch (_) {
      return Offset.zero;
    }
  }

  void _onTapDown(TapDownDetails d) {
    if (!_streaming) return;
    final remote = _toRemote(d.localPosition);
    _ws.send('screen_input', {
      'input_type': 'mouse_down',
      'data': {'x': remote.dx.toInt(), 'y': remote.dy.toInt(), 'button': 1},
    });
  }

  void _onTapUp(TapUpDetails d) {
    if (!_streaming) return;
    final remote = _toRemote(d.localPosition);
    _ws.send('screen_input', {
      'input_type': 'mouse_up',
      'data': {'x': remote.dx.toInt(), 'y': remote.dy.toInt(), 'button': 1},
    });
  }

  void _onDoubleTapDown(TapDownDetails d) {
    if (!_streaming) return;
    final remote = _toRemote(d.localPosition);
    _ws.send('screen_input', {
      'input_type': 'mouse_dblclick',
      'data': {'x': remote.dx.toInt(), 'y': remote.dy.toInt(), 'button': 1},
    });
  }

  void _sendRemoteKey(String key) {
    if (!_streaming) return;
    HapticFeedback.lightImpact();
    _ws.send('screen_input', {
      'input_type': 'key_press',
      'data': {'key': key},
    });
  }

  void _sendRemoteText(String text) {
    if (!_streaming || text.isEmpty) return;
    _ws.send('screen_input', {
      'input_type': 'key_type',
      'data': {'text': text},
    });
  }

  void _resetZoom() {
    _transformCtrl.value = Matrix4.identity();
  }

  void _sendSettings() {
    _ws.send('screen_start', {
      'fps': _fps.toInt(),
      'quality': _quality.toInt(),
      'max_width': 1920,
    });
  }

  @override
  void dispose() {
    _ws.off('screen_frame', _frameHandler);
    _ws.off('screen_check_res', _checkHandler);
    _ws.off('screen_error', _errorHandler);
    _ws.off('_connected', _connHandler);
    _currentFrame?.dispose();
    _transformCtrl.dispose();
    _typeCtrl.dispose();
    _typeFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.watch<ThemeService>().current;
    final wsConnected = context.watch<WsService>().connected;

    return Column(
      children: [
        const ConnectionBanner(),
        // Controls (collapsible)
        if (_showControls) _buildControls(t, wsConnected),
        Divider(height: 1, color: t.border),
        // Canvas
        Expanded(
          child: !wsConnected
              ? _buildStatus(t, Icons.cloud_off, 'Not connected')
              : _checking
                  ? Center(child: CircularProgressIndicator(color: t.accent))
                  : !_available
                      ? _buildStatus(t, Icons.desktop_access_disabled, 'Screen sharing not available on this agent')
                      : _currentFrame == null
                          ? _buildStatus(t, _streaming ? Icons.hourglass_empty : Icons.desktop_windows, _streaming ? 'Waiting for frames...' : 'Tap Start to begin')
                          : Stack(
                              children: [
                                Container(
                                  color: Colors.black,
                                  child: InteractiveViewer(
                                    transformationController: _transformCtrl,
                                    minScale: 1.0,
                                    maxScale: 5.0,
                                    panEnabled: true,
                                    scaleEnabled: true,
                                    child: Center(
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onTapDown: _onTapDown,
                                        onTapUp: _onTapUp,
                                        onDoubleTapDown: _onDoubleTapDown,
                                        child: CustomPaint(
                                          key: _canvasKey,
                                          painter: _FramePainter(_currentFrame!),
                                          size: _calculateSize(context),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                // Toggle controls button
                                Positioned(
                                  top: 8, right: 8,
                                  child: Material(
                                    color: Colors.black54,
                                    borderRadius: BorderRadius.circular(20),
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(20),
                                      onTap: () => setState(() => _showControls = !_showControls),
                                      child: Padding(
                                        padding: const EdgeInsets.all(8),
                                        child: Icon(
                                          _showControls ? Icons.expand_less : Icons.expand_more,
                                          color: Colors.white70, size: 20,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
        ),
        // Remote keyboard toolbar (when streaming)
        if (_streaming) _buildRemoteKeybar(t),
      ],
    );
  }

  Widget _buildControls(AppThemeData t, bool wsConnected) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: t.bgSecondary,
      child: Column(
        children: [
          Row(
            children: [
              Text('FPS: ${_fps.toInt()}', style: TextStyle(color: t.textMuted, fontSize: 12)),
              Expanded(
                child: Slider(
                  value: _fps, min: 1, max: 60,
                  activeColor: t.accent,
                  onChanged: (v) {
                    setState(() => _fps = v);
                    if (_streaming) _sendSettings();
                  },
                ),
              ),
              Text('Q: ${_quality.toInt()}', style: TextStyle(color: t.textMuted, fontSize: 12)),
              Expanded(
                child: Slider(
                  value: _quality, min: 10, max: 95,
                  activeColor: t.accent,
                  onChanged: (v) {
                    setState(() => _quality = v);
                    if (_streaming) _sendSettings();
                  },
                ),
              ),
            ],
          ),
          Row(
            children: [
              ElevatedButton(
                onPressed: (!wsConnected || !_available) ? null : (_streaming ? _stop : _start),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _streaming ? t.danger : t.accent,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                ),
                child: Text(_streaming ? 'Stop' : 'Start'),
              ),
              const SizedBox(width: 8),
              if (_streaming)
                IconButton(
                  icon: const Icon(Icons.zoom_out_map, size: 20),
                  color: t.textMuted,
                  tooltip: 'Reset zoom',
                  onPressed: _resetZoom,
                ),
              if (!_available && wsConnected)
                TextButton.icon(
                  icon: Icon(Icons.refresh, size: 16, color: t.textMuted),
                  label: Text('Re-check', style: TextStyle(color: t.textMuted, fontSize: 12)),
                  onPressed: () {
                    setState(() => _checking = true);
                    _ws.send('screen_check');
                  },
                ),
              const Spacer(),
              Text(
                !wsConnected ? 'Offline'
                    : !_available ? 'Not available'
                    : _streaming ? 'Tap image to toggle controls' : 'Ready',
                style: TextStyle(color: t.textMuted, fontSize: 11),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRemoteKeybar(AppThemeData t) {
    return Container(
      color: t.bgSecondary,
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            // Text input for typing on remote
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _typeCtrl,
                      focusNode: _typeFocusNode,
                      style: TextStyle(color: t.textPrimary, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: 'Type text to send...',
                        hintStyle: TextStyle(color: t.textMuted.withOpacity( 0.5)),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (text) {
                        _sendRemoteText(text);
                        _sendRemoteKey('Return');
                        _typeCtrl.clear();
                        _typeFocusNode.requestFocus();
                      },
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.send, size: 20, color: t.accent),
                    onPressed: () {
                      _sendRemoteText(_typeCtrl.text);
                      _sendRemoteKey('Return');
                      _typeCtrl.clear();
                    },
                  ),
                ],
              ),
            ),
            // Key shortcuts
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Row(
                children: [
                  _remoteKeyBtn(t, 'Enter', 'Return'),
                  _remoteKeyBtn(t, 'Esc', 'Escape'),
                  _remoteKeyBtn(t, 'Tab', 'Tab'),
                  _remoteKeyBtn(t, 'BS', 'BackSpace'),
                  _remoteKeyBtn(t, 'Del', 'Delete'),
                  _remoteKeyBtn(t, 'Space', 'space'),
                  _remoteKeyBtn(t, 'Ctrl+C', 'ctrl+c'),
                  _remoteKeyBtn(t, 'Ctrl+V', 'ctrl+v'),
                  _remoteKeyBtn(t, 'Ctrl+Z', 'ctrl+z'),
                  _remoteKeyBtn(t, 'Ctrl+A', 'ctrl+a'),
                  _remoteKeyBtn(t, 'Alt+Tab', 'alt+Tab'),
                  _remoteKeyBtn(t, 'Alt+F4', 'alt+F4'),
                  _remoteIconBtn(t, Icons.arrow_upward, 'Up'),
                  _remoteIconBtn(t, Icons.arrow_downward, 'Down'),
                  _remoteIconBtn(t, Icons.arrow_back, 'Left'),
                  _remoteIconBtn(t, Icons.arrow_forward, 'Right'),
                  _remoteKeyBtn(t, 'Home', 'Home'),
                  _remoteKeyBtn(t, 'End', 'End'),
                  _remoteKeyBtn(t, 'PgUp', 'Prior'),
                  _remoteKeyBtn(t, 'PgDn', 'Next'),
                  _remoteKeyBtn(t, 'F5', 'F5'),
                  _remoteKeyBtn(t, 'F11', 'F11'),
                  // Scroll buttons
                  _remoteScrollBtn(t, Icons.expand_less, 'up'),
                  _remoteScrollBtn(t, Icons.expand_more, 'down'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _remoteKeyBtn(AppThemeData t, String label, String key) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: t.bgTertiary,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => _sendRemoteKey(key),
          child: Container(
            constraints: const BoxConstraints(minWidth: 40, minHeight: 32),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.center,
            child: Text(label, style: TextStyle(color: t.textPrimary, fontSize: 11, fontFamily: 'monospace')),
          ),
        ),
      ),
    );
  }

  Widget _remoteIconBtn(AppThemeData t, IconData icon, String key) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: t.bgTertiary,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => _sendRemoteKey(key),
          child: Container(
            constraints: const BoxConstraints(minWidth: 36, minHeight: 32),
            alignment: Alignment.center,
            child: Icon(icon, size: 16, color: t.textPrimary),
          ),
        ),
      ),
    );
  }

  Widget _remoteScrollBtn(AppThemeData t, IconData icon, String direction) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: t.accent.withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () {
            if (!_streaming) return;
            HapticFeedback.lightImpact();
            _ws.send('screen_input', {
              'input_type': 'mouse_scroll',
              'data': {
                'x': _naturalWidth ~/ 2,
                'y': _naturalHeight ~/ 2,
                'direction': direction,
                'clicks': 3,
              },
            });
          },
          child: Container(
            constraints: const BoxConstraints(minWidth: 36, minHeight: 32),
            alignment: Alignment.center,
            child: Icon(icon, size: 16, color: t.accent),
          ),
        ),
      ),
    );
  }

  Widget _buildStatus(AppThemeData t, IconData icon, String text) {
    return Container(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: t.textMuted),
            const SizedBox(height: 12),
            Text(text, style: TextStyle(color: t.textMuted, fontSize: 14), textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  Size _calculateSize(BuildContext context) {
    if (_naturalWidth == 0 || _naturalHeight == 0) return Size.zero;
    final screen = MediaQuery.of(context).size;
    final maxW = screen.width;
    final maxH = screen.height - 200;
    final ratio = _naturalWidth / _naturalHeight;
    double w, h;
    if (maxW / maxH > ratio) {
      h = maxH;
      w = h * ratio;
    } else {
      w = maxW;
      h = w / ratio;
    }
    return Size(w, h);
  }
}

class _FramePainter extends CustomPainter {
  final ui.Image image;
  _FramePainter(this.image);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_FramePainter old) => old.image != image;
}
