import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_file/open_file.dart';
import 'package:file_picker/file_picker.dart';
import '../services/download_registry.dart';
import '../services/ws_service.dart';
import '../services/theme_service.dart';
import 'connection_banner.dart';
import 'downloads_sheet.dart';

enum _SortBy { name, size, type }

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
  final Map<String, _PreviewState> _previews = {};
  Timer? _loadTimeout;
  // Idle timeouts so a stalled transfer (lost chunk / missing ack) doesn't
  // leave a spinner or progress bar stuck forever.
  final Map<String, Timer> _downloadTimeouts = {};
  final Map<String, Timer> _previewTimeouts = {};
  final Map<String, Timer> _uploadTimeouts = {};
  static const _downloadIdleTimeout = Duration(seconds: 60);
  static const _previewIdleTimeout = Duration(seconds: 30);
  static const _uploadAckTimeout = Duration(seconds: 60);
  static const _maxDownloadSize = 500 * 1024 * 1024; // 500 MB
  static const _maxUploadSize = 500 * 1024 * 1024; // 500 MB
  static const _chunkSize = 524288; // 512 KB

  // Upload progress tracking
  final Map<String, _UploadProgress> _uploadProgress = {};
  // Last failed download, offered as a one-tap retry.
  String? _lastFailedPath;
  String? _lastFailedName;

  // Browsing controls
  final TextEditingController _filterCtrl = TextEditingController();
  String _filter = '';
  bool _showHidden = false;
  _SortBy _sortBy = _SortBy.type;
  bool _sortAscending = true;
  bool _showFilterBar = false;

  late void Function(Map<String, dynamic>) _listHandler;
  late void Function(Map<String, dynamic>) _downloadHandler;
  late void Function(Map<String, dynamic>) _uploadAckHandler;
  late void Function(Map<String, dynamic>) _connHandler;
  late void Function(Map<String, dynamic>) _disconnHandler;

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
      if (!mounted) return;
      final payload = msg['payload'] as Map<String, dynamic>? ?? {};
      if (payload['error'] != null) {
        setState(() {
          _error = payload['error'].toString();
          _loading = false;
        });
        return;
      }
      // Parse defensively OUTSIDE setState: a malformed entry must not throw
      // from inside the build-triggering callback and leave _loading stuck.
      final rawEntries = payload['entries'] as List<dynamic>? ?? [];
      final parsed = <Map<String, dynamic>>[];
      for (final e in rawEntries) {
        if (e is! Map) continue;
        final map = Map<String, dynamic>.from(e);
        final name = map['name'];
        if (name is! String || name.isEmpty) continue;
        parsed.add(map);
      }
      setState(() {
        _currentPath = payload['path'] as String? ?? '/';
        _entries = parsed;
        _loading = false;
        _error = null;
      });
    };

    _downloadHandler = (msg) {
      if (!mounted) return;
      final payload = msg['payload'] as Map<String, dynamic>? ?? {};
      final path = payload['path'] as String? ?? '';

      // A server-side error for this path must clear whatever transfer is
      // waiting on it, or the stale entry hijacks every later request.
      if (payload['error'] != null) {
        _failTransfer(path, payload['error'].toString());
        return;
      }

      // Tolerate num-typed indices (JSON numbers may arrive as doubles).
      final chunkIndex = (payload['chunk_index'] as num?)?.toInt();
      if (chunkIndex == null) return;
      final totalChunks = (payload['total_chunks'] as num?)?.toInt();
      final data = payload['data'] as String? ?? '';
      final done = payload['done'] == true;

      final preview = _previews[path];
      if (preview != null) {
        preview.chunks[chunkIndex] = data;
        if (totalChunks != null) preview.totalChunks = totalChunks;
        _previewTimeouts[path]?.cancel();
        if (done) {
          _previewTimeouts.remove(path)?.cancel();
          _finishPreview(path, preview);
        } else {
          _previewTimeouts[path] =
              Timer(_previewIdleTimeout, () => _onPreviewTimeout(path));
        }
        return;
      }

      final dl = _downloads[path];
      if (dl == null) return;
      if (totalChunks != null) dl.totalChunks = totalChunks;
      dl.addChunk(chunkIndex, data, done).then((_) {
        if (!mounted) return;
        // Back-to-back chunks queue several continuations; only the first one
        // that sees the finished state may complete the transfer.
        if (!identical(_downloads[path], dl)) return;
        if (dl.failure != null) {
          _failTransfer(path, dl.failure!);
        } else if (dl.completed) {
          _finishDownload(path, dl);
        } else {
          // Reset the idle timeout each time progress is made.
          _downloadTimeouts[path]?.cancel();
          _downloadTimeouts[path] =
              Timer(_downloadIdleTimeout, () => _onDownloadTimeout(path));
          setState(() {});
        }
      });
    };

    _uploadAckHandler = (msg) {
      if (!mounted) return;
      final payload = msg['payload'] as Map<String, dynamic>? ?? {};
      final path = payload['path'] as String?;
      final t = context.read<ThemeService>().current;
      if (path != null) {
        _uploadTimeouts.remove(path)?.cancel();
        final progress = _uploadProgress.remove(path);
        final name = progress?.filename ?? path.split('/').last;
        final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
        // Success feedback is shown ONLY after the server acks, so it can never
        // contradict a later error for the same upload.
        if (payload['success'] == true) {
          messenger.showSnackBar(SnackBar(
              content: Text('Uploaded $name'), backgroundColor: t.success));
        } else {
          messenger.showSnackBar(SnackBar(
              content: Text(
                  'Upload failed: ${payload['error'] ?? 'unknown error'}'),
              backgroundColor: t.danger));
        }
      }
      setState(() {});
      // Refresh the listing once every upload has resolved.
      if (_uploadProgress.isEmpty && _ws.connected) _navigate(_currentPath);
    };

    _connHandler = (_) {
      // Always re-issue the listing: a request that was in flight when the
      // socket died will never be answered, so the !_loading guard would
      // leave the tab spinning until its timeout.
      if (mounted) _navigate(_currentPath);
    };

    _disconnHandler = (_) {
      if (!mounted) return;
      _abortAllTransfers('Connection lost');
    };

    _ws.on('file_list_res', _listHandler);
    _ws.on('file_download_chunk', _downloadHandler);
    _ws.on('file_upload_ack', _uploadAckHandler);
    _ws.on('_connected', _connHandler);
    _ws.on('_disconnected', _disconnHandler);

    _navigate(_currentPath);
  }

  /// Clear every in-flight transfer (used on disconnect) so nothing sits at a
  /// frozen percentage waiting for a 60 s idle timeout that can never resolve.
  void _abortAllTransfers(String reason) {
    final names = <String>[
      ..._downloads.values.map((d) => d.filename),
      ..._uploadProgress.values.map((u) => u.filename),
    ];
    for (final t in _downloadTimeouts.values) {
      t.cancel();
    }
    for (final t in _previewTimeouts.values) {
      t.cancel();
    }
    for (final t in _uploadTimeouts.values) {
      t.cancel();
    }
    _downloadTimeouts.clear();
    _previewTimeouts.clear();
    _uploadTimeouts.clear();
    for (final dl in _downloads.values) {
      dl.abort();
    }
    final hadWork = _downloads.isNotEmpty ||
        _uploadProgress.isNotEmpty ||
        _previews.isNotEmpty;
    _downloads.clear();
    _previews.clear();
    _uploadProgress.clear();
    if (!mounted) return;
    setState(() {});
    if (hadWork) {
      final t = context.read<ThemeService>().current;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('$reason — interrupted: ${names.join(', ')}'),
          backgroundColor: t.danger,
        ));
    }
  }

  void _failTransfer(String path, String error) {
    _downloadTimeouts.remove(path)?.cancel();
    _previewTimeouts.remove(path)?.cancel();
    final dl = _downloads.remove(path);
    dl?.abort();
    final preview = _previews.remove(path);
    if (!mounted) return;
    final name = dl?.filename ?? preview?.filename ?? path.split('/').last;
    if (dl != null) {
      _lastFailedPath = path;
      _lastFailedName = name;
    }
    setState(() {});
    final t = context.read<ThemeService>().current;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('$name: $error'),
        backgroundColor: t.danger,
        action: dl == null
            ? null
            : SnackBarAction(
                label: 'Retry',
                textColor: t.bgPrimary,
                onPressed: () => _startDownload(path, name),
              ),
      ));
  }

  void _navigate(String path) {
    if (!_ws.connected) {
      setState(() {
        _error = 'Not connected to server';
        _loading = false;
      });
      return;
    }
    _loadTimeout?.cancel();
    setState(() {
      _loading = true;
      _error = null;
    });
    _ws.send('file_list_req', {'path': path});

    _loadTimeout = Timer(const Duration(seconds: 8), () {
      if (mounted && _loading) {
        setState(() {
          _loading = false;
          _error = 'Request timed out';
        });
      }
    });
  }

  Future<void> _refresh() async {
    _navigate(_currentPath);
    // Wait for response or timeout
    await Future.delayed(const Duration(milliseconds: 500));
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

  /// Join a directory and an entry name into an absolute remote path,
  /// collapsing any duplicate separators the server (or the Go-to dialog)
  /// might have introduced.
  String _joinPath(String dir, String name) {
    final base = dir.endsWith('/') ? dir.substring(0, dir.length - 1) : dir;
    return '$base/$name';
  }

  void _requestPreview(String fullPath, String filename, int size) {
    // One transfer per path: preview and download share the server's path-keyed
    // chunk stream, so overlapping them would interleave chunks.
    if (_downloads.containsKey(fullPath) || _previews.containsKey(fullPath)) {
      return;
    }
    if (!_ws.connected) return;
    _previews[fullPath] = _PreviewState(filename);
    _ws.send('file_download_req', {'path': fullPath});
    _previewTimeouts[fullPath]?.cancel();
    _previewTimeouts[fullPath] =
        Timer(_previewIdleTimeout, () => _onPreviewTimeout(fullPath));
    setState(() {});
  }

  void _onPreviewTimeout(String path) {
    _previewTimeouts.remove(path)?.cancel();
    final preview = _previews.remove(path);
    if (preview == null || !mounted) return;
    setState(() {});
    final t = context.read<ThemeService>().current;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text('Preview timed out: ${preview.filename}'),
          backgroundColor: t.danger));
  }

  void _finishPreview(String path, _PreviewState dl) {
    _previews.remove(path);
    if (mounted) setState(() {});
    try {
      final sortedKeys = dl.chunks.keys.toList()..sort();
      Uint8List data;
      try {
        // Normal case: the server base64-encodes each chunk independently.
        final bytes = BytesBuilder(copy: false);
        for (final k in sortedKeys) {
          bytes.add(base64Decode(dl.chunks[k]!));
        }
        data = bytes.takeBytes();
      } on FormatException {
        // Fallback for a server that encodes the whole file once and splits the
        // resulting string, so individual chunks aren't valid base64.
        data = base64Decode(sortedKeys.map((k) => dl.chunks[k]!).join());
      }
      final ext = _ext(dl.filename);
      if (_imageExts.contains(ext)) {
        _showImagePreview(dl.filename, data, path);
      } else {
        // Decode as UTF-8 (allowMalformed so binary-ish files don't throw)
        // instead of String.fromCharCodes, which mangles multibyte characters.
        final text = utf8.decode(data, allowMalformed: true);
        _showTextPreview(dl.filename, text, path);
      }
    } catch (e) {
      debugPrint('Preview error: $e');
      if (mounted) {
        final t = context.read<ThemeService>().current;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
              content: Text('Preview failed: ${dl.filename}'),
              backgroundColor: t.danger));
      }
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
                  Expanded(
                      child: Text(filename,
                          style: TextStyle(
                              color: t.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w500),
                          overflow: TextOverflow.ellipsis)),
                  IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      color: t.textMuted,
                      onPressed: () => Navigator.pop(ctx)),
                ],
              ),
            ),
            ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(ctx).size.height * 0.5),
              child: InteractiveViewer(
                  child: Image.memory(bytes, fit: BoxFit.contain)),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.download, size: 18),
                  label: const Text('Download'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _startDownload(remotePath, filename);
                  },
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
                  Expanded(
                      child: Text(filename,
                          style: TextStyle(
                              color: t.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w500),
                          overflow: TextOverflow.ellipsis)),
                  IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      color: t.textMuted,
                      onPressed: () => Navigator.pop(ctx)),
                ],
              ),
            ),
            Divider(height: 1, color: t.border),
            ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(ctx).size.height * 0.5),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  text,
                  style: TextStyle(
                      color: t.textSecondary,
                      fontSize: 12,
                      fontFamily: 'monospace'),
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
                  onPressed: () {
                    Navigator.pop(ctx);
                    _startDownload(remotePath, filename);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _finishDownload(String path, _DownloadState dl) async {
    _downloadTimeouts.remove(path)?.cancel();
    _downloads.remove(path);
    try {
      final file = await dl.finish();
      if (mounted) {
        final t = context.read<ThemeService>().current;
        setState(() {});
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text('Downloaded ${file.path.split('/').last}'),
            backgroundColor: t.success,
            action: SnackBarAction(
                label: 'Open',
                textColor: t.bgPrimary,
                onPressed: () => OpenFile.open(file.path)),
          ));
      }
    } catch (e) {
      await dl.abort();
      if (mounted) {
        _lastFailedPath = path;
        _lastFailedName = dl.filename;
        final t = context.read<ThemeService>().current;
        setState(() {});
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text('Download error: $e'),
            backgroundColor: t.danger,
            action: SnackBarAction(
                label: 'Retry',
                textColor: t.bgPrimary,
                onPressed: () => _startDownload(path, dl.filename)),
          ));
      }
    }
  }

  /// Returns a non-existing File path, appending " (1)", " (2)", ... on collision
  /// so a new download never silently overwrites an earlier one. The chosen
  /// path is reserved in [DownloadRegistry] until the transfer ends.
  static Future<File> uniqueFile(String dirPath, String filename) async {
    Future<bool> taken(File f) async =>
        DownloadRegistry.isActive(f.path) || await f.exists();

    var file = File('$dirPath/$filename');
    if (!await taken(file)) {
      DownloadRegistry.reserve(file.path);
      return file;
    }
    final dot = filename.lastIndexOf('.');
    final base = dot > 0 ? filename.substring(0, dot) : filename;
    final ext = dot > 0 ? filename.substring(dot) : '';
    var i = 1;
    while (await taken(file)) {
      file = File('$dirPath/$base ($i)$ext');
      i++;
    }
    DownloadRegistry.reserve(file.path);
    return file;
  }

  void _onDownloadTimeout(String path) {
    _downloadTimeouts.remove(path)?.cancel();
    final dl = _downloads.remove(path);
    if (dl == null || !mounted) return;
    dl.abort();
    _lastFailedPath = path;
    _lastFailedName = dl.filename;
    final t = context.read<ThemeService>().current;
    setState(() {});
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('Download timed out: ${dl.filename}'),
        backgroundColor: t.danger,
        action: SnackBarAction(
            label: 'Retry',
            textColor: t.bgPrimary,
            onPressed: () => _startDownload(path, dl.filename)),
      ));
  }

  Future<void> _startDownload(String fullPath, String filename,
      [int size = 0]) async {
    if (!_ws.connected) return;
    final t = context.read<ThemeService>().current;
    final messenger = ScaffoldMessenger.of(context);
    if (size > _maxDownloadSize) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
            content: Text('File too large to download (${_formatSize(size)})'),
            backgroundColor: t.danger));
      return;
    }
    // One transfer per path (see _requestPreview).
    if (_downloads.containsKey(fullPath) || _previews.containsKey(fullPath)) {
      return;
    }

    final File target;
    try {
      final dir = await getApplicationDocumentsDirectory();
      target = await uniqueFile(dir.path, filename);
    } catch (e) {
      if (!mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
            content: Text('Cannot open storage: $e'), backgroundColor: t.danger));
      return;
    }
    if (!mounted) return;
    // Re-check after the await: a second tap could have started this same
    // download while the documents directory was being resolved, which would
    // orphan one of the two files.
    if (_downloads.containsKey(fullPath) || _previews.containsKey(fullPath)) {
      return;
    }

    if (_lastFailedPath == fullPath) {
      _lastFailedPath = null;
      _lastFailedName = null;
    }
    _downloads[fullPath] = _DownloadState(filename, target, expectedSize: size);
    _ws.send('file_download_req', {'path': fullPath});
    _downloadTimeouts[fullPath]?.cancel();
    _downloadTimeouts[fullPath] =
        Timer(_downloadIdleTimeout, () => _onDownloadTimeout(fullPath));
    setState(() {});
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text('Downloading $filename...'),
          backgroundColor: t.bgSecondary));
  }

  Future<void> _pickAndUpload() async {
    if (!_ws.connected) return;
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null || !mounted) return;
    final t = context.read<ThemeService>().current;
    final messenger = ScaffoldMessenger.of(context);

    for (final pf in result.files) {
      if (pf.path == null) continue;
      if (!_ws.connected || !mounted) break;
      final file = File(pf.path!);
      final filename = pf.name;

      final int totalSize;
      try {
        totalSize = await file.length();
        if (!mounted) return;
      } catch (e) {
        if (!mounted) return;
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
              content: Text('Cannot read $filename'), backgroundColor: t.danger));
        continue;
      }
      if (totalSize > _maxUploadSize) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
              content: Text(
                  '$filename is too large to upload (${_formatSize(totalSize)})'),
              backgroundColor: t.danger));
        continue;
      }

      final targetPath = _joinPath(_currentPath, filename);
      // Two picked files with the same name would share one progress/timeout
      // key and cross-cancel each other.
      if (_uploadProgress.containsKey(targetPath)) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
              content: Text('$filename is already uploading'),
              backgroundColor: t.warning));
        continue;
      }
      // Warn before silently overwriting a file the listing already shows.
      final exists = _entries.any((e) =>
          e['name'] == filename && e['is_dir'] != true);
      if (exists) {
        final overwrite = await _confirmOverwrite(filename);
        if (!mounted) return;
        if (!overwrite) continue;
      }

      final totalChunks =
          totalSize == 0 ? 1 : (totalSize / _chunkSize).ceil();
      _uploadProgress[targetPath] =
          _UploadProgress(filename, totalChunks, totalSize);
      setState(() {});

      _ws.send('file_upload_start', {
        'path': targetPath,
        'total_size': totalSize,
        'total_chunks': totalChunks,
      });

      // Stream the file chunk by chunk: readAsBytes would hold the whole file
      // in RAM and base64 inflates it another 4/3 on top.
      RandomAccessFile? raf;
      var aborted = false;
      try {
        raf = await file.open();
        for (int i = 0; i < totalChunks; i++) {
          if (!_ws.connected || !mounted) {
            aborted = true;
            break;
          }
          final bytes = await _readExactly(raf, _chunkSize);
          _ws.send('file_upload_chunk', {
            'path': targetPath,
            'chunk_index': i,
            'data': base64Encode(bytes),
            'done': i == totalChunks - 1,
          });
          final progress = _uploadProgress[targetPath];
          if (progress == null) {
            // Cancelled elsewhere (disconnect).
            aborted = true;
            break;
          }
          progress.sentChunks = i + 1;
          progress.sentBytes += bytes.length;
          if (i % 5 == 0) setState(() {});
          // Yield periodically so the socket sink can drain instead of buffering
          // the entire (base64-inflated) file in memory at once.
          if (i % 8 == 7) await Future.delayed(const Duration(milliseconds: 8));
        }
      } catch (e) {
        aborted = true;
        debugPrint('Upload read error: $e');
        if (mounted) {
          messenger
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(
                content: Text('Upload failed: $filename ($e)'),
                backgroundColor: t.danger));
        }
      } finally {
        await raf?.close();
      }

      if (!mounted) return;
      if (aborted) {
        _uploadTimeouts.remove(targetPath)?.cancel();
        _uploadProgress.remove(targetPath);
        setState(() {});
        continue;
      }
      setState(() {});
      // Don't claim success yet — wait for file_upload_ack. Arm a timeout so a
      // missing ack clears the progress bar instead of hanging at 100%.
      _uploadTimeouts[targetPath]?.cancel();
      _uploadTimeouts[targetPath] =
          Timer(_uploadAckTimeout, () => _onUploadTimeout(targetPath));
    }
  }

  /// [RandomAccessFile.read] is allowed to return fewer bytes than requested;
  /// keep reading until the chunk is full or the file ends, otherwise the chunk
  /// count would no longer match the bytes actually sent.
  static Future<Uint8List> _readExactly(RandomAccessFile raf, int count) async {
    final buffer = BytesBuilder(copy: false);
    var remaining = count;
    while (remaining > 0) {
      final part = await raf.read(remaining);
      if (part.isEmpty) break; // EOF
      buffer.add(part);
      remaining -= part.length;
    }
    return buffer.takeBytes();
  }

  Future<bool> _confirmOverwrite(String filename) async {
    final t = context.read<ThemeService>().current;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.bgSecondary,
        title: Text('Overwrite file?', style: TextStyle(color: t.textPrimary)),
        content: Text(
          '"$filename" already exists in this directory. Uploading will '
          'replace it on the remote machine.',
          style: TextStyle(color: t.textMuted, fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Skip')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Overwrite', style: TextStyle(color: t.danger)),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  void _onUploadTimeout(String path) {
    _uploadTimeouts.remove(path)?.cancel();
    final progress = _uploadProgress.remove(path);
    if (progress == null || !mounted) return;
    final t = context.read<ThemeService>().current;
    setState(() {});
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text('Upload timed out: ${progress.filename}'),
          backgroundColor: t.danger));
    // Refresh once all uploads have resolved (the file may have partially landed).
    if (_uploadProgress.isEmpty && _ws.connected) _navigate(_currentPath);
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
          controller: ctrl,
          autofocus: true,
          style: TextStyle(color: t.textPrimary, fontFamily: 'monospace'),
          decoration: const InputDecoration(hintText: '/path/to/directory'),
          onSubmitted: (v) {
            Navigator.pop(ctx);
            _navigate(_normalizePath(v));
          },
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _navigate(_normalizePath(ctrl.text));
              },
              child: const Text('Go')),
        ],
      ),
    ).then((_) => ctrl.dispose());
  }

  /// Trim whitespace and collapse trailing slashes so '/var/log/' and
  /// '/var/log' address the same directory.
  String _normalizePath(String raw) {
    var p = raw.trim();
    if (p.isEmpty) return '/';
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  String _parentPath(String path) {
    final normalized = _normalizePath(path);
    final idx = normalized.lastIndexOf('/');
    if (idx <= 0) return '/';
    return normalized.substring(0, idx);
  }

  @override
  void dispose() {
    _loadTimeout?.cancel();
    for (final t in _downloadTimeouts.values) {
      t.cancel();
    }
    for (final t in _previewTimeouts.values) {
      t.cancel();
    }
    for (final t in _uploadTimeouts.values) {
      t.cancel();
    }
    for (final dl in _downloads.values) {
      dl.abort();
    }
    _filterCtrl.dispose();
    _ws.off('file_list_res', _listHandler);
    _ws.off('file_download_chunk', _downloadHandler);
    _ws.off('file_upload_ack', _uploadAckHandler);
    _ws.off('_connected', _connHandler);
    _ws.off('_disconnected', _disconnHandler);
    super.dispose();
  }

  /// Entries after hidden-file, text-filter and sort rules are applied.
  List<Map<String, dynamic>> get _visibleEntries {
    final filter = _filter.toLowerCase();
    final list = _entries.where((e) {
      final name = e['name'] as String? ?? '';
      if (!_showHidden && name.startsWith('.')) return false;
      if (filter.isNotEmpty && !name.toLowerCase().contains(filter)) {
        return false;
      }
      return true;
    }).toList();

    int cmp(Map<String, dynamic> a, Map<String, dynamic> b) {
      final aDir = a['is_dir'] == true;
      final bDir = b['is_dir'] == true;
      // Directories always lead, regardless of sort key/direction.
      if (aDir != bDir) return aDir ? -1 : 1;
      switch (_sortBy) {
        case _SortBy.size:
          return _entrySize(a).compareTo(_entrySize(b));
        case _SortBy.type:
          final byExt = _ext(a['name'] as String)
              .compareTo(_ext(b['name'] as String));
          if (byExt != 0) return byExt;
          return (a['name'] as String)
              .toLowerCase()
              .compareTo((b['name'] as String).toLowerCase());
        case _SortBy.name:
          return (a['name'] as String)
              .toLowerCase()
              .compareTo((b['name'] as String).toLowerCase());
      }
    }

    list.sort((a, b) => _sortAscending ? cmp(a, b) : -cmp(a, b));
    return list;
  }

  /// Sizes may arrive as int or double depending on the server's JSON encoder.
  static int _entrySize(Map<String, dynamic> entry) =>
      (entry['size'] as num?)?.toInt() ?? 0;

  @override
  Widget build(BuildContext context) {
    final t = context.watch<ThemeService>().current;
    final entries = _visibleEntries;

    return Column(
      children: [
        const ConnectionBanner(),
        // Transfer progress bars
        ..._buildTransferBars(t),
        if (_lastFailedPath != null) _buildRetryBar(t),
        // Path bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          color: t.bgSecondary,
          child: Row(
            children: [
              Material(
                color: t.bgTertiary,
                borderRadius: BorderRadius.circular(6),
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => _navigate(_currentPath),
                  child: Padding(
                      padding: const EdgeInsets.all(8),
                      child:
                          Icon(Icons.refresh, size: 20, color: t.textMuted)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: GestureDetector(
                  onTap: _showPathDialog,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                        color: t.bgPrimary,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: t.border)),
                    child: Text(_currentPath,
                        style: TextStyle(
                            color: t.textPrimary,
                            fontSize: 13,
                            fontFamily: 'monospace'),
                        overflow: TextOverflow.ellipsis),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Material(
                color: _showFilterBar ? t.accent.withOpacity(0.2) : t.bgTertiary,
                borderRadius: BorderRadius.circular(6),
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => setState(() {
                    _showFilterBar = !_showFilterBar;
                    if (!_showFilterBar) {
                      _filterCtrl.clear();
                      _filter = '';
                    }
                  }),
                  child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(Icons.search,
                          size: 20,
                          color: _showFilterBar ? t.accent : t.textMuted)),
                ),
              ),
              const SizedBox(width: 6),
              Material(
                color: t.bgTertiary,
                borderRadius: BorderRadius.circular(6),
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: _pickAndUpload,
                  child: Padding(
                      padding: const EdgeInsets.all(8),
                      child:
                          Icon(Icons.upload_file, size: 20, color: t.accent)),
                ),
              ),
            ],
          ),
        ),
        if (_showFilterBar) _buildFilterBar(t, entries.length),
        Divider(height: 1, color: t.border),
        // Content with pull-to-refresh
        Expanded(
          child: _loading
              ? Center(child: CircularProgressIndicator(color: t.accent))
              : _error != null
                  ? _buildStatusView(t, Icons.error_outline, 'Error', _error!,
                      () => _navigate(_currentPath))
                  : RefreshIndicator(
                      onRefresh: _refresh,
                      color: t.accent,
                      backgroundColor: t.bgSecondary,
                      child: entries.isEmpty
                          ? ListView(
                              children: [
                                SizedBox(
                                  height: 300,
                                  child: _buildStatusView(
                                      t,
                                      Icons.folder_open,
                                      _filter.isEmpty ? 'Empty' : 'No matches',
                                      _filter.isEmpty
                                          ? 'No files found'
                                          : 'Nothing matches "$_filter"',
                                      () => _navigate(_currentPath)),
                                ),
                              ],
                            )
                          : ListView.builder(
                              itemCount:
                                  (_currentPath != '/' ? 1 : 0) + entries.length,
                              itemBuilder: (ctx, i) {
                                if (_currentPath != '/' && i == 0) {
                                  return _buildEntry(t,
                                      name: '..',
                                      isDir: true,
                                      size: 0,
                                      onTap: () =>
                                          _navigate(_parentPath(_currentPath)));
                                }
                                final entry =
                                    entries[i - (_currentPath != '/' ? 1 : 0)];
                                final name = entry['name'] as String;
                                final isDir = entry['is_dir'] == true;
                                final size = _entrySize(entry);
                                final fullPath = _joinPath(_currentPath, name);
                                final isDownloading =
                                    _downloads.containsKey(fullPath);
                                final isPreviewing =
                                    _previews.containsKey(fullPath);
                                return _buildEntry(t,
                                    name: name,
                                    isDir: isDir,
                                    size: size,
                                    onTap: () {
                                      if (isDir) {
                                        _navigate(fullPath);
                                      } else if (_canPreview(name, size)) {
                                        _requestPreview(fullPath, name, size);
                                      } else {
                                        _startDownload(fullPath, name, size);
                                      }
                                    },
                                    onLongPress: !isDir
                                        ? () =>
                                            _startDownload(fullPath, name, size)
                                        : null,
                                    previewable: !isDir && _canPreview(name, size),
                                    downloading: isDownloading || isPreviewing,
                                    downloadProgress: isDownloading
                                        ? _downloads[fullPath]!.progress
                                        : null);
                              },
                            ),
                    ),
        ),
      ],
    );
  }

  Widget _buildFilterBar(AppThemeData t, int shown) {
    return Container(
      color: t.bgSecondary,
      padding: const EdgeInsets.fromLTRB(12, 0, 8, 6),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _filterCtrl,
              autofocus: true,
              style: TextStyle(color: t.textPrimary, fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: 'Filter ($shown shown)',
                hintStyle:
                    TextStyle(color: t.textMuted.withOpacity(0.6), fontSize: 13),
              ),
              onChanged: (v) => setState(() => _filter = v),
            ),
          ),
          Tooltip(
            message: _showHidden ? 'Hide dotfiles' : 'Show hidden files',
            child: InkWell(
              onTap: () => setState(() => _showHidden = !_showHidden),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(
                    _showHidden ? Icons.visibility : Icons.visibility_off,
                    size: 18,
                    color: _showHidden ? t.accent : t.textMuted),
              ),
            ),
          ),
          PopupMenuButton<_SortBy>(
            icon: Icon(Icons.sort, size: 18, color: t.textMuted),
            tooltip: 'Sort',
            color: t.bgTertiary,
            onSelected: (v) => setState(() {
              if (_sortBy == v) {
                _sortAscending = !_sortAscending;
              } else {
                _sortBy = v;
                _sortAscending = true;
              }
            }),
            itemBuilder: (_) => [
              for (final entry in const {
                _SortBy.type: 'Type',
                _SortBy.name: 'Name',
                _SortBy.size: 'Size',
              }.entries)
                PopupMenuItem(
                  value: entry.key,
                  child: Row(
                    children: [
                      Icon(
                        _sortBy == entry.key
                            ? (_sortAscending
                                ? Icons.arrow_upward
                                : Icons.arrow_downward)
                            : null,
                        size: 14,
                        color: t.accent,
                      ),
                      const SizedBox(width: 8),
                      Text(entry.value,
                          style:
                              TextStyle(color: t.textPrimary, fontSize: 13)),
                    ],
                  ),
                ),
            ],
          ),
          Tooltip(
            message: 'Downloaded files',
            child: InkWell(
              onTap: () => showModalBottomSheet(
                context: context,
                backgroundColor: Colors.transparent,
                isScrollControlled: true,
                builder: (_) => const DownloadsSheet(),
              ),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child:
                    Icon(Icons.folder_special, size: 18, color: t.textMuted),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRetryBar(AppThemeData t) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      color: t.danger.withOpacity(0.12),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 14, color: t.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text('Failed: ${_lastFailedName ?? ''}',
                style: TextStyle(color: t.danger, fontSize: 11),
                overflow: TextOverflow.ellipsis),
          ),
          TextButton(
            onPressed: () {
              final path = _lastFailedPath;
              final name = _lastFailedName;
              if (path != null && name != null) _startDownload(path, name);
            },
            style: TextButton.styleFrom(
              foregroundColor: t.danger,
              minimumSize: const Size(0, 26),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Retry', style: TextStyle(fontSize: 11)),
          ),
          InkWell(
            onTap: () => setState(() {
              _lastFailedPath = null;
              _lastFailedName = null;
            }),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.close, size: 14, color: t.danger),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildTransferBars(AppThemeData t) {
    final bars = <Widget>[];
    for (final up in _uploadProgress.entries) {
      final p = up.value;
      final progress = p.totalChunks > 0 ? p.sentChunks / p.totalChunks : 0.0;
      bars.add(_transferBar(t, Icons.upload, p.filename, progress, p.rateLabel));
    }
    for (final dl in _downloads.entries) {
      final d = dl.value;
      bars.add(_transferBar(
          t, Icons.download, d.filename, d.progress, d.rateLabel));
    }
    return bars;
  }

  Widget _transferBar(AppThemeData t, IconData icon, String name,
      double progress, String rate) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: t.accent.withOpacity(0.1),
      child: Row(
        children: [
          Icon(icon, size: 14, color: t.accent),
          const SizedBox(width: 8),
          Expanded(
              child: Text(name,
                  style: TextStyle(color: t.textPrimary, fontSize: 11),
                  overflow: TextOverflow.ellipsis)),
          if (rate.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text(rate, style: TextStyle(color: t.textMuted, fontSize: 10)),
          ],
          const SizedBox(width: 8),
          SizedBox(
            width: 60,
            child: LinearProgressIndicator(
                value: progress, backgroundColor: t.bgTertiary, color: t.accent),
          ),
          const SizedBox(width: 8),
          Text('${(progress * 100).toInt()}%',
              style: TextStyle(color: t.textMuted, fontSize: 11)),
        ],
      ),
    );
  }

  Widget _buildStatusView(AppThemeData t, IconData icon, String title,
      String subtitle, VoidCallback? onRetry) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: t.textMuted),
          const SizedBox(height: 12),
          Text(title,
              style: TextStyle(
                  color: t.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 4),
          Text(subtitle,
              style: TextStyle(color: t.textMuted, fontSize: 13),
              textAlign: TextAlign.center),
          if (onRetry != null) ...[
            const SizedBox(height: 16),
            ElevatedButton.icon(
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry'),
              onPressed: onRetry,
              style: ElevatedButton.styleFrom(
                  backgroundColor: t.accent, foregroundColor: t.bgPrimary),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEntry(
    AppThemeData t, {
    required String name,
    required bool isDir,
    required int size,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
    bool previewable = false,
    bool downloading = false,
    double? downloadProgress,
  }) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration:
            BoxDecoration(border: Border(bottom: BorderSide(color: t.bgTertiary))),
        child: Column(
          children: [
            Row(
              children: [
                Icon(
                  isDir ? Icons.folder : _fileIcon(name),
                  size: 22,
                  color: isDir ? t.accent : t.textMuted,
                ),
                const SizedBox(width: 10),
                Expanded(
                    child: Text(name,
                        style: TextStyle(
                            color: isDir ? t.accent : t.textPrimary,
                            fontSize: 14,
                            fontWeight:
                                isDir ? FontWeight.w500 : FontWeight.normal))),
                if (downloading)
                  SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: t.accent))
                else if (previewable)
                  Icon(Icons.preview, size: 16, color: t.textMuted),
                if (!isDir && !downloading) ...[
                  const SizedBox(width: 8),
                  Text(_formatSize(size),
                      style: TextStyle(color: t.textMuted, fontSize: 12)),
                ],
              ],
            ),
            if (downloading && downloadProgress != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: LinearProgressIndicator(
                  value: downloadProgress,
                  backgroundColor: t.bgTertiary,
                  color: t.accent,
                  minHeight: 3,
                ),
              ),
          ],
        ),
      ),
    );
  }

  IconData _fileIcon(String name) {
    final ext = _ext(name);
    if (_imageExts.contains(ext)) return Icons.image;
    if (_textExts.contains(ext)) return Icons.description;
    if ({'.zip', '.tar', '.gz', '.rar', '.7z'}.contains(ext)) {
      return Icons.archive;
    }
    if ({'.mp4', '.mkv', '.avi', '.mov'}.contains(ext)) return Icons.movie;
    if ({'.mp3', '.wav', '.flac', '.ogg'}.contains(ext)) return Icons.audiotrack;
    if ({'.pdf'}.contains(ext)) return Icons.picture_as_pdf;
    return Icons.insert_drive_file;
  }

  String _formatSize(int bytes) => formatBytes(bytes);

  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
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

