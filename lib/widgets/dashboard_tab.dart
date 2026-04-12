import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/ws_service.dart';
import '../theme.dart';

class DashboardTab extends StatefulWidget {
  const DashboardTab({super.key});

  @override
  State<DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends State<DashboardTab>
    with AutomaticKeepAliveClientMixin {
  late WsService _ws;
  Timer? _pollTimer;
  Map<String, dynamic>? _data;
  int? _prevBytesSent;
  int? _prevBytesRecv;
  DateTime? _prevNetTime;

  late void Function(Map<String, dynamic>) _handler;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _ws = context.read<WsService>();
    _handler = (msg) {
      if (mounted) setState(() => _data = msg['payload'] as Map<String, dynamic>?);
    };
    _ws.on('sysinfo_res', _handler);
    _startPolling();
  }

  void _startPolling() {
    _ws.send('sysinfo_req');
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _ws.send('sysinfo_req');
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _ws.off('sysinfo_res', _handler);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_data == null) {
      return const Center(
        child: CircularProgressIndicator(color: TokyoNight.accent),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _buildSystemCard(),
        const SizedBox(height: 10),
        _buildCpuCard(),
        const SizedBox(height: 10),
        _buildMemoryCard(),
        const SizedBox(height: 10),
        _buildDiskCard(),
        const SizedBox(height: 10),
        _buildNetworkCard(),
        if (_data!['gpu'] != null && (_data!['gpu'] as List).isNotEmpty) ...[
          const SizedBox(height: 10),
          ..._buildGpuCards(),
        ],
      ],
    );
  }

  Widget _card(String title, Widget content) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TokyoNight.bgSecondary,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: TokyoNight.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: const TextStyle(
              color: TokyoNight.textMuted,
              fontSize: 11,
              letterSpacing: 0.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          content,
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: TokyoNight.textMuted, fontSize: 13)),
          Text(value,
              style: const TextStyle(
                  color: TokyoNight.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  Widget _progressBar(double percent, {Color? color}) {
    final c = color ??
        (percent > 80
            ? TokyoNight.danger
            : percent > 60
                ? TokyoNight.warning
                : TokyoNight.accent);
    return Container(
      height: 8,
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        color: TokyoNight.bgPrimary,
        borderRadius: BorderRadius.circular(4),
      ),
      child: FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: (percent / 100).clamp(0, 1),
        child: Container(
          decoration: BoxDecoration(
            color: c,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      ),
    );
  }

  Widget _buildSystemCard() {
    final d = _data!;
    String uptime = '';
    if (d['uptime'] != null) {
      final s = (d['uptime'] as num).toInt();
      final days = s ~/ 86400;
      final hours = (s % 86400) ~/ 3600;
      final mins = (s % 3600) ~/ 60;
      final parts = <String>[];
      if (days > 0) parts.add('${days}d');
      if (hours > 0) parts.add('${hours}h');
      parts.add('${mins}m');
      uptime = parts.join(' ');
    }
    return _card(
      'System',
      Column(
        children: [
          _infoRow('Hostname', d['hostname']?.toString() ?? '-'),
          _infoRow('Platform', d['platform']?.toString() ?? '-'),
          if (uptime.isNotEmpty) _infoRow('Uptime', uptime),
          if (d['battery'] != null)
            _infoRow(
              'Battery',
              '${d['battery']['percent']}%${d['battery']['plugged'] == true ? ' (plugged)' : ''}',
            ),
        ],
      ),
    );
  }

  Widget _buildCpuCard() {
    final cpuPercent = (_data!['cpu_percent'] as List<dynamic>?)
            ?.map((e) => (e as num).toDouble())
            .toList() ??
        [];
    final avg = cpuPercent.isEmpty
        ? 0.0
        : cpuPercent.reduce((a, b) => a + b) / cpuPercent.length;
    final cores = _data!['cpu_count'] ?? cpuPercent.length;

    return _card(
      'CPU ($cores cores) - ${avg.toStringAsFixed(1)}%',
      SizedBox(
        height: 60,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: cpuPercent.map((pct) {
            final color = pct > 80
                ? TokyoNight.danger
                : pct > 50
                    ? TokyoNight.warning
                    : TokyoNight.accent;
            return Expanded(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 1),
                height: (pct / 100 * 60).clamp(2, 60),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(2)),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildMemoryCard() {
    final mem = _data!['mem'] as Map<String, dynamic>? ?? {};
    final percent = (mem['percent'] as num?)?.toDouble() ?? 0;
    return _card(
      'Memory',
      Column(
        children: [
          _infoRow(
            'Used / Total',
            '${_formatBytes(mem['used'])} / ${_formatBytes(mem['total'])}',
          ),
          _progressBar(percent),
          const SizedBox(height: 4),
          _infoRow('${percent.toStringAsFixed(1)}% used',
              '${_formatBytes(mem['available'])} free'),
        ],
      ),
    );
  }

  Widget _buildDiskCard() {
    final disks = (_data!['disk'] as List<dynamic>?) ?? [];
    return _card(
      'Disk',
      Column(
        children: disks.map<Widget>((d) {
          final percent = (d['percent'] as num?)?.toDouble() ?? 0;
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
              children: [
                _infoRow(
                  d['mountpoint']?.toString() ?? '/',
                  '${_formatBytes(d['used'])} / ${_formatBytes(d['total'])}',
                ),
                _progressBar(percent),
                _infoRow('${percent.toStringAsFixed(0)}%',
                    d['fstype']?.toString() ?? ''),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildNetworkCard() {
    final net = _data!['net'] as Map<String, dynamic>? ?? {};
    final now = DateTime.now();
    String upSpeed = '';
    String downSpeed = '';

    if (_prevBytesSent != null && _prevNetTime != null) {
      final dt = now.difference(_prevNetTime!).inMilliseconds / 1000;
      if (dt > 0) {
        final up = ((net['bytes_sent'] as num? ?? 0).toInt() - _prevBytesSent!) / dt;
        final down = ((net['bytes_recv'] as num? ?? 0).toInt() - _prevBytesRecv!) / dt;
        upSpeed = '${_formatBytes(up.toInt())}/s';
        downSpeed = '${_formatBytes(down.toInt())}/s';
      }
    }
    _prevBytesSent = (net['bytes_sent'] as num?)?.toInt();
    _prevBytesRecv = (net['bytes_recv'] as num?)?.toInt();
    _prevNetTime = now;

    return _card(
      'Network',
      Column(
        children: [
          _infoRow('Total Sent', _formatBytes(net['bytes_sent'])),
          _infoRow('Total Received', _formatBytes(net['bytes_recv'])),
          if (upSpeed.isNotEmpty) _infoRow('Upload', upSpeed),
          if (downSpeed.isNotEmpty) _infoRow('Download', downSpeed),
        ],
      ),
    );
  }

  List<Widget> _buildGpuCards() {
    final gpus = (_data!['gpu'] as List<dynamic>?) ?? [];
    return gpus.map<Widget>((g) {
      final gpuUtil = (g['gpu_util'] as num?)?.toDouble() ?? 0;
      final memPercent = (g['mem_percent'] as num?)?.toDouble() ?? 0;
      final temp = (g['temp'] as num?)?.toDouble() ?? 0;
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: _card(
          'GPU ${g['index']}: ${g['name']}',
          Column(
            children: [
              _infoRow('GPU Usage', '${gpuUtil.toStringAsFixed(0)}%'),
              _progressBar(gpuUtil),
              const SizedBox(height: 8),
              _infoRow('VRAM', '${g['mem_used']} / ${g['mem_total']} MB'),
              _progressBar(memPercent),
              const SizedBox(height: 8),
              _infoRow('Temperature', '${temp.toStringAsFixed(0)} C'),
              _progressBar(temp.clamp(0, 100)),
              if ((g['fan_speed'] as num?)?.toInt() != null &&
                  (g['fan_speed'] as num).toInt() > 0)
                _infoRow('Fan', '${g['fan_speed']}%'),
              if ((g['power_draw'] as num?)?.toDouble() != null &&
                  (g['power_draw'] as num).toDouble() > 0)
                _infoRow('Power', '${g['power_draw']}W / ${g['power_limit']}W'),
            ],
          ),
        ),
      );
    }).toList();
  }

  String _formatBytes(dynamic bytes) {
    if (bytes == null) return '0 B';
    final b = (bytes as num).toInt();
    if (b == 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    int i = 0;
    double val = b.toDouble();
    while (val >= 1024 && i < units.length - 1) {
      val /= 1024;
      i++;
    }
    return '${val.toStringAsFixed(i > 0 ? 1 : 0)} ${units[i]}';
  }
}
