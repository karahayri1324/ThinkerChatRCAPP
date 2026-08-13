import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/ws_service.dart';
import '../services/theme_service.dart';
import 'connection_banner.dart';
import 'sparkline.dart';

class DashboardTab extends StatefulWidget {
  /// Index of this tab and a listenable of the currently-visible tab index, so
  /// polling can pause while the dashboard is off-screen (IndexedStack keeps it
  /// mounted otherwise). When null, polling always runs.
  final ValueListenable<int>? activeTab;
  final int tabIndex;
  const DashboardTab({super.key, this.activeTab, this.tabIndex = 2});

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
  String _upSpeed = '';
  String _downSpeed = '';

  // Rolling history for the sparklines (~2.5 minutes at the 3 s poll rate).
  static const _historyLength = 50;
  final List<double> _cpuHistory = [];
  final List<double> _memHistory = [];
  final List<double> _netUpHistory = [];
  final List<double> _netDownHistory = [];
  DateTime? _lastSampleAt;

  static void _push(List<double> series, double value) {
    series.add(value);
    if (series.length > _historyLength) {
      series.removeRange(0, series.length - _historyLength);
    }
  }

  @override
  bool get wantKeepAlive => true;

  bool get _isVisible =>
      widget.activeTab == null || widget.activeTab!.value == widget.tabIndex;

  @override
  void initState() {
    super.initState();
    _ws = context.read<WsService>();
    _handler = (msg) {
      if (!mounted) return;
      final data = msg['payload'] as Map<String, dynamic>?;
      _updateNetworkSpeed(data);
      _recordHistory(data);
      setState(() {
        _data = data;
        _lastSampleAt = DateTime.now();
      });
    };
    _ws.on('sysinfo_res', _handler);
    widget.activeTab?.addListener(_onVisibilityChanged);
    if (_isVisible) _startPolling();
  }

  void _onVisibilityChanged() {
    if (_isVisible) {
      if (_pollTimer == null) _startPolling();
    } else {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  void _updateNetworkSpeed(Map<String, dynamic>? data) {
    if (data == null) return;
    final net = data['net'] as Map<String, dynamic>? ?? {};
    final now = DateTime.now();
    if (_prevBytesSent != null && _prevBytesRecv != null && _prevNetTime != null) {
      final dt = now.difference(_prevNetTime!).inMilliseconds / 1000;
      final sentDelta = (net['bytes_sent'] as num? ?? 0).toInt() - _prevBytesSent!;
      final recvDelta = (net['bytes_recv'] as num? ?? 0).toInt() - _prevBytesRecv!;
      // Skip on counter resets (negative deltas) which would otherwise render
      // nonsensical speeds like "-500 MB/s".
      if (dt > 0 && sentDelta >= 0 && recvDelta >= 0) {
        final upRate = sentDelta / dt;
        final downRate = recvDelta / dt;
        _upSpeed = '${_formatBytes(upRate.toInt())}/s';
        _downSpeed = '${_formatBytes(downRate.toInt())}/s';
        _push(_netUpHistory, upRate);
        _push(_netDownHistory, downRate);
      }
    }
    _prevBytesSent = (net['bytes_sent'] as num?)?.toInt();
    _prevBytesRecv = (net['bytes_recv'] as num?)?.toInt();
    _prevNetTime = now;
  }

  void _recordHistory(Map<String, dynamic>? data) {
    if (data == null) return;
    final cpu = (data['cpu_percent'] as List<dynamic>?)
            ?.whereType<num>()
            .map((e) => e.toDouble())
            .toList() ??
        const [];
    if (cpu.isNotEmpty) {
      _push(_cpuHistory, cpu.reduce((a, b) => a + b) / cpu.length);
    }
    final memPercent =
        ((data['mem'] as Map<String, dynamic>?)?['percent'] as num?)?.toDouble();
    if (memPercent != null) _push(_memHistory, memPercent);
  }

  /// Highest value in a series, used to label the network sparkline.
  static double _peak(List<double> series) =>
      series.isEmpty ? 0 : series.reduce((a, b) => a > b ? a : b);

  void _startPolling() {
    // Restart the freshness clock: while the tab was off-screen no polls were
    // sent, so the age of the last sample says nothing about the agent's health
    // and would otherwise flash a false "stale" warning on every return here.
    _lastSampleAt = DateTime.now();
    _ws.send('sysinfo_req');
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _ws.send('sysinfo_req');
      // Re-render even without a reply so the staleness notice appears.
      if (mounted && _data != null) setState(() {});
    });
  }