/// Streams an incoming download straight to disk instead of accumulating every
/// base64 chunk in RAM (the old approach peaked at roughly 5x the file size).
///
/// Chunks may arrive out of order, so they are buffered only until the next
/// expected index is available, then decoded and appended in order.
class _DownloadState {
  final String filename;
  final File file;
  final int expectedSize;
  final Map<int, String> _pending = {};
  final DateTime _startedAt = DateTime.now();

  IOSink? _sink;
  int _nextIndex = 0;
  int _bytesWritten = 0;
  int totalChunks = 0;
  bool completed = false;
  bool _draining = false;
  bool _aborted = false;
  bool _sawDone = false;
  String? failure;

  /// True while chunks are being buffered whole because the server splits one
  /// base64 stream across chunks rather than encoding each chunk on its own.
  bool _concatMode = false;

  _DownloadState(this.filename, this.file, {this.expectedSize = 0});

  double get progress {
    if (expectedSize > 0) {
      return (_bytesWritten / expectedSize).clamp(0.0, 1.0);
    }
    if (totalChunks > 0) return (_nextIndex / totalChunks).clamp(0.0, 1.0);
    return 0.0;
  }

  String get rateLabel {
    final elapsed = DateTime.now().difference(_startedAt).inMilliseconds / 1000;
    if (elapsed < 0.5 || _bytesWritten == 0) return '';
    final rate = _bytesWritten / elapsed;
    final speed = '${_FilesTabState.formatBytes(rate.toInt())}/s';
    if (expectedSize <= 0 || rate <= 0) return speed;
    final remaining = ((expectedSize - _bytesWritten) / rate).round();
    if (remaining <= 0) return speed;
    return '$speed · ${remaining}s';
  }

