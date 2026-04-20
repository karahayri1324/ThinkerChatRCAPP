import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/ws_service.dart';
import '../services/theme_service.dart';
import '../widgets/terminal_tab.dart';
import '../widgets/files_tab.dart';
import '../widgets/dashboard_tab.dart';
import '../widgets/screen_tab.dart';
import '../widgets/settings_sheet.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _currentTab = 0;
  bool _agentOnline = false;
  bool _wsConnected = false;
  late WsService _ws;

  // Store handler references for proper cleanup
  late final void Function(Map<String, dynamic>) _onConnected;
  late final void Function(Map<String, dynamic>) _onDisconnected;
  late final void Function(Map<String, dynamic>) _onAgentStatus;
  late final void Function(Map<String, dynamic>) _onError;

  final _tabLabels = const ['Terminal', 'Files', 'System', 'Screen'];
  final _tabIcons = const [
    Icons.terminal,
    Icons.folder_outlined,
    Icons.monitor_heart_outlined,
    Icons.desktop_windows_outlined,
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _onConnected = (_) {
      if (mounted) setState(() => _wsConnected = true);
    };
    _onDisconnected = (_) {
      if (mounted) setState(() { _wsConnected = false; _agentOnline = false; });
    };
    _onAgentStatus = (msg) {
      if (mounted) setState(() => _agentOnline = msg['payload']?['online'] == true);
    };
    _onError = (msg) {
      if (mounted) {
        final t = context.read<ThemeService>().current;
        final message = msg['payload']?['message'] ?? 'Error';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message.toString()), backgroundColor: t.danger),
        );
      }
    };
    WidgetsBinding.instance.addPostFrameCallback((_) => _connectWs());
  }

  void _connectWs() {
    final auth = context.read<AuthService>();
    _ws = context.read<WsService>();

    _ws.on('_connected', _onConnected);
    _ws.on('_disconnected', _onDisconnected);
    _ws.on('agent_status', _onAgentStatus);
    _ws.on('error', _onError);

    _ws.connect(auth.wsUrl);
  }

  void _logout() {
    final auth = context.read<AuthService>();
    final ws = context.read<WsService>();
    ws.disconnect();
    auth.logout();
    Navigator.pushReplacementNamed(context, '/login');
  }

  void _openSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const SettingsSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.watch<ThemeService>().current;
    final statusColor = _agentOnline
        ? t.success
        : _wsConnected
            ? t.warning
            : t.danger;
    final statusText = _agentOnline
        ? 'Agent Online'
        : _wsConnected
            ? 'Connecting...'
            : 'Offline';

    return Scaffold(
      backgroundColor: t.bgPrimary,
      appBar: AppBar(
        backgroundColor: t.bgSecondary,
        toolbarHeight: 48,
        titleSpacing: 8,
        title: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: statusColor,
                shape: BoxShape.circle,
                boxShadow: _agentOnline
                    ? [BoxShadow(color: statusColor, blurRadius: 6)]
                    : null,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              statusText,
              style: TextStyle(fontSize: 12, color: t.textMuted),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings, size: 20),
            color: t.textMuted,
            onPressed: _openSettings,
          ),
          IconButton(
            icon: const Icon(Icons.logout, size: 20),
            color: t.textMuted,
            onPressed: _logout,
          ),
        ],
      ),
      body: GestureDetector(
        // Disable swipe on Screen tab (index 3) to avoid conflict with InteractiveViewer
        onHorizontalDragEnd: _currentTab == 3 ? null : (details) {
          if (details.primaryVelocity == null) return;
          if (details.primaryVelocity! < -300) {
            if (_currentTab < 3) setState(() => _currentTab++);
          } else if (details.primaryVelocity! > 300) {
            if (_currentTab > 0) setState(() => _currentTab--);
          }
        },
        child: IndexedStack(
          index: _currentTab,
          children: const [
            TerminalTab(),
            FilesTab(),
            DashboardTab(),
            ScreenTab(),
          ],
        ),
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: t.bgSecondary,
          border: Border(top: BorderSide(color: t.border, width: 1)),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: List.generate(4, (i) {
                final active = _currentTab == i;
                return InkWell(
                  onTap: () => setState(() => _currentTab = i),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _tabIcons[i],
                          size: 22,
                          color: active ? t.accent : t.textMuted,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _tabLabels[i],
                          style: TextStyle(
                            fontSize: 10,
                            color: active ? t.accent : t.textMuted,
                            fontWeight:
                                active ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Force reconnect on resume to recover from any stale WS
      // left over from backgrounding or network changes.
      _ws.forceReconnect();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ws.off('_connected', _onConnected);
    _ws.off('_disconnected', _onDisconnected);
    _ws.off('agent_status', _onAgentStatus);
    _ws.off('error', _onError);
    super.dispose();
  }
}
