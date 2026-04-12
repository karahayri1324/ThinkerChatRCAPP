import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_file/open_file.dart';
import 'package:file_picker/file_picker.dart';
import '../services/ws_service.dart';
import '../theme.dart';

class FilesTab extends StatefulWidget {
  const FilesTab({super.key});

  @override
  State<FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends State<FilesTab> {
  late WsService _ws;
  String _currentPath = '/';
  List<Map<String, dynamic>> _entries = [];
  bool _loading = false;
  String? _error;

  // Download state
  final Map<String, _DownloadState> _downloads = {};

  late void Function(Map<String, dynamic>) _listHandler;
  late void Function(Map<String, dynamic>) _downloadHandler;
  late void Function(Map<String, dynamic>) _uploadAckHandler;

  @override
  void initState() {
    super.initState();
    _ws = context.read<WsService>();

    _listHandler = (msg) {
      final payload = msg['payload'] as Map<String, dynamic>? ?? {};
      if (payload['error'] != null) {
        setState(() {
          _error = payload['error'] as String;
          _loading = false;
        });
        return;
      }
      setState(() {
        _currentPath = payload['path'] as String? ?? '/';
        final rawEntries = payload['entries'] as List<dynamic>? ?? [];
        _entries = rawEntries.cast<Map<String, dynamic>>();
        _entries.sort((a, b) {
          if (a['is_dir'] == true && b['is_dir'] != true) return -1;
          if (a['is_dir'] != true && b['is_dir'] == true) return 1;
          return (a['name'] as String).compareTo(b['name'] as String);
        });
        _loading = false;
        _error = null;
      });
    };

    _downloadHandler = (msg) {
      final payload = msg['payload'] as Map<String, dynamic>? ?? {};
      final path = payload['path'] as String? ?? '';
      final dl = _downloads[path];
      if (dl == null) return;

      final chunkIndex = payload['chunk_index'] as int?;
      if (chunkIndex == null) return;
      dl.chunks[chunkIndex] = payload['data'] as String? ?? '';

      if (payload['done'] == true) {
        _finishDownload(path, dl);
      }
    };

    _uploadAckHandler = (msg) {
      final payload = msg['payload'] as Map<String, dynamic>? ?? {};
      if (payload['success'] != true && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Upload error: ${payload['error']}'),
            backgroundColor: TokyoNight.danger,
          ),
        );
      }
    };

    _ws.on('file_list_res', _listHandler);
    _ws.on('file_download_chunk', _downloadHandler);
    _ws.on('file_upload_ack', _uploadAckHandler);