  Future<void> addChunk(int index, String data, bool done) async {
    if (_aborted) return;
    if (done) _sawDone = true;
    // Drop retransmits of chunks already written: parking one below _nextIndex
    // would leave _pending permanently non-empty and wedge the completion gate.
    if (!_concatMode && index < _nextIndex) return;
    _pending[index] = data;
    await _drain();
  }

  Future<void> _drain() async {
    if (_draining || _aborted) return;
    _draining = true;
    try {
      _sink ??= file.openWrite();
      while (_pending.containsKey(_nextIndex)) {
        final b64 = _pending.remove(_nextIndex)!;
        if (_concatMode) {
          // Cannot decode independently — keep buffering until the end.
          _pending[_nextIndex] = b64;
          break;
        }
        Uint8List bytes;
        try {
          bytes = base64Decode(b64);
        } catch (e) {
          if (_nextIndex == 0) {
            // The server encoded the whole file as one base64 string and split
            // the STRING; fall back to joining everything before decoding.
            // Nothing has been written yet, so this switch is safe.
            _concatMode = true;
            _pending[0] = b64;
            break;
          }
          failure = 'corrupt chunk $_nextIndex';
          return;
        }
        _sink!.add(bytes);
        _bytesWritten += bytes.length;
        _nextIndex++;
      }
      if (!_sawDone) return;
      if (!_concatMode) {
        if (_pending.isNotEmpty) return; // still waiting on an earlier chunk
        if (totalChunks > 0 && _nextIndex < totalChunks) {
          failure =
              'incomplete transfer (${totalChunks - _nextIndex} missing chunk(s))';
          return;
        }
        completed = true;
      } else {
        // Concat mode holds every chunk; require a contiguous 0..n-1 run rather
        // than just a count, and never treat "no total_chunks" as complete by
        // default.
        final expected = totalChunks > 0 ? totalChunks : _pending.length;
        final missing = [
          for (var i = 0; i < expected; i++)
            if (!_pending.containsKey(i)) i
        ];
        if (missing.isNotEmpty) {
          failure = 'incomplete transfer (${missing.length} missing chunk(s))';
          return;
        }
        completed = true;
      }
    } catch (e) {
      failure = '$e';
    } finally {
      _draining = false;
    }
  }

