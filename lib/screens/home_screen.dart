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

class _HomeScreenState extends State<HomeScreen> {
  int _currentTab = 0;
  bool _agentOnline = false;
  bool _wsConnected = false;

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
    WidgetsBinding.instance.addPostFrameCallback((_) => _connectWs());
  }

  void _connectWs() {
    final auth = context.read<AuthService>();
    final ws = context.read<WsService>();

    ws.on('_connected', (_) {
      if (mounted) setState(() => _wsConnected = true);
    });
    ws.on('_disconnected', (_) {
      if (mounted) {
        setState(() {
          _wsConnected = false;
          _agentOnline = false;
        });
      }
    });
    ws.on('agent_status', (msg) {
      if (mounted) {
        setState(() => _agentOnline = msg['payload']?['online'] == true);
      }
    });
    ws.on('error', (msg) {
      if (mounted) {
        final t = context.read<ThemeService>().current;
        final message = msg['payload']?['message'] ?? 'Error';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message.toString()),
            backgroundColor: t.danger,
          ),
        );
      }
    });

    ws.connect(auth.wsUrl);
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
      body: IndexedStack(
        index: _currentTab,
        children: const [
          TerminalTab(),
          FilesTab(),
          DashboardTab(),
          ScreenTab(),
        ],
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
  void dispose() {
    final ws = context.read<WsService>();
    ws.off('_connected');
    ws.off('_disconnected');
    ws.off('agent_status');
    ws.off('error');
    super.dispose();
  }
}
