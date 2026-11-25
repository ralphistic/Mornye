part of 'downloaded_embedded_cover_resolver.dart';

/// Small, persistent song-list thumbnails, separate from full-resolution
/// covers used by playback and metadata. Row builds only look up prepared
/// artwork; metadata verification and decoding happen during page preparation.
class SongListArtworkCache {
  static const _directoryName = 'song_rows_v1';
  static const _thumbnailEdge = 224;
  static const _maxMemoryEntries = 1200;
  static final _entries = LinkedHashMap<String, _SongRowCover>();
  static final _pending = <String, Future<String?>>{};
  static final _callbacks = <String, Set<VoidCallback>>{};
  static final _forced = <String>{};
  static final _verifiedAfterScan = <String>{};
  static final _retryAfter = <String, DateTime>{};
  static bool _suspended = false;
  static bool _verifyContent = false;
  static int _epoch = 0;
  static int _stageSequence = 0;
  static final changes = ValueNotifier<(String, int)>(('', 0));
  static Future<void>? _maintenance;
  static DateTime? _lastMaintenance;
  static int _writesSinceMaintenance = 0;

  static bool supports(String? path) =>
      DownloadedEmbeddedCoverResolver.isLocalFlac(path) &&
      !isContentUri(DownloadedEmbeddedCoverResolver.cleanFilePath(path));

  static bool hasNoEmbeddedCover(String? filePath) {
    final entry = _entries[DownloadedEmbeddedCoverResolver.cleanFilePath(filePath)];
    return entry != null && entry.previewPath == null;
  }

  static String? resolve(String? filePath, {VoidCallback? onChanged}) {
    final path = DownloadedEmbeddedCoverResolver.cleanFilePath(filePath);
    final entry = _entries[path];
    if (entry != null) {
      _touch(path, entry);
      return entry.previewPath;
    }
    if (_suspended || !supports(path)) return null;
    final retryAt = _retryAfter[path];
    if (retryAt != null && DateTime.now().isBefore(retryAt)) return null;
    if (onChanged != null) {
      _callbacks.putIfAbsent(path, () => <VoidCallback>{}).add(onChanged);
    }
    unawaited(prepare(path));
    return null;
  }

  static Future<String?> prepare(String filePath) async {
    final path = DownloadedEmbeddedCoverResolver.cleanFilePath(filePath);
    if (!supports(path)) {
      return DownloadedEmbeddedCoverResolver.resolveOrExtract(path);
    }
    if (_suspended) return null;
    final existing = _pending[path];
    if (existing != null) {
      final result = await existing;
      if (identical(_pending[path], existing)) _pending.remove(path);
      if (_forced.contains(path) && !_suspended) return prepare(path);
      return result;
    }
    final epoch = _epoch;
    final oldEntry = _entries[path];
    final forced = _forced.remove(path);
    final future = _prepare(path, epoch, forced);
    _pending[path] = future;
    try {
      final result = await future;
      if (!_suspended && epoch == _epoch && _entries.containsKey(path)) {
        _retryAfter.remove(path);
        if (oldEntry != null && oldEntry.previewPath != _entries[path]!.previewPath) {
          changes.value = (path, changes.value.$2 + 1);
        }
        final callbacks = _callbacks.remove(path);
        for (final callback in callbacks ?? const <VoidCallback>{}) {
          try {
            callback();
          } catch (_) {}
        }
      } else if (!_forced.contains(path)) {
        _callbacks.remove(path);
        _retryAfter[path] = DateTime.now().add(const Duration(seconds: 15));
      }
      return result;
    } finally {
      if (identical(_pending[path], future)) _pending.remove(path);
    }
  }

  static bool _current(String path, int epoch) =>
      !_suspended && epoch == _epoch && !_forced.contains(path);

