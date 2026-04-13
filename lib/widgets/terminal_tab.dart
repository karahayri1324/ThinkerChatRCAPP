import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';
import '../services/ws_service.dart';
import '../services/theme_service.dart';
import '../services/terminal_history_service.dart';
import 'connection_banner.dart';

class _ShellEntry {
  final String id;
  final Terminal terminal;
  final FocusNode focusNode;
  _ShellEntry(this.id, this.terminal, this.focusNode);
}

class TerminalTab extends StatefulWidget {
  const TerminalTab({super.key});

  @override
  State<TerminalTab> createState() => _TerminalTabState();
}

class _TerminalTabState extends State<TerminalTab> {
  final List<_ShellEntry> _shells = [];
  int _activeIndex = 0;
  int _nextId = 1;
  late WsService _ws;
  late void Function(Map<String, dynamic>) _outputHandler;

  // Command input
  final TextEditingController _inputCtrl = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();
  bool _useInputBar = true;

  // History save debounce
  Timer? _saveTimer;
  final Map<String, String> _pendingSaves = {};

  @override
  void initState() {
    super.initState();
    _ws = context.read<WsService>();
    _outputHandler = (msg) {
      if (!mounted) return;
      final payload = msg['payload'] as Map<String, dynamic>? ?? {};
      final shellId = payload['shell_id']?.toString() ?? '1';
      final data = payload['data'] as String? ?? '';
      final entry = _shells.where((s) => s.id == shellId).firstOrNull;
      if (entry != null) {
        entry.terminal.write(data);
        _debounceSave(shellId, data);
      }
    };
    _ws.on('shell_output', _outputHandler);
    _createShell();
  }

