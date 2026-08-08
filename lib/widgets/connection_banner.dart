import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/ws_service.dart';
import '../services/theme_service.dart';

/// A small banner that shows when WebSocket is disconnected, with the current
/// retry attempt and a "Retry now" action that skips the backoff wait.
/// Place at the top of any tab's Column.
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WsService>();
    if (ws.connected) return const SizedBox.shrink();

    final t = context.watch<ThemeService>().current;
    final attempts = ws.reconnectAttempts;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: t.danger.withOpacity(0.15),
      child: Row(
        children: [
          Icon(Icons.cloud_off, size: 14, color: t.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              attempts > 1
                  ? 'Reconnecting... (attempt $attempts)'
                  : 'Not connected - waiting for server...',
              style: TextStyle(color: t.danger, fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: ws.retryNow,
            style: TextButton.styleFrom(
              foregroundColor: t.danger,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Retry now', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