  static void _touch(String path, _SongRowCover entry) {
    _entries
      ..remove(path)
      ..[path] = entry;
    while (_entries.length > _maxMemoryEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  static Future<void> _invalidate(String path) async {
    if (!supports(path)) return;
    _entries.remove(path);
    _retryAfter.remove(path);
    _verifiedAfterScan.remove(path);
    _forced.add(path);
    changes.value = (path, changes.value.$2 + 1);
    // Persist explicit invalidation across process death, even if a tag
    // editor preserves the ordinary source identity fields.
    try {
      final root = await DownloadedEmbeddedCoverResolver._getPersistentCacheDirectory();
      final directory = Directory(p.join(root.path, _directoryName));
      if (!await directory.exists()) return;
      final key = sha256.convert(utf8.encode(path)).toString();
      if (!_forced.contains(path)) return;
      await File(p.join(directory.path, '$key.dirty')).writeAsString('', flush: true);
    } catch (_) {}
  }

  static Future<void> _suspend() async {
    _suspended = true;
    _epoch++;
    await Future.wait(_pending.values.toList(growable: false));
    await _maintenance;
    _lastMaintenance = null;
    _writesSinceMaintenance = 0;
    _entries.clear();
    _pending.clear();
    _callbacks.clear();
    _retryAfter.clear();
    _forced.clear();
    _verifiedAfterScan.clear();
  }

  static void _resume({required bool verifyContent}) {
    _verifyContent = verifyContent;
    _suspended = false;
  }

  static void _resetForTesting() {
    if (_pending.isNotEmpty) {
      throw StateError('Cannot replace song artwork cache while work is active');
    }
    _epoch++;
    _entries.clear();
    _callbacks.clear();
    _retryAfter.clear();
    _forced.clear();
    _verifiedAfterScan.clear();
    _resume(verifyContent: false);
  }

  /// Include file change time as well as size and modification time. Explicit
  /// rescans also verify the complete FLAC metadata fingerprint, so restoring
  /// the original mtime cannot resurrect obsolete artwork.
  static String? _signature(FileStat stat) {
    if (stat.type != FileSystemEntityType.file || stat.size <= 0) return null;
    return '${stat.size}:${stat.modified.microsecondsSinceEpoch}:'
        '${stat.changed.microsecondsSinceEpoch}';
  }

  static Future<String?> _prepare(String path, int epoch, bool forced) async {
    try {
      final source = File(path);
      final signature = _signature(await source.stat());
      if (signature == null || !_current(path, epoch)) return null;
      final needsContentCheck = _verifyContent && !_verifiedAfterScan.contains(path);
      final memory = _entries[path];
      if (!forced &&
          !needsContentCheck &&
          memory != null &&
          memory.signature == signature &&
          (memory.previewPath == null || await File(memory.previewPath!).exists())) {
        if (!_current(path, epoch)) return null;
        _touch(path, memory);
        return memory.previewPath;
      }
      final root = await DownloadedEmbeddedCoverResolver._getPersistentCacheDirectory();
      final directory = Directory(p.join(root.path, _directoryName));
      if (!await directory.exists()) await directory.create(recursive: true);
      final key = sha256.convert(utf8.encode(path)).toString();
      final index = File(p.join(directory.path, '$key.json'));
      final dirty = File(p.join(directory.path, '$key.dirty'));
      forced = forced || await dirty.exists();
      _SongRowCover? disk;
      try {
        final data = jsonDecode(await index.readAsString()) as Map<String, dynamic>;
        if (data['source'] == path &&
            data['signature'] is String &&
            data['fingerprint'] is String) {
          final name = data['file'];
          if (name == null ||
              (name is String &&
                  name.startsWith('${key}_') &&
                  RegExp(r'^[0-9a-f]{64}_[0-9a-f]{64}\.png$').hasMatch(name))) {
            final preview = name == null ? null : p.join(directory.path, name as String);
            if (preview == null ||
                (await File(preview).exists() && await File(preview).length() > 0)) {
              disk = _SongRowCover(
                signature: data['signature'] as String,
                fingerprint: data['fingerprint'] as String,
                previewPath: preview,
              );
            }
          }
        }
      } catch (_) {
        // Missing or corrupt index is a cache miss, not proof of freshness.
      }
      if (!_current(path, epoch)) return null;

      String? fingerprint;
      if (!forced && disk != null) {
        if (disk.signature == signature && !needsContentCheck) {
          _touch(path, disk);
          return disk.previewPath;
        }
        fingerprint = await DownloadedEmbeddedCoverResolver._nativeFlacMetadataFingerprint(path);
        if (!_current(path, epoch)) return null;
        if (fingerprint != null && disk.fingerprint == fingerprint &&
            _signature(await source.stat()) == signature) {
          final updated = _SongRowCover(
            signature: signature,
            fingerprint: fingerprint,
            previewPath: disk.previewPath,
          );
          await _writeIndex(index, path, updated);
          if (!_current(path, epoch)) return null;
          _verifiedAfterScan.add(path);
          _touch(path, updated);
          return updated.previewPath;
        }
      }

      // A full-resolution extraction is needed only for an actual miss or
      // changed source. Reuse an already verified full preview when possible.
      fingerprint ??= await DownloadedEmbeddedCoverResolver._nativeFlacMetadataFingerprint(path);
      if (!_current(path, epoch)) return null;
      final fullEntry = DownloadedEmbeddedCoverResolver._cache[path];
      final expectedName = fingerprint == null
          ? null
          : DownloadedEmbeddedCoverResolver._persistentFileName(
              path, null, content: 'f1_$fingerprint',
            );
      final mustRefresh = forced ||
          (disk != null && disk.fingerprint != fingerprint) ||
          DownloadedEmbeddedCoverResolver.hasNoEmbeddedCover(path) ||
          (fullEntry != null &&
              (expectedName == null ||
                  p.basename(fullEntry.previewPath) != expectedName ||
                  !await File(fullEntry.previewPath).exists()));
      final preview = await DownloadedEmbeddedCoverResolver.resolveOrExtract(
        path,
        requireFreshExtraction: mustRefresh,
      );
      if (!_current(path, epoch)) return null;
      if (preview == null &&
          !DownloadedEmbeddedCoverResolver.hasNoEmbeddedCover(path)) {
        return null;
      }
      if (_signature(await source.stat()) != signature) return null;

      // Nonstandard containers remain on the conservative extraction path.
      if (fingerprint == null) {
        final entry = _SongRowCover(
          signature: signature,
          fingerprint: '',
          previewPath: preview,
        );
        _touch(path, entry);
        return preview;
      }
      String? thumbnail;
      if (preview != null) {
        final bytes = await _thumbnailBytes(preview);
        if (!_current(path, epoch) || _signature(await source.stat()) != signature) {
          return null;
        }
        final digest = sha256.convert(bytes).toString();
        thumbnail = p.join(directory.path, '${key}_$digest.png');
        final output = File(thumbnail);
        if (!await output.exists()) await _atomicBytes(output, bytes);
      }
      if (!_current(path, epoch) || _signature(await source.stat()) != signature) {
        return null;
      }
      final entry = _SongRowCover(
        signature: signature,
        fingerprint: fingerprint,
        previewPath: thumbnail,
      );
      await _writeIndex(index, path, entry);
      _writesSinceMaintenance++;
      if (!_current(path, epoch)) return null;
      await DownloadedEmbeddedCoverResolver._deleteFileIfPresent(dirty);
      if (!_current(path, epoch)) return null;
      _verifiedAfterScan.add(path);
      _touch(path, entry);
      final oldPath = disk?.previewPath;
      if (oldPath != null && oldPath != thumbnail) {
        await DownloadedEmbeddedCoverResolver._deleteFileIfPresent(File(oldPath));
      }
      return thumbnail;
    } catch (_) {
      return null;
    }
  }

  static Future<List<int>> _thumbnailBytes(String previewPath) async {
    final buffer = await ui.ImmutableBuffer.fromFilePath(previewPath);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        final scale = _thumbnailEdge /
            (descriptor.width > descriptor.height ? descriptor.width : descriptor.height);
        final codec = await descriptor.instantiateCodec(
          targetWidth: scale < 1 ? (descriptor.width * scale).round().clamp(1, _thumbnailEdge).toInt() : descriptor.width,
          targetHeight: scale < 1 ? (descriptor.height * scale).round().clamp(1, _thumbnailEdge).toInt() : descriptor.height,
        );
        try {
          final frame = await codec.getNextFrame();
          try {
            final bytes = await frame.image.toByteData(format: ui.ImageByteFormat.png);
            if (bytes == null) throw StateError('Unable to encode song artwork');
            return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
          } finally {
            frame.image.dispose();
          }
        } finally {
          codec.dispose();
        }
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  }

  /// Independent disk budget; sweep at most once per session or after many
  /// new writes, never once per row. Preserve prepared/visible thumbnails.
  static Future<void> maintain() async {
    if (_suspended) return;
    if (_maintenance != null) {
      await _maintenance;
      return;
    }
    // An unchanged warm launch creates no new disk entries. Do not compete
    // with scrolling by walking the cache directory in that case.
    if (_writesSinceMaintenance == 0 ||
        (_lastMaintenance != null && _writesSinceMaintenance < 128)) return;
    final epoch = _epoch;
    final future = _maintain(epoch);
    _maintenance = future;
    try {
      await future;
      _lastMaintenance = DateTime.now();
      _writesSinceMaintenance = 0;
    } finally {
      if (identical(_maintenance, future)) _maintenance = null;
    }
  }

  static Future<void> _maintain(int epoch) async {
    try {
      final root = await DownloadedEmbeddedCoverResolver._getPersistentCacheDirectory();
      final directory = Directory(p.join(root.path, _directoryName));
      if (!await directory.exists()) return;
      final records = <(File, FileStat)>[];
      var totalBytes = 0;
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        final stat = await entity.stat();
        totalBytes += stat.size;
        if (entity.path.endsWith('.json')) {
          records.add((entity, stat));
        }
      }
      const maxBytes = 320 << 20;
      const maxRecords = 2400;
      if (records.length <= maxRecords && totalBytes <= maxBytes) return;
      records.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
      var count = records.length;
      for (final (index, stat) in records) {
        if (_suspended || epoch != _epoch) return;
        if (count <= maxRecords && totalBytes <= maxBytes) break;
        try {
          final data = jsonDecode(await index.readAsString()) as Map<String, dynamic>;
          final source = data['source'];
          if (source is! String || _entries.containsKey(source) ||
              _pending.containsKey(source)) continue;
          final name = data['file'];
          if (name is String &&
              RegExp(r'^[0-9a-f]{64}_[0-9a-f]{64}\.png$').hasMatch(name)) {
            final thumbnail = File(p.join(directory.path, name));
            if (await thumbnail.exists()) {
              final length = await thumbnail.length();
              if (_entries.containsKey(source) || _pending.containsKey(source)) continue;
              await thumbnail.delete();
              totalBytes -= length;
            }
          }
          if (_entries.containsKey(source) || _pending.containsKey(source)) continue;
          await index.delete();
          count--;
          totalBytes -= stat.size;
        } catch (_) {}
      }
    } catch (_) {
      // Cache maintenance cannot block artwork display.
    }
  }

  static Future<void> _writeIndex(File index, String source, _SongRowCover entry) =>
      _atomicBytes(index, utf8.encode(jsonEncode({
        'source': source,
        'signature': entry.signature,
        'fingerprint': entry.fingerprint,
        'file': entry.previewPath == null ? null : p.basename(entry.previewPath!),
      })));

  static Future<void> _atomicBytes(File file, List<int> bytes) async {
    final stage = File('${file.path}.tmp_${DateTime.now().microsecondsSinceEpoch}_${_stageSequence++}');
    try {
      await stage.writeAsBytes(bytes, flush: true);
      await stage.rename(file.path);
    } finally {
      await DownloadedEmbeddedCoverResolver._deleteFileIfPresent(stage);
    }
  }
}

class _SongRowCover {
  final String signature;
  final String fingerprint;
  final String? previewPath;

  const _SongRowCover({
    required this.signature,
    required this.fingerprint,
    required this.previewPath,
  });
}
