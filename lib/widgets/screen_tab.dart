import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
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

  // Screen-check timeout: without it an agent that never answers leaves the
  // tab on a permanent spinner with no way out.
  Timer? _checkTimeout;
  static const _checkTimeoutDuration = Duration(seconds: 10);

  // Live stream stats + stall detection.
  Timer? _statsTimer;
  int _framesSinceTick = 0;
  double _liveFps = 0;
  int _bytesSinceTick = 0;
  double _liveKbps = 0;
  DateTime? _lastFrameAt;
  bool get _stalled =>
      _streaming &&
      _lastFrameAt != null &&
      DateTime.now().difference(_lastFrameAt!) > const Duration(seconds: 5);

  final TransformationController _transformCtrl = TransformationController();
  final TextEditingController _typeCtrl = TextEditingController();
  final FocusNode _typeFocusNode = FocusNode();

  late void Function(Map<String, dynamic>) _frameHandler;
  late void Function(Map<String, dynamic>) _checkHandler;
  late void Function(Map<String, dynamic>) _errorHandler;
  late void Function(Map<String, dynamic>) _connHandler;
  late void Function(Map<String, dynamic>) _disconnHandler;

  final GlobalKey _canvasKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _ws = context.read<WsService>();

    _frameHandler = (msg) {
      if (!mounted) return;
      final payload = msg['payload'] as Map<String, dynamic>? ?? {};
      final data = payload['data'] as String? ?? '';
      _lastFrameAt = DateTime.now();
      _framesSinceTick++;
      _bytesSinceTick += data.length;
      if (!_decoding) {
        // Dimensions are adopted together with the decoded image so the painted
        // frame and the tap-coordinate mapping can never disagree.
        _decodeFrame(
          data,
          (payload['width'] as num?)?.toInt() ?? 0,
          (payload['height'] as num?)?.toInt() ?? 0,
        );
      }
    };

    _checkHandler = (msg) {
      if (!mounted) return;
      _checkTimeout?.cancel();
      final payload = msg['payload'] as Map<String, dynamic>? ?? {};
      setState(() {
        _available = payload['available'] == true;
        _checking = false;
      });
    };

    _errorHandler = (msg) {
      if (!mounted) return;
      _checkTimeout?.cancel();
      _stopStatsTimer();
      // Clear _checking too: an agent that answers screen_check with an error
      // would otherwise leave the tab spinning forever.
      setState(() {
        _streaming = false;
        _checking = false;
      });
      final t = context.read<ThemeService>().current;
      final message = (msg['payload'] as Map<String, dynamic>?)?['message'] ?? 'Screen error';
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message.toString()), backgroundColor: t.danger));
    };

    _connHandler = (_) {
      if (mounted) {
        // The server's stream did not survive the reconnect, so clear the
        // local streaming flag — otherwise the UI shows "Waiting for frames..."
        // forever and inputs go nowhere until the user manually taps Stop.
        _stopStatsTimer();
        setState(() { _streaming = false; });
        _sendCheck();
      }
    };

    // A dropped connection kills the server-side stream: stop the 1 Hz stats
    // rebuild immediately instead of ticking for the whole outage.
    _disconnHandler = (_) {
      if (!mounted) return;
      _checkTimeout?.cancel();
      _stopStatsTimer();
      setState(() {
        _streaming = false;
        _checking = false;
      });
    };

    _ws.on('screen_frame', _frameHandler);
    _ws.on('screen_check_res', _checkHandler);
    _ws.on('screen_error', _errorHandler);
    _ws.on('_connected', _connHandler);
    _ws.on('_disconnected', _disconnHandler);

    if (_ws.connected) {
      _beginCheck();
    } else {
      _checking = false;
    }
  }

  /// Ask the agent whether screen sharing is available, with a timeout so an
  /// unanswered check can never strand the tab on a spinner.
  void _sendCheck() {
    _beginCheck();
    setState(() {});
  }

  /// The state mutation without the rebuild, so initState can arm a check
  /// before the first frame (setState there would be a no-op at best).
  void _beginCheck() {
    _checkTimeout?.cancel();
    _checking = true;
    _ws.send('screen_check');
    _checkTimeout = Timer(_checkTimeoutDuration, () {
      if (!mounted || !_checking) return;
      setState(() {
        _checking = false;
        _available = false;
      });
    });
  }

  void _startStatsTimer() {
    _statsTimer?.cancel();
    _framesSinceTick = 0;
    _bytesSinceTick = 0;
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _liveFps = _framesSinceTick.toDouble();
        // Payloads are base64, so raw bytes are ~3/4 of the string length.
        _liveKbps = _bytesSinceTick * 0.75 / 1024;
        _framesSinceTick = 0;
        _bytesSinceTick = 0;
      });
    });
  }

  void _stopStatsTimer() {
    _statsTimer?.cancel();
    _statsTimer = null;
    _liveFps = 0;
    _liveKbps = 0;
    _lastFrameAt = null;
  }

  Future<void> _decodeFrame(String b64data, int width, int height) async {
    if (b64data.isEmpty) return;
    _decoding = true;
    ui.Image? decoded;
    try {
      final bytes = base64Decode(b64data);
      final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
      final frame = await codec.getNextFrame();
      decoded = frame.image;
      if (mounted) {
        final old = _currentFrame;
        _currentFrame = decoded;
        if (width > 0 && height > 0) {
          _naturalWidth = width;
          _naturalHeight = height;
        }
        decoded = null; // adopted — must not be disposed in finally
        setState(() {});
        old?.dispose();
      }
    } catch (e) {
      debugPrint('Frame decode error: $e');
    } finally {
      // Dispose the freshly decoded image if it was never adopted (widget
      // unmounted, or setState threw) so native image memory can't leak.
      decoded?.dispose();
      _decoding = false;
    }
  }

  void _start() {
    if (!_ws.connected) return;
    _ws.send('screen_start', {
      'fps': _fps.toInt(),
      'quality': _quality.toInt(),
      'max_width': 1920,
    });
    _lastFrameAt = DateTime.now();
    _startStatsTimer();
    setState(() => _streaming = true);
  }

  void _stop() {
    _ws.send('screen_stop');
    _stopStatsTimer();
    setState(() => _streaming = false);
  }

  /// Save the currently displayed frame as a PNG in the app's documents
  /// directory (visible in the Files tab's downloads manager).
  Future<void> _saveScreenshot() async {
    final frame = _currentFrame;
    if (frame == null) return;
    final t = context.read<ThemeService>().current;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final data = await frame.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw Exception('encode failed');
      final dir = await getApplicationDocumentsDirectory();
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(RegExp(r'[:.]'), '-')
          .substring(0, 19);
      final file = File('${dir.path}/screenshot-$stamp.png');
      await file.writeAsBytes(data.buffer.asUint8List());
      if (!mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('Saved ${file.path.split('/').last}'),
          backgroundColor: t.success,
          action: SnackBarAction(
            label: 'Open',
            textColor: t.bgPrimary,
            onPressed: () => OpenFile.open(file.path),
          ),
        ));
    } catch (e) {
      if (!mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
            content: Text('Screenshot failed: $e'), backgroundColor: t.danger));
    }
  }

  /// Map a tap on the canvas to remote screen pixels.
  ///
  /// The GestureDetector sits INSIDE InteractiveViewer's transform, so Flutter
  /// has already converted the pointer through the render transform chain:
  /// `localPosition` is in the canvas's own untransformed space. Applying the
  /// inverse matrix again here would double-transform and send clicks to the
  /// wrong place whenever the view is zoomed or panned.
  Offset _toRemote(Offset local) {
    if (_naturalWidth == 0 || _naturalHeight == 0) return Offset.zero;
    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return Offset.zero;
    final canvasSize = box.size;
    if (canvasSize.width == 0 || canvasSize.height == 0) return Offset.zero;
    final scaleX = _naturalWidth / canvasSize.width;
    final scaleY = _naturalHeight / canvasSize.height;
    return Offset(
      (local.dx * scaleX).clamp(0, _naturalWidth.toDouble()).roundToDouble(),
      (local.dy * scaleY).clamp(0, _naturalHeight.toDouble()).roundToDouble(),
    );
  }

  /// A click is emitted as a down/up pair only once the tap is CONFIRMED
  /// (onTapUp). Sending mouse_down from onTapDown would leave the remote button
  /// held whenever the tap turns into an InteractiveViewer pan or pinch — and
  /// synthesising the missing mouse_up on cancel would instead turn every pan
  /// into a stray click. Emitting nothing until the tap wins the arena avoids
  /// both failure modes.
  void _onTapUp(TapUpDetails d) {
    if (!_streaming) return;
    final remote = _toRemote(d.localPosition);
    final data = {
      'x': remote.dx.toInt(),
      'y': remote.dy.toInt(),
      'button': 1,
    };
    _ws.send('screen_input', {'input_type': 'mouse_down', 'data': data});
    _ws.send('screen_input', {'input_type': 'mouse_up', 'data': data});
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
    _checkTimeout?.cancel();
    _statsTimer?.cancel();
    _ws.off('screen_frame', _frameHandler);
    _ws.off('screen_check_res', _checkHandler);
    _ws.off('screen_error', _errorHandler);
    _ws.off('_connected', _connHandler);
    _ws.off('_disconnected', _disconnHandler);
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
                                      child: LayoutBuilder(
                                        builder: (context, constraints) => GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onTapUp: _onTapUp,
                                          onDoubleTapDown: _onDoubleTapDown,
                                          child: CustomPaint(
                                            key: _canvasKey,
                                            painter: _FramePainter(_currentFrame!),
                                            size: _calculateSize(constraints),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                // Live stats + stall warning
                                if (_streaming)
                                  Positioned(
                                    top: 8,
                                    left: 8,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: Colors.black54,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Text(
                                        _stalled
                                            ? 'STREAM STALLED'
                                            : '${_liveFps.toStringAsFixed(0)} fps · '
                                                '${_liveKbps.toStringAsFixed(0)} KB/s · '
                                                '${_naturalWidth}x$_naturalHeight',
                                        style: TextStyle(
                                          color: _stalled
                                              ? t.danger
                                              : Colors.white70,
                                          fontSize: 10,
                                          fontFamily: 'monospace',
                                          fontWeight: _stalled
                                              ? FontWeight.bold
                                              : FontWeight.normal,
                                        ),
                                      ),
                                    ),
                                  ),
                                // Screenshot + toggle controls buttons
                                Positioned(
                                  top: 8, right: 8,
                                  child: Row(
                                    children: [
                                      Material(
                                        color: Colors.black54,
                                        borderRadius: BorderRadius.circular(20),
                                        child: InkWell(
                                          borderRadius: BorderRadius.circular(20),
                                          onTap: _saveScreenshot,
                                          child: const Padding(
                                            padding: EdgeInsets.all(8),
                                            child: Icon(Icons.photo_camera,
                                                color: Colors.white70, size: 20),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Material(
                                        color: Colors.black54,
                                        borderRadius: BorderRadius.circular(20),
                                        child: InkWell(
                                          borderRadius: BorderRadius.circular(20),
                                          onTap: () => setState(
                                              () => _showControls = !_showControls),
                                          child: Padding(
                                            padding: const EdgeInsets.all(8),
                                            child: Icon(
                                              _showControls
                                                  ? Icons.expand_less
                                                  : Icons.expand_more,
                                              color: Colors.white70,
                                              size: 20,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
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
                  // Disabled while offline so adjustments can't be silently
                  // dropped on a closed channel and lost on reconnect.
                  onChanged: !wsConnected ? null : (v) {
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
                  onChanged: !wsConnected ? null : (v) {
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
                  onPressed: _sendCheck,
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

  Size _calculateSize(BoxConstraints constraints) {
    if (_naturalWidth == 0 || _naturalHeight == 0) return Size.zero;
    // Fit within the ACTUAL available canvas area (from LayoutBuilder) rather
    // than subtracting a hardcoded 200px from screen height, which breaks on
    // small screens / split-screen / landscape (could go zero or negative).
    final maxW = constraints.maxWidth;
    final maxH = constraints.maxHeight;
    if (maxW <= 0 || maxH <= 0 || !maxW.isFinite || !maxH.isFinite) {
      return Size.zero;
    }
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