  @override
  void dispose() {
    widget.activeTab?.removeListener(_onVisibilityChanged);
    _pollTimer?.cancel();
    _ws.off('sysinfo_res', _handler);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = context.watch<ThemeService>().current;
    if (_data == null) {
      return const Column(
        children: [
          ConnectionBanner(),
          Expanded(child: Center(child: CircularProgressIndicator())),
        ],
      );
    }
    return Column(
      children: [
        const ConnectionBanner(),
        Expanded(
          child: ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _buildSystemCard(t),
        const SizedBox(height: 10),
        _buildCpuCard(t),
        const SizedBox(height: 10),
        _buildMemoryCard(t),
        const SizedBox(height: 10),
        _buildDiskCard(t),
        const SizedBox(height: 10),
        _buildNetworkCard(t),
        if (_data!['gpu'] != null && (_data!['gpu'] as List).isNotEmpty) ...[
          const SizedBox(height: 10),
          ..._buildGpuCards(t),
        ],
      ],
    )),
      ],
    );
  }

  Widget _card(AppThemeData t, String title, Widget content) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.bgSecondary,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title.toUpperCase(),
              style: TextStyle(color: t.textMuted, fontSize: 11,
                  letterSpacing: 0.5, fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          content,
        ],
      ),
    );
  }

  Widget _infoRow(AppThemeData t, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: t.textMuted, fontSize: 13)),
          Text(value, style: TextStyle(color: t.textPrimary, fontSize: 13, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  Widget _progressBar(AppThemeData t, double percent, {Color? color}) {
    final c = color ?? (percent > 80 ? t.danger : percent > 60 ? t.warning : t.accent);
    return Container(
      height: 8,
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(color: t.bgPrimary, borderRadius: BorderRadius.circular(4)),
      child: FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: (percent / 100).clamp(0, 1),
        child: Container(
          decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(4)),
        ),
      ),
    );
  }

  Widget _buildSystemCard(AppThemeData t) {
    final d = _data!;
    String uptime = '';
    if (d['uptime'] != null) {
      final s = (d['uptime'] as num).toInt();
      final days = s ~/ 86400; final hours = (s % 86400) ~/ 3600; final mins = (s % 3600) ~/ 60;
      final parts = <String>[]; if (days > 0) parts.add('${days}d');
      if (hours > 0) parts.add('${hours}h'); parts.add('${mins}m');
      uptime = parts.join(' ');
    }
    // Poll answers stop arriving silently when the agent goes away; say so
    // instead of leaving the last snapshot looking live.
    final age = _lastSampleAt == null
        ? null
        : DateTime.now().difference(_lastSampleAt!).inSeconds;
    return _card(t, 'System', Column(children: [
      if (age != null && age > 10)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(children: [
            Icon(Icons.update_disabled, size: 13, color: t.warning),
            const SizedBox(width: 6),
            Text('Stale — last update ${age}s ago',
                style: TextStyle(color: t.warning, fontSize: 11)),
          ]),
        ),
      _infoRow(t, 'Hostname', d['hostname']?.toString() ?? '-'),
      _infoRow(t, 'Platform', d['platform']?.toString() ?? '-'),
      if (uptime.isNotEmpty) _infoRow(t, 'Uptime', uptime),
      if (d['battery'] is Map)
        _infoRow(t, 'Battery',
            '${(d['battery'] as Map)['percent'] ?? '?'}%${(d['battery'] as Map)['plugged'] == true ? ' (plugged)' : ''}'),
    ]));
  }

  Widget _buildCpuCard(AppThemeData t) {
    final cpuPercent = (_data!['cpu_percent'] as List<dynamic>?)?.map((e) => (e as num).toDouble()).toList() ?? [];
    final avg = cpuPercent.isEmpty ? 0.0 : cpuPercent.reduce((a, b) => a + b) / cpuPercent.length;
    final cores = _data!['cpu_count'] ?? cpuPercent.length;
    final avgColor = avg > 80 ? t.danger : avg > 50 ? t.warning : t.accent;
    return _card(t, 'CPU ($cores cores) - ${avg.toStringAsFixed(1)}%',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: 60, child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: cpuPercent.map((pct) {
              final color = pct > 80 ? t.danger : pct > 50 ? t.warning : t.accent;
              return Expanded(child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 1),
                height: (pct / 100 * 60).clamp(2, 60),
                decoration: BoxDecoration(color: color, borderRadius: const BorderRadius.vertical(top: Radius.circular(2))),
              ));
            }).toList(),
          )),
          if (_cpuHistory.length > 1) ...[
            const SizedBox(height: 10),
            // Sample count, not elapsed time: polling pauses while the tab is
            // off-screen, so the series is not a contiguous 3 s timeline.
            _historyLabel(t, 'Average, last ${_cpuHistory.length} samples',
                'peak ${_peak(_cpuHistory).toStringAsFixed(0)}%'),
            const SizedBox(height: 2),
            Sparkline(values: _cpuHistory, maxY: 100, color: avgColor),
          ],
        ],
      ),
    );
  }

  Widget _historyLabel(AppThemeData t, String left, String right) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(left, style: TextStyle(color: t.textMuted, fontSize: 10)),
        Text(right, style: TextStyle(color: t.textMuted, fontSize: 10)),
      ],
    );
  }

  Widget _buildMemoryCard(AppThemeData t) {
    final mem = _data!['mem'] as Map<String, dynamic>? ?? {};
    final percent = (mem['percent'] as num?)?.toDouble() ?? 0;
    final memColor = percent > 80 ? t.danger : percent > 60 ? t.warning : t.accent;
    return _card(t, 'Memory', Column(children: [
      _infoRow(t, 'Used / Total', '${_formatBytes(mem['used'])} / ${_formatBytes(mem['total'])}'),
      _progressBar(t, percent),
      const SizedBox(height: 4),
      _infoRow(t, '${percent.toStringAsFixed(1)}% used', '${_formatBytes(mem['available'])} free'),
      if (_memHistory.length > 1) ...[
        const SizedBox(height: 8),
        _historyLabel(t, 'Last ${_memHistory.length} samples',
            'peak ${_peak(_memHistory).toStringAsFixed(0)}%'),
        const SizedBox(height: 2),
        Sparkline(values: _memHistory, maxY: 100, color: memColor),
      ],
    ]));
  }

  Widget _buildDiskCard(AppThemeData t) {
    final disks = (_data!['disk'] as List<dynamic>?) ?? [];
    return _card(t, 'Disk', Column(children: disks.map<Widget>((d) {
      final percent = (d['percent'] as num?)?.toDouble() ?? 0;
      return Padding(padding: const EdgeInsets.only(bottom: 10), child: Column(children: [
        _infoRow(t, d['mountpoint']?.toString() ?? '/', '${_formatBytes(d['used'])} / ${_formatBytes(d['total'])}'),
        _progressBar(t, percent),
        _infoRow(t, '${percent.toStringAsFixed(0)}%', d['fstype']?.toString() ?? ''),
      ]));
    }).toList()));
  }

  Widget _buildNetworkCard(AppThemeData t) {
    final net = _data!['net'] as Map<String, dynamic>? ?? {};
    // Both charts share one y-scale so the lines stay visually comparable, but
    // each is labelled with its OWN peak — labelling the download chart with a
    // shared maximum would report an upload spike as a download one.
    final upPeak = _peak(_netUpHistory);
    final downPeak = _peak(_netDownHistory);
    final netMax = upPeak > downPeak ? upPeak : downPeak;
    return _card(t, 'Network', Column(children: [
      _infoRow(t, 'Total Sent', _formatBytes(net['bytes_sent'])),
      _infoRow(t, 'Total Received', _formatBytes(net['bytes_recv'])),
      if (_upSpeed.isNotEmpty) _infoRow(t, 'Upload', _upSpeed),
      if (_downSpeed.isNotEmpty) _infoRow(t, 'Download', _downSpeed),
      if (_netDownHistory.length > 1) ...[
        const SizedBox(height: 8),
        _historyLabel(t, 'Download',
            'peak ${_formatBytes(downPeak.toInt())}/s'),
        const SizedBox(height: 2),
        Sparkline(
            values: _netDownHistory,
            maxY: netMax > 0 ? netMax : null,
            color: t.success,
            height: 28),
        const SizedBox(height: 6),
        _historyLabel(t, 'Upload', 'peak ${_formatBytes(upPeak.toInt())}/s'),
        const SizedBox(height: 2),
        Sparkline(
            values: _netUpHistory,
            maxY: netMax > 0 ? netMax : null,
            color: t.warning,
            height: 28),
      ],
    ]));
  }

  List<Widget> _buildGpuCards(AppThemeData t) {
    final gpus = (_data!['gpu'] as List<dynamic>?) ?? [];
    return gpus.map<Widget>((g) {
      final gpuUtil = (g['gpu_util'] as num?)?.toDouble() ?? 0;
      final memPercent = (g['mem_percent'] as num?)?.toDouble() ?? 0;
      final temp = (g['temp'] as num?)?.toDouble() ?? 0;
      return Padding(padding: const EdgeInsets.only(bottom: 10), child: _card(t, 'GPU ${g['index'] ?? '?'}: ${g['name'] ?? 'Unknown'}',
        Column(children: [
          _infoRow(t, 'GPU Usage', '${gpuUtil.toStringAsFixed(0)}%'), _progressBar(t, gpuUtil),
          const SizedBox(height: 8),
          _infoRow(t, 'VRAM', '${g['mem_used']} / ${g['mem_total']} MB'), _progressBar(t, memPercent),
          const SizedBox(height: 8),
          _infoRow(t, 'Temperature', '${temp.toStringAsFixed(0)} C'), _progressBar(t, temp.clamp(0, 100)),
          if ((g['fan_speed'] as num?)?.toInt() != null && (g['fan_speed'] as num).toInt() > 0)
            _infoRow(t, 'Fan', '${g['fan_speed']}%'),
          if ((g['power_draw'] as num?)?.toDouble() != null && (g['power_draw'] as num).toDouble() > 0)
            _infoRow(t, 'Power', '${g['power_draw']}W / ${g['power_limit']}W'),
        ]),
      ));
    }).toList();
  }

  String _formatBytes(dynamic bytes) {
    if (bytes == null) return '0 B';
    final b = (bytes as num).toInt(); if (b == 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    int i = 0; double val = b.toDouble();
    while (val >= 1024 && i < units.length - 1) { val /= 1024; i++; }
    return '${val.toStringAsFixed(i > 0 ? 1 : 0)} ${units[i]}';
  }
}