    _navigate(_currentPath);
  }

  void _navigate(String path) {
    setState(() {
      _loading = true;
      _error = null;
    });
    _ws.send('file_list_req', {'path': path});
  }

  Future<void> _finishDownload(String path, _DownloadState dl) async {
    try {
      final sortedKeys = dl.chunks.keys.toList()..sort();
      final combined = sortedKeys.map((k) => dl.chunks[k]!).join('');
      final bytes = base64Decode(combined);
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/${dl.filename}');
      await file.writeAsBytes(bytes);
      _downloads.remove(path);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Downloaded ${dl.filename}'),
            backgroundColor: TokyoNight.success,
            action: SnackBarAction(
              label: 'Open',
              textColor: TokyoNight.bgPrimary,
              onPressed: () => OpenFile.open(file.path),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Download error: $e'),
            backgroundColor: TokyoNight.danger,
          ),
        );
      }
    }
  }

  void _startDownload(String fullPath, String filename) {
    _downloads[fullPath] = _DownloadState(filename);
    _ws.send('file_download_req', {'path': fullPath});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Downloading $filename...'),
        backgroundColor: TokyoNight.bgSecondary,
      ),
    );
  }

  Future<void> _pickAndUpload() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null) return;

    for (final pf in result.files) {
      if (pf.path == null) continue;
      final file = File(pf.path!);
      final bytes = await file.readAsBytes();
      final filename = pf.name;
      final targetPath =
          '${_currentPath == '/' ? '/' : '$_currentPath/'}$filename';
      const chunkSize = 524288;
      final totalChunks = (bytes.length / chunkSize).ceil().clamp(1, 999999);

      _ws.send('file_upload_start', {
        'path': targetPath,
        'total_size': bytes.length,
        'total_chunks': totalChunks,
      });

      for (int i = 0; i < totalChunks; i++) {
        final start = i * chunkSize;
        final end = (start + chunkSize).clamp(0, bytes.length);
        final chunk = bytes.sublist(start, end);
        _ws.send('file_upload_chunk', {
          'path': targetPath,
          'chunk_index': i,
          'data': base64Encode(chunk),
          'done': i == totalChunks - 1,
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Uploaded $filename'),
            backgroundColor: TokyoNight.success,
          ),
        );
      }
    }
    // Refresh after upload
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) _navigate(_currentPath);
    });
  }

  void _showPathDialog() {
    final ctrl = TextEditingController(text: _currentPath);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TokyoNight.bgSecondary,
        title: const Text('Go to path', style: TextStyle(color: TokyoNight.textPrimary)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: TokyoNight.textPrimary, fontFamily: 'monospace'),
          decoration: const InputDecoration(hintText: '/path/to/directory'),
          onSubmitted: (v) {
            Navigator.pop(ctx);
            _navigate(v);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _navigate(ctrl.text);
            },
            child: const Text('Go'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _ws.off('file_list_res', _listHandler);
    _ws.off('file_download_chunk', _downloadHandler);
    _ws.off('file_upload_ack', _uploadAckHandler);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Path toolbar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          color: TokyoNight.bgSecondary,
          child: Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: _showPathDialog,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: TokyoNight.bgPrimary,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: TokyoNight.border),
                    ),
                    child: Text(
                      _currentPath,
                      style: const TextStyle(
                        color: TokyoNight.textPrimary,
                        fontSize: 13,
                        fontFamily: 'monospace',
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Material(
                color: TokyoNight.bgTertiary,
                borderRadius: BorderRadius.circular(6),
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: _pickAndUpload,
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(Icons.upload_file, size: 20, color: TokyoNight.accent),
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: TokyoNight.border),
        // File list
        Expanded(
          child: _loading
              ? const Center(
                  child: CircularProgressIndicator(color: TokyoNight.accent),
                )
              : _error != null
                  ? Center(
                      child: Text(_error!,
                          style: const TextStyle(color: TokyoNight.danger)),
                    )
                  : ListView.builder(
                      itemCount: (_currentPath != '/' ? 1 : 0) + _entries.length,
                      itemBuilder: (ctx, i) {
                        // Parent directory
                        if (_currentPath != '/' && i == 0) {
                          final parentPath = _currentPath
                                  .split('/')
                                  .sublist(
                                      0,
                                      _currentPath.split('/').length - 1)
                                  .join('/');
                          return _buildEntry(
                            name: '..',
                            isDir: true,
                            size: 0,
                            onTap: () =>
                                _navigate(parentPath.isEmpty ? '/' : parentPath),
                          );
                        }
                        final entry = _entries[i - (_currentPath != '/' ? 1 : 0)];
                        final name = entry['name'] as String;
                        final isDir = entry['is_dir'] == true;
                        final size = entry['size'] as int? ?? 0;
                        final fullPath =
                            '${_currentPath == '/' ? '/' : '$_currentPath/'}$name';
                        return _buildEntry(
                          name: name,
                          isDir: isDir,
                          size: size,
                          onTap: () {
                            if (isDir) {
                              _navigate(fullPath);
                            } else {
                              _startDownload(fullPath, name);
                            }
                          },
                        );
                      },
                    ),
        ),
      ],
    );
  }

  Widget _buildEntry({
    required String name,
    required bool isDir,
    required int size,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: TokyoNight.bgTertiary)),
        ),
        child: Row(
          children: [
            Text(
              isDir ? '\u{1F4C1}' : '\u{1F4C4}',
              style: const TextStyle(fontSize: 18),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                name,
                style: TextStyle(
                  color: isDir ? TokyoNight.accent : TokyoNight.textPrimary,
                  fontSize: 14,
                  fontWeight: isDir ? FontWeight.w500 : FontWeight.normal,
                ),
              ),
            ),
            if (!isDir)
              Text(
                _formatSize(size),
                style: const TextStyle(
                  color: TokyoNight.textMuted,
                  fontSize: 12,
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes == 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    int i = 0;
    double val = bytes.toDouble();
    while (val >= 1024 && i < units.length - 1) {
      val /= 1024;
      i++;
    }
    return '${val.toStringAsFixed(i > 0 ? 1 : 0)} ${units[i]}';
  }
}

class _DownloadState {
  final String filename;
  final Map<int, String> chunks = {};
  _DownloadState(this.filename);
}
