import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import '../services/download_registry.dart';
import '../services/theme_service.dart';

/// Bottom sheet listing files previously downloaded into the app's documents
/// directory, with open and delete actions.
class DownloadsSheet extends StatefulWidget {
  const DownloadsSheet({super.key});

  @override
  State<DownloadsSheet> createState() => _DownloadsSheetState();
}

class _DownloadsSheetState extends State<DownloadsSheet> {
  List<FileSystemEntity>? _files;

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  Future<void> _loadFiles() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => !f.path.split('/').last.startsWith('.'))
          // Hide files still being written: opening a partial download or
          // deleting it out from under the transfer would both misbehave.
          .where((f) => !DownloadRegistry.isActive(f.path))
          .toList()
        ..sort((a, b) =>
            b.statSync().modified.compareTo(a.statSync().modified));
      if (mounted) setState(() => _files = files);
    } catch (_) {
      if (mounted) setState(() => _files = const []);
    }
  }

  Future<void> _delete(File file) async {
    final name = file.path.split('/').last;
    try {
      await file.delete();
    } catch (_) {}
    await _loadFiles();
    if (mounted) {
      final t = context.read<ThemeService>().current;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
            SnackBar(content: Text('Deleted $name'), backgroundColor: t.bgTertiary));
    }
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    var i = 0;
    var val = bytes.toDouble();
    while (val >= 1024 && i < units.length - 1) {
      val /= 1024;
      i++;
    }
    return '${val.toStringAsFixed(i > 0 ? 1 : 0)} ${units[i]}';
  }

  @override
  Widget build(BuildContext context) {
    final t = context.watch<ThemeService>().current;
    final files = _files;
    return Container(
      decoration: BoxDecoration(
        color: t.bgSecondary,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      constraints:
          BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: t.textMuted, borderRadius: BorderRadius.circular(2))),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(Icons.download_done, size: 18, color: t.accent),
                const SizedBox(width: 8),
                Text('DOWNLOADED FILES',
                    style: TextStyle(
                        color: t.textPrimary,
                        fontSize: 13,
                        letterSpacing: 0.5,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          Divider(height: 1, color: t.border),
          Flexible(
            child: files == null
                ? Padding(
                    padding: const EdgeInsets.all(32),
                    child: CircularProgressIndicator(color: t.accent))
                : files.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text('No downloaded files yet',
                            style:
                                TextStyle(color: t.textMuted, fontSize: 13)))
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: files.length,
                        itemBuilder: (ctx, i) {
                          final file = files[i] as File;
                          final name = file.path.split('/').last;
                          final stat = file.statSync();
                          return ListTile(
                            dense: true,
                            leading: Icon(Icons.insert_drive_file,
                                size: 20, color: t.textMuted),
                            title: Text(name,
                                style: TextStyle(
                                    color: t.textPrimary, fontSize: 13),
                                overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                                '${_formatSize(stat.size)} · ${stat.modified.toLocal().toString().substring(0, 16)}',
                                style: TextStyle(
                                    color: t.textMuted, fontSize: 11)),
                            trailing: IconButton(
                              icon: Icon(Icons.delete_outline,
                                  size: 18, color: t.danger),
                              onPressed: () => _delete(file),
                            ),
                            onTap: () => OpenFile.open(file.path),
                          );
                        },
                      ),
          ),
          const SafeArea(top: false, child: SizedBox(height: 4)),
        ],
      ),
    );
  }
}
