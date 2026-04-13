import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_file/open_file.dart';
import 'package:file_picker/file_picker.dart';
import '../services/ws_service.dart';
import '../services/theme_service.dart';

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
  final Map<String, _DownloadState> _downloads = {};
  final Map<String, _DownloadState> _previews = {};
  Timer? _loadTimeout;

  late void Function(Map<String, dynamic>) _listHandler;
  late void Function(Map<String, dynamic>) _downloadHandler;
  late void Function(Map<String, dynamic>) _uploadAckHandler;
  late void Function(Map<String, dynamic>) _connHandler;

  static const _imageExts = {'.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp'};
  static const _textExts = {
    '.txt', '.log', '.md', '.json', '.yaml', '.yml',
    '.xml', '.csv', '.ini', '.conf', '.cfg', '.sh', '.bash', '.py', '.js',
    '.dart', '.html', '.css', '.toml', '.env', '.gitignore',
  };
  static const _maxPreviewSize = 512 * 1024;

  @override
  void initState() {
    super.initState();
    _ws = context.read<WsService>();

    _listHandler = (msg) {
      _loadTimeout?.cancel();
      final payload = msg['payload'] as Map<String, dynamic>? ?? {};
      if (payload['error'] != null) {
        setState(() { _error = payload['error'] as String; _loading = false; });
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
      final chunkIndex = payload['chunk_index'] as int?;
      if (chunkIndex == null) return;
      final data = payload['data'] as String? ?? '';
      final done = payload['done'] == true;

      final preview = _previews[path];
      if (preview != null) {
        preview.chunks[chunkIndex] = data;
        if (done) _finishPreview(path, preview);
        return;
      }

      final dl = _downloads[path];
      if (dl == null) return;
      dl.chunks[chunkIndex] = data;
      if (done) _finishDownload(path, dl);
    };

    _uploadAckHandler = (msg) {
      final payload = msg['payload'] as Map<String, dynamic>? ?? {};
      if (payload['success'] != true && mounted) {
        final t = context.read<ThemeService>().current;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload error: ${payload['error']}'), backgroundColor: t.danger),
        );
      }
    };

    // Re-request file list when WS reconnects
    _connHandler = (_) {
      if (mounted && !_loading) {
        _navigate(_currentPath);
      }
    };

    _ws.on('file_list_res', _listHandler);
    _ws.on('file_download_chunk', _downloadHandler);
    _ws.on('file_upload_ack', _uploadAckHandler);
    _ws.on('_connected', _connHandler);

    _navigate(_currentPath);
  }

  void _navigate(String path) {
    if (!_ws.connected) {
      setState(() { _error = 'Not connected to server'; _loading = false; });
      return;
    }
    _loadTimeout?.cancel();
    setState(() { _loading = true; _error = null; });
    _ws.send('file_list_req', {'path': path});

    // Timeout after 8 seconds
    _loadTimeout = Timer(const Duration(seconds: 8), () {
      if (mounted && _loading) {
        setState(() {
          _loading = false;
          _error = 'Request timed out. Tap to retry.';
        });
      }
    });
  }

  String _ext(String name) {
    final dot = name.lastIndexOf('.');
    return dot >= 0 ? name.substring(dot).toLowerCase() : '';
  }

  bool _canPreview(String name, int size) {
    if (size > _maxPreviewSize || size == 0) return false;
    final ext = _ext(name);
    return _imageExts.contains(ext) || _textExts.contains(ext);
  }

  void _requestPreview(String fullPath, String filename, int size) {
    _previews[fullPath] = _DownloadState(filename);
    _ws.send('file_download_req', {'path': fullPath});
  }

  void _finishPreview(String path, _DownloadState dl) {
    _previews.remove(path);
    try {
      final sortedKeys = dl.chunks.keys.toList()..sort();
      final combined = sortedKeys.map((k) => dl.chunks[k]!).join('');
      final bytes = base64Decode(combined);
      final ext = _ext(dl.filename);

      if (_imageExts.contains(ext)) {
        _showImagePreview(dl.filename, bytes, path);
      } else {
        final text = String.fromCharCodes(bytes);
        _showTextPreview(dl.filename, text, path);
      }
    } catch (e) {
      debugPrint('Preview error: $e');
    }
  }

  void _showImagePreview(String filename, Uint8List bytes, String remotePath) {
    final t = context.read<ThemeService>().current;
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: t.bgSecondary,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(child: Text(filename, style: TextStyle(color: t.textPrimary, fontSize: 14, fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis)),
                  IconButton(icon: const Icon(Icons.close, size: 20), color: t.textMuted, onPressed: () => Navigator.pop(ctx)),
                ],
              ),
            ),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.5),
              child: InteractiveViewer(child: Image.memory(bytes, fit: BoxFit.contain)),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.download, size: 18),
                  label: const Text('Download'),
                  onPressed: () { Navigator.pop(ctx); _startDownload(remotePath, filename); },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showTextPreview(String filename, String text, String remotePath) {
    final t = context.read<ThemeService>().current;
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: t.bgSecondary,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(child: Text(filename, style: TextStyle(color: t.textPrimary, fontSize: 14, fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis)),
                  IconButton(icon: const Icon(Icons.close, size: 20), color: t.textMuted, onPressed: () => Navigator.pop(ctx)),
                ],
              ),
            ),
            Divider(height: 1, color: t.border),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.5),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  text,
                  style: TextStyle(color: t.textSecondary, fontSize: 12, fontFamily: 'monospace'),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.download, size: 18),
                  label: const Text('Download'),
                  onPressed: () { Navigator.pop(ctx); _startDownload(remotePath, filename); },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _finishDownload(String path, _DownloadState dl) async {
    final t = context.read<ThemeService>().current;
    try {
      final sortedKeys = dl.chunks.keys.toList()..sort();
      final combined = sortedKeys.map((k) => dl.chunks[k]!).join('');
      final bytes = base64Decode(combined);
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/${dl.filename}');
      await file.writeAsBytes(bytes);
      _downloads.remove(path);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Downloaded ${dl.filename}'), backgroundColor: t.success,
          action: SnackBarAction(label: 'Open', textColor: t.bgPrimary, onPressed: () => OpenFile.open(file.path)),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Download error: $e'), backgroundColor: t.danger));
      }
    }
  }

  void _startDownload(String fullPath, String filename) {
    if (!_ws.connected) return;
    final t = context.read<ThemeService>().current;
    _downloads[fullPath] = _DownloadState(filename);
    _ws.send('file_download_req', {'path': fullPath});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Downloading $filename...'), backgroundColor: t.bgSecondary),
    );
  }

  Future<void> _pickAndUpload() async {
    if (!_ws.connected) return;
    final t = context.read<ThemeService>().current;
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null) return;
    for (final pf in result.files) {
      if (pf.path == null) continue;
      final file = File(pf.path!);
      final bytes = await file.readAsBytes();
      final filename = pf.name;
      final targetPath = '${_currentPath == '/' ? '/' : '$_currentPath/'}$filename';
      const chunkSize = 524288;
      final totalChunks = (bytes.length / chunkSize).ceil().clamp(1, 999999);
      _ws.send('file_upload_start', {'path': targetPath, 'total_size': bytes.length, 'total_chunks': totalChunks});
      for (int i = 0; i < totalChunks; i++) {
        final start = i * chunkSize;
        final end = (start + chunkSize).clamp(0, bytes.length);
        _ws.send('file_upload_chunk', {
          'path': targetPath, 'chunk_index': i,
          'data': base64Encode(bytes.sublist(start, end)),
          'done': i == totalChunks - 1,
        });
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Uploaded $filename'), backgroundColor: t.success));
      }
    }
    Future.delayed(const Duration(milliseconds: 500), () { if (mounted) _navigate(_currentPath); });
  }

  void _showPathDialog() {
    final t = context.read<ThemeService>().current;
    final ctrl = TextEditingController(text: _currentPath);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.bgSecondary,
        title: Text('Go to path', style: TextStyle(color: t.textPrimary)),
        content: TextField(
          controller: ctrl, autofocus: true,
          style: TextStyle(color: t.textPrimary, fontFamily: 'monospace'),
          decoration: const InputDecoration(hintText: '/path/to/directory'),
          onSubmitted: (v) { Navigator.pop(ctx); _navigate(v); },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () { Navigator.pop(ctx); _navigate(ctrl.text); }, child: const Text('Go')),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _loadTimeout?.cancel();
    _ws.off('file_list_res', _listHandler);
    _ws.off('file_download_chunk', _downloadHandler);
    _ws.off('file_upload_ack', _uploadAckHandler);
    _ws.off('_connected', _connHandler);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.watch<ThemeService>().current;
    final wsConnected = context.watch<WsService>().connected;

    return Column(
      children: [
        // Path bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          color: t.bgSecondary,
          child: Row(
            children: [
              // Refresh button
              Material(
                color: t.bgTertiary, borderRadius: BorderRadius.circular(6),
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => _navigate(_currentPath),
                  child: Padding(padding: const EdgeInsets.all(8), child: Icon(Icons.refresh, size: 20, color: t.textMuted)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: GestureDetector(
                  onTap: _showPathDialog,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(color: t.bgPrimary, borderRadius: BorderRadius.circular(6), border: Border.all(color: t.border)),
                    child: Text(_currentPath, style: TextStyle(color: t.textPrimary, fontSize: 13, fontFamily: 'monospace'), overflow: TextOverflow.ellipsis),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Material(
                color: t.bgTertiary, borderRadius: BorderRadius.circular(6),
                child: InkWell(
                  borderRadius: BorderRadius.circular(6), onTap: _pickAndUpload,
                  child: Padding(padding: const EdgeInsets.all(8), child: Icon(Icons.upload_file, size: 20, color: t.accent)),
                ),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: t.border),
        // Content
        Expanded(
          child: !wsConnected
              ? _buildStatusView(t, Icons.cloud_off, 'Not connected', 'Waiting for server connection...', null)
              : _loading
                  ? Center(child: CircularProgressIndicator(color: t.accent))
                  : _error != null
                      ? _buildStatusView(t, Icons.error_outline, 'Error', _error!, () => _navigate(_currentPath))
                      : _entries.isEmpty && _currentPath == '/'
                          ? _buildStatusView(t, Icons.folder_open, 'Empty', 'No files found', () => _navigate(_currentPath))
                          : ListView.builder(
                              itemCount: (_currentPath != '/' ? 1 : 0) + _entries.length,
                              itemBuilder: (ctx, i) {
                                if (_currentPath != '/' && i == 0) {
                                  final parts = _currentPath.split('/');
                                  parts.removeLast();
                                  final parentPath = parts.join('/');
                                  return _buildEntry(t, name: '..', isDir: true, size: 0,
                                    onTap: () => _navigate(parentPath.isEmpty ? '/' : parentPath));
                                }
                                final entry = _entries[i - (_currentPath != '/' ? 1 : 0)];
                                final name = entry['name'] as String;
                                final isDir = entry['is_dir'] == true;
                                final size = entry['size'] as int? ?? 0;
                                final fullPath = '${_currentPath == '/' ? '/' : '$_currentPath/'}$name';
                                return _buildEntry(t, name: name, isDir: isDir, size: size,
                                  onTap: () {
                                    if (isDir) { _navigate(fullPath); }
                                    else if (_canPreview(name, size)) { _requestPreview(fullPath, name, size); }
                                    else { _startDownload(fullPath, name); }
                                  },
                                  onLongPress: !isDir ? () => _startDownload(fullPath, name) : null,
                                  previewable: !isDir && _canPreview(name, size),
                                );
                              },
                            ),
        ),
      ],
    );
  }

  Widget _buildStatusView(AppThemeData t, IconData icon, String title, String subtitle, VoidCallback? onRetry) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: t.textMuted),
          const SizedBox(height: 12),
          Text(title, style: TextStyle(color: t.textPrimary, fontSize: 16, fontWeight: FontWeight.w500)),
          const SizedBox(height: 4),
          Text(subtitle, style: TextStyle(color: t.textMuted, fontSize: 13), textAlign: TextAlign.center),
          if (onRetry != null) ...[
            const SizedBox(height: 16),
            ElevatedButton.icon(
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry'),
              onPressed: onRetry,
              style: ElevatedButton.styleFrom(backgroundColor: t.accent, foregroundColor: t.bgPrimary),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEntry(AppThemeData t, {
    required String name, required bool isDir, required int size,
    required VoidCallback onTap, VoidCallback? onLongPress, bool previewable = false,
  }) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.bgTertiary))),
        child: Row(
          children: [
            Icon(
              isDir ? Icons.folder : _fileIcon(name),
              size: 22,
              color: isDir ? t.accent : t.textMuted,
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(name,
              style: TextStyle(color: isDir ? t.accent : t.textPrimary, fontSize: 14,
                fontWeight: isDir ? FontWeight.w500 : FontWeight.normal))),
            if (previewable)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(Icons.preview, size: 16, color: t.textMuted),
              ),
            if (!isDir) Text(_formatSize(size), style: TextStyle(color: t.textMuted, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  IconData _fileIcon(String name) {
    final ext = _ext(name);
    if (_imageExts.contains(ext)) return Icons.image;
    if (_textExts.contains(ext)) return Icons.description;
    if ({'.zip', '.tar', '.gz', '.rar', '.7z'}.contains(ext)) return Icons.archive;
    if ({'.mp4', '.mkv', '.avi', '.mov'}.contains(ext)) return Icons.movie;
    if ({'.mp3', '.wav', '.flac', '.ogg'}.contains(ext)) return Icons.audiotrack;
    if ({'.pdf'}.contains(ext)) return Icons.picture_as_pdf;
    return Icons.insert_drive_file;
  }

  String _formatSize(int bytes) {
    if (bytes == 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    int i = 0; double val = bytes.toDouble();
    while (val >= 1024 && i < units.length - 1) { val /= 1024; i++; }
    return '${val.toStringAsFixed(i > 0 ? 1 : 0)} ${units[i]}';
  }
}

class _DownloadState {
  final String filename;
  final Map<int, String> chunks = {};
  _DownloadState(this.filename);
}