  void _releaseReservation() => DownloadRegistry.release(file.path);

  /// Flush and close the file, returning it for the success message.
  Future<File> finish() async {
    if (_concatMode) {
      final keys = _pending.keys.toList()..sort();
      final joined = keys.map((k) => _pending[k]!).join();
      _pending.clear();
      final bytes = base64Decode(joined);
      _sink ??= file.openWrite();
      _sink!.add(bytes);
      _bytesWritten += bytes.length;
    }
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
    _releaseReservation();
    if (_bytesWritten == 0 && expectedSize > 0) {
      throw Exception('no data received');
    }
    return file;
  }

  /// Give up: close the sink and remove the partial file so a failed transfer
  /// never leaves a truncated download behind.
  Future<void> abort() async {
    if (_aborted) return;
    _aborted = true;
    _pending.clear();
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {}
    _sink = null;
    _releaseReservation();
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

/// Previews stay in memory: they are capped at 512 KB and are rendered, not
/// saved.
class _PreviewState {
  final String filename;
  final Map<int, String> chunks = {};
  int totalChunks = 0;
  _PreviewState(this.filename);
}

class _UploadProgress {
  final String filename;
  final int totalChunks;
  final int totalBytes;
  final DateTime startedAt = DateTime.now();
  int sentChunks = 0;
  int sentBytes = 0;

  _UploadProgress(this.filename, this.totalChunks, this.totalBytes);

  String get rateLabel {
    final elapsed = DateTime.now().difference(startedAt).inMilliseconds / 1000;
    if (elapsed < 0.5 || sentBytes == 0) return '';
    final rate = sentBytes / elapsed;
    final speed = '${_FilesTabState.formatBytes(rate.toInt())}/s';
    if (totalBytes <= 0 || rate <= 0) return speed;
    final remaining = ((totalBytes - sentBytes) / rate).round();
    if (remaining <= 0) return speed;
    return '$speed · ${remaining}s';
  }
}
