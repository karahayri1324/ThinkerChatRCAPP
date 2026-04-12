
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';
import '../services/ws_service.dart';
import '../theme.dart';

class _ShellEntry {
  final String id;
  final Terminal terminal;
  _ShellEntry(this.id, this.terminal);
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

  @override
  void initState() {
    super.initState();
    _ws = context.read<WsService>();
    _outputHandler = (msg) {
      final payload = msg['payload'] as Map<String, dynamic>? ?? {};
      final shellId = payload['shell_id']?.toString() ?? '1';
      final data = payload['data'] as String? ?? '';
      final entry = _shells.where((s) => s.id == shellId).firstOrNull;
      if (entry != null) {
        entry.terminal.write(data);
      }
    };
    _ws.on('shell_output', _outputHandler);
    _createShell();
  }

  void _createShell() {
    final shellId = '${_nextId++}';
    final terminal = Terminal(
      maxLines: 5000,
    );

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

    _ws.send('shell_create', {'shell_id': shellId});

    setState(() {
      _shells.add(_ShellEntry(shellId, terminal));
      _activeIndex = _shells.length - 1;
    });
  }

  void _closeShell(int index) {
    if (_shells.length <= 1) return;
    final entry = _shells[index];
    _ws.send('shell_close', {'shell_id': entry.id});
    setState(() {
      _shells.removeAt(index);
      if (_activeIndex >= _shells.length) {
        _activeIndex = _shells.length - 1;
      }
    });
  }

  void _sendKey(String data) {
    if (_shells.isEmpty) return;
    final shellId = _shells[_activeIndex].id;
    _ws.send('shell_input', {'shell_id': shellId, 'data': data});
  }

  @override
  void dispose() {
    _ws.off('shell_output', _outputHandler);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Tab bar
        Container(
          height: 36,
          color: TokyoNight.bgSecondary,
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
                          color: active
                              ? TokyoNight.bgPrimary
                              : Colors.transparent,
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(4),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _shells[i].id,
                              style: TextStyle(
                                fontSize: 12,
                                color: active
                                    ? TokyoNight.accent
                                    : TokyoNight.textMuted,
                              ),
                            ),
                            if (_shells.length > 1) ...[
                              const SizedBox(width: 6),
                              GestureDetector(
                                onTap: () => _closeShell(i),
                                child: Icon(
                                  Icons.close,
                                  size: 14,
                                  color: active
                                      ? TokyoNight.textMuted
                                      : TokyoNight.textMuted.withOpacity(0.5),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              InkWell(
                onTap: _createShell,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Icon(Icons.add, size: 18, color: TokyoNight.textMuted),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: TokyoNight.border),
        // Terminal view
        Expanded(
          child: _shells.isEmpty
              ? const SizedBox.shrink()
              : TerminalView(
                  _shells[_activeIndex].terminal,
                  textStyle: const TerminalStyle(
                    fontSize: 13,
                    fontFamily: 'monospace',
                  ),
                  theme: const TerminalTheme(
                    cursor: TokyoNight.textPrimary,
                    selection: Color(0xFF33467c),
                    foreground: TokyoNight.textSecondary,
                    background: TokyoNight.bgPrimary,
                    black: TokyoNight.termBlack,
                    red: TokyoNight.termRed,
                    green: TokyoNight.termGreen,
                    yellow: TokyoNight.termYellow,
                    blue: TokyoNight.termBlue,
                    magenta: TokyoNight.termMagenta,
                    cyan: TokyoNight.termCyan,
                    white: TokyoNight.termWhite,
                    brightBlack: TokyoNight.termBrightBlack,
                    brightRed: TokyoNight.termRed,
                    brightGreen: TokyoNight.termGreen,
                    brightYellow: TokyoNight.termYellow,
                    brightBlue: TokyoNight.termBlue,
                    brightMagenta: TokyoNight.termMagenta,
                    brightCyan: TokyoNight.termCyan,
                    brightWhite: TokyoNight.termBrightWhite,
                    searchHitBackground: TokyoNight.accent,
                    searchHitBackgroundCurrent: TokyoNight.warning,
                    searchHitForeground: TokyoNight.bgPrimary,
                  ),
                  autofocus: true,
                ),
        ),
        // Keyboard helper bar
        Container(
          color: TokyoNight.bgSecondary,
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Row(
                children: [
                  _kbButton('ESC', '\x1b'),
                  _kbButton('TAB', '\t'),
                  _kbButton('^C', '\x03'),
                  _kbButton('^D', '\x04'),
                  _kbButton('^Z', '\x1a'),
                  _kbButton('^L', '\x0c'),
                  _arrowButton(Icons.arrow_upward, '\x1b[A'),
                  _arrowButton(Icons.arrow_downward, '\x1b[B'),
                  _arrowButton(Icons.arrow_back, '\x1b[D'),
                  _arrowButton(Icons.arrow_forward, '\x1b[C'),
                  _kbButton('|', '|'),
                  _kbButton('/', '/'),
                  _kbButton('-', '-'),
                  _kbButton('~', '~'),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _kbButton(String label, String data) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: TokyoNight.bgTertiary,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => _sendKey(data),
          child: Container(
            constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            child: Text(
              label,
              style: const TextStyle(
                color: TokyoNight.textPrimary,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _arrowButton(IconData icon, String data) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: TokyoNight.bgTertiary,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => _sendKey(data),
          child: Container(
            constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
            alignment: Alignment.center,
            child: Icon(icon, size: 16, color: TokyoNight.textPrimary),
          ),
        ),
      ),
    );
  }
}
