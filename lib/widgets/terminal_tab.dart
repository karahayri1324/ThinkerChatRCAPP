import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';
import '../services/ws_service.dart';
import '../services/theme_service.dart';
import '../services/terminal_history_service.dart';

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
        // Save to history in background
        TerminalHistoryService.saveOutput(shellId, data);
      }
    };
    _ws.on('shell_output', _outputHandler);
    _createShell();
  }

  Future<void> _createShell() async {
    final shellId = '${_nextId++}';
    final terminal = Terminal(maxLines: 5000);

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

    // Restore previous history if exists
    final savedHistory = await TerminalHistoryService.getOutput(shellId);
    if (savedHistory != null && savedHistory.isNotEmpty) {
      terminal.write(savedHistory);
      terminal.write('\r\n--- Session restored ---\r\n');
    }

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
    HapticFeedback.lightImpact();
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
    final t = context.watch<ThemeService>().current;
    return Column(
      children: [
        // Tab bar
        Container(
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
                                color: active ? t.accent : t.textMuted,
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
                                      ? t.textMuted
                                      : t.textMuted.withOpacity(0.5),
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
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Icon(Icons.add, size: 18, color: t.textMuted),
                ),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: t.border),
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
                  theme: t.toTerminalTheme(),
                  autofocus: true,
                ),
        ),
        // Keyboard helper bar
        Container(
          color: t.bgSecondary,
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Row(
                children: [
                  _kbButton(t, 'ESC', '\x1b'),
                  _kbButton(t, 'TAB', '\t'),
                  _kbButton(t, '^C', '\x03'),
                  _kbButton(t, '^D', '\x04'),
                  _kbButton(t, '^Z', '\x1a'),
                  _kbButton(t, '^L', '\x0c'),
                  _arrowButton(t, Icons.arrow_upward, '\x1b[A'),
                  _arrowButton(t, Icons.arrow_downward, '\x1b[B'),
                  _arrowButton(t, Icons.arrow_back, '\x1b[D'),
                  _arrowButton(t, Icons.arrow_forward, '\x1b[C'),
                  _kbButton(t, 'HOME', '\x1b[H'),
                  _kbButton(t, 'END', '\x1b[F'),
                  _kbButton(t, 'PGUP', '\x1b[5~'),
                  _kbButton(t, 'PGDN', '\x1b[6~'),
                  _kbButton(t, 'DEL', '\x1b[3~'),
                  _kbButton(t, 'INS', '\x1b[2~'),
                  _kbButton(t, '|', '|'),
                  _kbButton(t, '/', '/'),
                  _kbButton(t, '-', '-'),
                  _kbButton(t, '~', '~'),
                  _kbButton(t, '_', '_'),
                  _kbButton(t, '\\', '\\'),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _kbButton(AppThemeData t, String label, String data) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: t.bgTertiary,
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
              style: TextStyle(
                color: t.textPrimary,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _arrowButton(AppThemeData t, IconData icon, String data) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: t.bgTertiary,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => _sendKey(data),
          child: Container(
            constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
            alignment: Alignment.center,
            child: Icon(icon, size: 16, color: t.textPrimary),
          ),
        ),
      ),
    );
  }
}