  void _debounceSave(String shellId, String data) {
    _pendingSaves[shellId] = (_pendingSaves[shellId] ?? '') + data;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 3), _flushSaves);
  }

  Future<void> _flushSaves() async {
    final saves = Map<String, String>.of(_pendingSaves);
    _pendingSaves.clear();
    for (final entry in saves.entries) {
      await TerminalHistoryService.saveOutput(entry.key, entry.value);
    }
  }

  Future<void> _createShell() async {
    final shellId = '${_nextId++}';
    final terminal = Terminal(maxLines: 5000);
    final focusNode = FocusNode();

    terminal.onOutput = (data) {
      _ws.send('shell_input', {'shell_id': shellId, 'data': data});
    };

    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      _ws.send('shell_resize', {
        'shell_id': shellId,
        'cols': width,
        'rows': height,
      });
    };

    final savedHistory = await TerminalHistoryService.getOutput(shellId);
    if (savedHistory != null && savedHistory.isNotEmpty) {
      terminal.write(savedHistory);
      terminal.write('\r\n--- Session restored ---\r\n');
    }

    _ws.send('shell_create', {'shell_id': shellId});

    setState(() {
      _shells.add(_ShellEntry(shellId, terminal, focusNode));
      _activeIndex = _shells.length - 1;
    });
  }

  void _closeShell(int index) {
    if (_shells.length <= 1) return;
    final entry = _shells[index];
    _ws.send('shell_close', {'shell_id': entry.id});
    entry.focusNode.dispose();
    setState(() {
      _shells.removeAt(index);
      if (_activeIndex >= _shells.length) {
        _activeIndex = _shells.length - 1;
      }
    });
  }

  void _sendKey(String data) {
    if (_shells.isEmpty) return;
    HapticFeedback.lightImpact();
    final shellId = _shells[_activeIndex].id;
    _ws.send('shell_input', {'shell_id': shellId, 'data': data});
  }

  void _sendCommand() {
    if (_shells.isEmpty) return;
    final text = _inputCtrl.text;
    if (text.isEmpty) {
      _sendKey('\r');
      return;
    }
    HapticFeedback.lightImpact();
    final shellId = _shells[_activeIndex].id;
    _ws.send('shell_input', {'shell_id': shellId, 'data': '$text\r'});
    _inputCtrl.clear();
  }

  Future<void> _pasteClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      if (_useInputBar) {
        // Paste into input field
        final currentText = _inputCtrl.text;
        final selection = _inputCtrl.selection;
        final newText = currentText.replaceRange(
          selection.start.clamp(0, currentText.length),
          selection.end.clamp(0, currentText.length),
          data.text!,
        );
        _inputCtrl.text = newText;
        _inputCtrl.selection = TextSelection.collapsed(
          offset: (selection.start.clamp(0, currentText.length) + data.text!.length),
        );
      } else {
        // Send directly to terminal
        _sendKey(data.text!);
      }
    }
  }

  void _dismissKeyboard() {
    HapticFeedback.lightImpact();
    FocusScope.of(context).unfocus();
  }

  void _focusTerminal() {
    if (_shells.isNotEmpty) {
      _shells[_activeIndex].focusNode.requestFocus();
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    final saves = Map<String, String>.of(_pendingSaves);
    _pendingSaves.clear();
    for (final entry in saves.entries) {
      TerminalHistoryService.saveOutput(entry.key, entry.value);
    }
    _ws.off('shell_output', _outputHandler);
    _inputCtrl.dispose();
    _inputFocusNode.dispose();
    for (final s in _shells) {
      s.focusNode.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.watch<ThemeService>().current;
    final fontSize = context.watch<ThemeService>().terminalFontSize;
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;

    return Column(
      children: [
        const ConnectionBanner(),
        // Tab bar
        _buildTabBar(t),
        Divider(height: 1, color: t.border),
        // Terminal view
        Expanded(
          child: _shells.isEmpty
              ? const SizedBox.shrink()
              : GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () {
                    if (_useInputBar) {
                      _inputFocusNode.requestFocus();
                    } else {
                      final kbOpen = MediaQuery.of(context).viewInsets.bottom > 50;
                      if (kbOpen) {
                        _dismissKeyboard();
                      } else {
                        _focusTerminal();
                      }
                    }
                  },
                  child: AbsorbPointer(
                    absorbing: _useInputBar,
                    child: TerminalView(
                      _shells[_activeIndex].terminal,
                      focusNode: _shells[_activeIndex].focusNode,
                      textStyle: TerminalStyle(
                        fontSize: fontSize,
                        fontFamily: 'monospace',
                      ),
                      theme: t.toTerminalTheme(),
                      autofocus: false,
                      keyboardType: TextInputType.text,
                      deleteDetection: true,
                    ),
                  ),
                ),
        ),
        // Command input bar (line mode)
        if (_useInputBar) _buildInputBar(t),
        // Special keys toolbar
        _buildKeyToolbar(t, isLandscape),
      ],
    );
  }

  Widget _buildTabBar(AppThemeData t) {
    return Container(
      height: 36,
      color: t.bgSecondary,
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _shells.length,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              itemBuilder: (ctx, i) {
                final active = i == _activeIndex;
                return GestureDetector(
                  onTap: () => setState(() => _activeIndex = i),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: active ? t.bgPrimary : Colors.transparent,
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Shell ${_shells[i].id}',
                          style: TextStyle(
                            fontSize: 12,
                            color: active ? t.accent : t.textMuted,
                          ),
                        ),
                        if (_shells.length > 1) ...[
                          const SizedBox(width: 6),
                          GestureDetector(
                            onTap: () => _closeShell(i),
                            child: Icon(Icons.close, size: 14,
                              color: active ? t.textMuted : t.textMuted.withOpacity(0.5)),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          // Font size controls
          InkWell(
            onTap: () => context.read<ThemeService>().setTerminalFontSize(
              context.read<ThemeService>().terminalFontSize - 1,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Icon(Icons.text_decrease, size: 16, color: t.textMuted),
            ),
          ),
          InkWell(
            onTap: () => context.read<ThemeService>().setTerminalFontSize(
              context.read<ThemeService>().terminalFontSize + 1,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Icon(Icons.text_increase, size: 16, color: t.textMuted),
            ),
          ),
          const SizedBox(width: 4),
          // Input mode toggle
          InkWell(
            onTap: () => setState(() => _useInputBar = !_useInputBar),
            child: Tooltip(
              message: _useInputBar ? 'Switch to raw keyboard' : 'Switch to input bar',
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Icon(
                  _useInputBar ? Icons.keyboard : Icons.text_fields,
                  size: 18,
                  color: t.accent,
                ),
              ),
            ),
          ),
          InkWell(
            onTap: _createShell,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Icon(Icons.add, size: 18, color: t.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar(AppThemeData t) {
    return Container(
      color: t.bgSecondary,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Text('\$', style: TextStyle(color: t.accent, fontSize: 16, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _inputCtrl,
              focusNode: _inputFocusNode,
              style: TextStyle(color: t.textPrimary, fontSize: 14, fontFamily: 'monospace'),
              decoration: InputDecoration(
                hintText: 'Type command...',
                hintStyle: TextStyle(color: t.textMuted.withOpacity(0.5)),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
              textInputAction: TextInputAction.send,
              onSubmitted: (_) {
                _sendCommand();
                _inputFocusNode.requestFocus();
              },
            ),
          ),
          const SizedBox(width: 4),
          Material(
            color: t.accent,
            borderRadius: BorderRadius.circular(6),
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: _sendCommand,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Icon(Icons.send, size: 18, color: t.bgPrimary),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildKeyToolbar(AppThemeData t, bool isLandscape) {
    // In landscape, use a more compact layout
    final buttonHeight = isLandscape ? 30.0 : 36.0;
    final fontSize = isLandscape ? 10.0 : 12.0;
    final iconSize = isLandscape ? 14.0 : 16.0;
    final vPad = isLandscape ? 3.0 : 6.0;

    return Container(
      color: t.bgSecondary,
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(horizontal: 4, vertical: vPad),
          child: Row(
            children: [
              _iconBtn(t, Icons.keyboard_hide, _dismissKeyboard, highlight: true, h: buttonHeight, iconSz: iconSize),
              _iconBtn(t, Icons.content_paste, _pasteClipboard, highlight: true, h: buttonHeight, iconSz: iconSize),
              _kbButton(t, 'ENTER', '\r', highlight: true, h: buttonHeight, fs: fontSize),
              _arrowButton(t, Icons.backspace_outlined, '\x7f', h: buttonHeight, iconSz: iconSize),
              _kbButton(t, 'TAB', '\t', h: buttonHeight, fs: fontSize),
              _kbButton(t, 'ESC', '\x1b', h: buttonHeight, fs: fontSize),
              _kbButton(t, '^C', '\x03', h: buttonHeight, fs: fontSize),
              _kbButton(t, '^D', '\x04', h: buttonHeight, fs: fontSize),
              _kbButton(t, '^Z', '\x1a', h: buttonHeight, fs: fontSize),
              _kbButton(t, '^L', '\x0c', h: buttonHeight, fs: fontSize),
              _arrowButton(t, Icons.arrow_upward, '\x1b[A', h: buttonHeight, iconSz: iconSize),
              _arrowButton(t, Icons.arrow_downward, '\x1b[B', h: buttonHeight, iconSz: iconSize),
              _arrowButton(t, Icons.arrow_back, '\x1b[D', h: buttonHeight, iconSz: iconSize),
              _arrowButton(t, Icons.arrow_forward, '\x1b[C', h: buttonHeight, iconSz: iconSize),
              _kbButton(t, 'HOME', '\x1b[H', h: buttonHeight, fs: fontSize),
              _kbButton(t, 'END', '\x1b[F', h: buttonHeight, fs: fontSize),
              _kbButton(t, 'PGUP', '\x1b[5~', h: buttonHeight, fs: fontSize),
              _kbButton(t, 'PGDN', '\x1b[6~', h: buttonHeight, fs: fontSize),
              _kbButton(t, 'DEL', '\x1b[3~', h: buttonHeight, fs: fontSize),
              _kbButton(t, '|', '|', h: buttonHeight, fs: fontSize),
              _kbButton(t, '/', '/', h: buttonHeight, fs: fontSize),
              _kbButton(t, '-', '-', h: buttonHeight, fs: fontSize),
              _kbButton(t, '~', '~', h: buttonHeight, fs: fontSize),
              _kbButton(t, '_', '_', h: buttonHeight, fs: fontSize),
              _kbButton(t, '\\', '\\', h: buttonHeight, fs: fontSize),
            ],
          ),
        ),
      ),
    );
  }

  Widget _kbButton(AppThemeData t, String label, String data, {bool highlight = false, double h = 36, double fs = 12}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: highlight ? t.accent.withOpacity(0.2) : t.bgTertiary,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => _sendKey(data),
          child: Container(
            constraints: BoxConstraints(minWidth: 40, minHeight: h),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                color: highlight ? t.accent : t.textPrimary,
                fontSize: fs,
                fontFamily: 'monospace',
                fontWeight: highlight ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _arrowButton(AppThemeData t, IconData icon, String data, {double h = 36, double iconSz = 16}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: t.bgTertiary,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => _sendKey(data),
          child: Container(
            constraints: BoxConstraints(minWidth: 40, minHeight: h),
            alignment: Alignment.center,
            child: Icon(icon, size: iconSz, color: t.textPrimary),
          ),
        ),
      ),
    );
  }

  Widget _iconBtn(AppThemeData t, IconData icon, VoidCallback onTap, {bool highlight = false, double h = 36, double iconSz = 18}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: highlight ? t.accent.withOpacity(0.2) : t.bgTertiary,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Container(
            constraints: BoxConstraints(minWidth: 40, minHeight: h),
            alignment: Alignment.center,
            child: Icon(icon, size: iconSz, color: highlight ? t.accent : t.textPrimary),
          ),
        ),
      ),
    );
  }
}
