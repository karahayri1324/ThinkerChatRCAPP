import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

import 'package:provider/provider.dart';
import '../services/ws_service.dart';
import '../theme.dart';

class ScreenTab extends StatefulWidget {
  const ScreenTab({super.key});

  @override
  State<ScreenTab> createState() => _ScreenTabState();
}

class _ScreenTabState extends State<ScreenTab> {
  late WsService _ws;
  bool _streaming = false;
  bool _available = false;
  double _fps = 15;
  double _quality = 50;
  ui.Image? _currentFrame;
  int _naturalWidth = 0;
  int _naturalHeight = 0;
  bool _decoding = false;

  late void Function(Map<String, dynamic>) _frameHandler;
  late void Function(Map<String, dynamic>) _checkHandler;
  late void Function(Map<String, dynamic>) _errorHandler;

  final GlobalKey _canvasKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _ws = context.read<WsService>();

    _frameHandler = (msg) {
      final payload = msg['payload'] as Map<String, dynamic>? ?? {};
      _naturalWidth = (payload['width'] as num?)?.toInt() ?? 0;
      _naturalHeight = (payload['height'] as num?)?.toInt() ?? 0;
      if (!_decoding) {
        _decodeFrame(payload['data'] as String? ?? '');
      }
    };

    _checkHandler = (msg) {
      final payload = msg['payload'] as Map<String, dynamic>? ?? {};
      setState(() => _available = payload['available'] == true);
    };

    _errorHandler = (msg) {
      setState(() => _streaming = false);
    };

    _ws.on('screen_frame', _frameHandler);
    _ws.on('screen_check_res', _checkHandler);
    _ws.on('screen_error', _errorHandler);
    _ws.send('screen_check');
  }

  Future<void> _decodeFrame(String b64data) async {
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
    // CustomPaint size matches the canvas exactly, so direct mapping works
    final canvasSize = box.size;
    final scaleX = _naturalWidth / canvasSize.width;
    final scaleY = _naturalHeight / canvasSize.height;
    return Offset(
      (local.dx * scaleX).clamp(0, _naturalWidth.toDouble()).roundToDouble(),
      (local.dy * scaleY).clamp(0, _naturalHeight.toDouble()).roundToDouble(),
    );
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

  void _onDoubleTap() {
    // Use last known position or center
    if (!_streaming) return;
    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final center = box.size.center(Offset.zero);
    final remote = _toRemote(center);
    _ws.send('screen_input', {
      'input_type': 'mouse_dblclick',
      'data': {'x': remote.dx.toInt(), 'y': remote.dy.toInt(), 'button': 1},
    });
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (!_streaming) return;
    final remote = _toRemote(d.localPosition);
    _ws.send('screen_input', {
      'input_type': 'mouse_move',
      'data': {'x': remote.dx.toInt(), 'y': remote.dy.toInt()},
    });
  }

  @override
  void dispose() {
    _ws.off('screen_frame', _frameHandler);
    _ws.off('screen_check_res', _checkHandler);
    _ws.off('screen_error', _errorHandler);
    _currentFrame?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Controls
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          color: TokyoNight.bgSecondary,
          child: Column(
            children: [
              Row(
                children: [
                  Text('FPS: ${_fps.toInt()}',
                      style: const TextStyle(
                          color: TokyoNight.textMuted, fontSize: 12)),
                  Expanded(
                    child: Slider(
                      value: _fps,
                      min: 1,
                      max: 60,
                      activeColor: TokyoNight.accent,
                      onChanged: (v) {
                        setState(() => _fps = v);
                        if (_streaming) {
                          _ws.send('screen_start', {
                            'fps': v.toInt(),
                            'quality': _quality.toInt(),
                            'max_width': 1920,
                          });
                        }
                      },
                    ),
                  ),
                  Text('Q: ${_quality.toInt()}',
                      style: const TextStyle(
                          color: TokyoNight.textMuted, fontSize: 12)),
                  Expanded(
                    child: Slider(
                      value: _quality,
                      min: 10,
                      max: 95,
                      activeColor: TokyoNight.accent,
                      onChanged: (v) {
                        setState(() => _quality = v);
                        if (_streaming) {
                          _ws.send('screen_start', {
                            'fps': _fps.toInt(),
                            'quality': v.toInt(),
                            'max_width': 1920,
                          });
                        }
                      },
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  ElevatedButton(
                    onPressed: !_available ? null : (_streaming ? _stop : _start),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _streaming
                          ? TokyoNight.danger
                          : TokyoNight.accent,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 8),
                    ),
                    child: Text(_streaming ? 'Stop' : 'Start'),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    !_available
                        ? 'Not available'
                        : _streaming
                            ? 'Streaming...'
                            : 'Ready',
                    style: const TextStyle(
                        color: TokyoNight.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: TokyoNight.border),
        // Canvas
        Expanded(
          child: Container(
            color: Colors.black,
            child: Center(
              child: _currentFrame == null
                  ? const Text(
                      'No frame',
                      style: TextStyle(color: TokyoNight.textMuted),
                    )
                  : GestureDetector(
                      onTapDown: _onTapDown,
                      onTapUp: _onTapUp,
                      onDoubleTap: _onDoubleTap,
                      onPanUpdate: _onPanUpdate,
                      child: CustomPaint(
                        key: _canvasKey,
                        painter: _FramePainter(_currentFrame!),
                        size: _calculateSize(context),
                      ),
                    ),
            ),
          ),
        ),
      ],
    );
  }

  Size _calculateSize(BuildContext context) {
    if (_naturalWidth == 0 || _naturalHeight == 0) return Size.zero;
    final screen = MediaQuery.of(context).size;
    final maxW = screen.width;
    final maxH = screen.height - 200; // Approx space minus controls
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
