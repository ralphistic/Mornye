part of 'downloaded_embedded_cover_resolver.dart';

/// Prepared, full-display-size artwork for the current playback neighbourhood.
/// The source signature is checked before synchronous publication; a cold
/// preparation verifies the FLAC metadata fingerprint and never uses scan art.
/// Decoded pixels are owned independently of Flutter's evictable image cache.
class PlaybackArtworkCache {
  static const _maxBytes = 96 << 20;
  static const _maxSources = 180;
  static const _maxImages = 48;
  static final _entries = <String, _PlaybackCover>{};
  // System artwork must not wait for the Flutter renderer.
  static final _fileEntries = <String, ({String signature, String path})>{};
  static final _filePending = <String, Future<String?>>{};
  static final _fileTokens = <String, Object>{};
  static int _fileEpoch = 0;
  static final _images = <(String, int), ui.Image>{};
  static final _pending = <(String, int), Future<String?>>{};
  static final _tokens = <String, Object>{};
  static int _epoch = 0;
  static int _bytes = 0;
  static bool _suspended = false;

  static bool supports(String source) =>
      source.startsWith('/') && isLocalFlacArtworkSource(source);

  @visibleForTesting
  static int? displayWidthForTesting;

  static int get displayWidth {
    if (displayWidthForTesting != null) return displayWidthForTesting!;
    final views = ui.PlatformDispatcher.instance.views;
    final width = views.isEmpty ? 0 : views.first.physicalSize.shortestSide.round();
    return width > 0 ? width : 1200;
  }

  /// A bounded queue neighbourhood sized to fit even if every cover differs.
  /// Same-image albums share decoded pixels, not one bitmap per song.
  static int get lookAhead {
    final width = displayWidth;
    return (_maxBytes ~/ (width * width * 4) - 4).clamp(2, 12).toInt();
  }

  static String? _signature(String source) {
    try {
      return SongListArtworkCache._signature(File(source).statSync());
    } catch (_) {
      return null;
    }
  }

  static _PlaybackCover? _ready(String source, int width) {
    if (_suspended ||
        DownloadedEmbeddedCoverResolver._pendingRefresh.contains(source)) {
      return null;
    }
    final entry = _entries[source];
    if (entry == null ||
        entry.width != width ||
        entry.signature != _signature(source) ||
        !File(entry.previewPath).existsSync()) {
      return null;
    }
    final imageKey = (entry.digest, entry.width);
    final image = _images.remove(imageKey);
    if (image == null) return null;
    _images[imageKey] = image;
    _entries
      ..remove(source)
      ..[source] = entry;
    return entry;
  }

  /// Safe to call before publishing a MediaItem; no native extraction or
  /// image decoding is done here.
  static String? readyPath(String source, {int? width}) =>
      _ready(source, width ?? displayWidth)?.previewPath;

  /// A verified preview file for native Now Playing, independent of dart:ui.
  static String? readyFilePath(String source) {
    if (_suspended ||
        DownloadedEmbeddedCoverResolver._pendingRefresh.contains(source)) {
      return null;
    }
    final entry = _fileEntries[source];
    if (entry == null || entry.signature != _signature(source) ||
        !File(entry.path).existsSync()) return null;
    _fileEntries
      ..remove(source)
      ..[source] = entry;
    return entry.path;
  }

  static Future<String?> prepareFile(String source) {
    if (!supports(source) || _suspended) return Future.value(null);
    final ready = readyFilePath(source);
    if (ready != null) return Future.value(ready);
    final existing = _filePending[source];
    if (existing != null) return existing;
    final epoch = _fileEpoch;
    final token = Object();
    _fileTokens[source] = token;
    final future = _prepareFile(source, epoch, token);
    _filePending[source] = future;
    unawaited(future.then((_) {
      if (identical(_filePending[source], future)) _filePending.remove(source);
      if (identical(_fileTokens[source], token)) _fileTokens.remove(source);
    }));
    return future;
  }

  static Future<String?> _prepareFile(
    String source, int epoch, Object token,
  ) async {
    bool active() => !_suspended && epoch == _fileEpoch &&
        identical(_fileTokens[source], token);
    try {
      final signature = _signature(source);
      if (signature == null) {
        final path = await DownloadedEmbeddedCoverResolver.resolveOrExtract(
          source, requireFreshExtraction: true,
        );
        return active() ? path : null;
      }
      final forced = DownloadedEmbeddedCoverResolver._pendingRefresh.remove(source);
      final path = await DownloadedEmbeddedCoverResolver._ensureCover(
        source, forceRefresh: forced, verifyExistingFlac: true, isForeground: true,
      );
      if (!active() || path == null || _signature(source) != signature) return null;
      final fingerprint =
          await DownloadedEmbeddedCoverResolver._nativeFlacMetadataFingerprint(source);
      if (!active() || _signature(source) != signature) return null;
      if (fingerprint == null) return path;
      final expected = DownloadedEmbeddedCoverResolver._persistentFileName(
        source, null, content: 'f1_$fingerprint',
      );
      if (p.basename(path) != expected || !File(path).existsSync()) return null;
      _fileEntries
        ..remove(source)
        ..[source] = (signature: signature, path: path);
      while (_fileEntries.length > _maxSources) {
        _fileEntries.remove(_fileEntries.keys.first);
      }
      return path;
    } catch (_) {
      return null;
    }
  }

  static ui.Image? imageForPath(String path, int? width) {
    if (width == null || _suspended) return null;
    for (final entry in _entries.values) {
      if (entry.previewPath != path || entry.width < width) continue;
      final imageKey = (entry.digest, entry.width);
      final image = _images.remove(imageKey);
      if (image == null) continue;
      _images[imageKey] = image;
      return image.clone();
    }
    return null;
  }

  static bool hasImage(String path, int? width) {
    final image = imageForPath(path, width);
    if (image == null) return false;
    image.dispose();
    return true;
  }

  static Future<String?> prepare(String source, {int? width}) {
    if (!supports(source) || _suspended) return Future.value(null);
    final targetWidth = width ?? displayWidth;
    final ready = readyPath(source, width: targetWidth);
    if (ready != null) return Future.value(ready);
    final key = (source, targetWidth);
    final existing = _pending[key];
    if (existing != null) return existing;
    final epoch = _epoch;
    final token = _tokens.putIfAbsent(source, Object.new);
    final future = _prepare(source, targetWidth, epoch, token);
    _pending[key] = future;
    unawaited(future.then((_) {
      if (identical(_pending[key], future)) _pending.remove(key);
      if (!_pending.keys.any((key) => key.$1 == source) &&
          identical(_tokens[source], token)) {
        _tokens.remove(source);
      }
    }));
    return future;
  }

  static Future<String?> _prepare(
    String source,
    int width,
    int epoch,
    Object token,
  ) async {
    bool active() =>
        !_suspended && epoch == _epoch && identical(_tokens[source], token);
    try {
      final signature = _signature(source);
      final path = await prepareFile(source);
      if (!active() || path == null || _signature(source) != signature) return null;
      if (signature == null || readyFilePath(source) != path) return path;
      final bytes = await File(path).readAsBytes();
      if (!active() || _signature(source) != signature) return null;
      final digest = sha256.convert(bytes).toString();
      final key = (digest, width);
      var image = _images.remove(key);
      if (image != null) {
        _images[key] = image;
      } else {
        image = await _decode(bytes, width);
        if (!active() || _signature(source) != signature) {
          image.dispose();
          return null;
        }
        // Another preparation of the same album may have decoded it while
        // we awaited the codec; keep exactly one cache-owned handle.
        final duplicate = _images.remove(key);
        if (duplicate != null) {
          image.dispose();
          image = duplicate;
        } else {
          _bytes += image.width * image.height * 4;
        }
        _images[key] = image;
      }
      if (!active() || _signature(source) != signature) return null;
      _entries
        ..remove(source)
        ..[source] = _PlaybackCover(path, signature, digest, width);
      while (_entries.length > _maxSources) {
        _entries.remove(_entries.keys.first);
      }
      while (_images.length > _maxImages || _bytes > _maxBytes) {
        final victim = _images.remove(_images.keys.first)!;
        _bytes -= victim.width * victim.height * 4;
        victim.dispose();
      }
      return path;
    } catch (_) {
      // Failed preparation never publishes an old source's artwork.
      return null;
    }
  }

  static Future<ui.Image> _decode(typed.Uint8List bytes, int width) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        final targetWidth = width.clamp(1, descriptor.width).toInt();
        final targetHeight = (descriptor.height * targetWidth / descriptor.width)
            .round().clamp(1, descriptor.height).toInt();
        final codec = await descriptor.instantiateCodec(
          targetWidth: targetWidth,
          targetHeight: targetHeight,
        );
        try {
          return (await codec.getNextFrame()).image;
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

  static void invalidate(String source) {
    _entries.remove(source);
    _tokens.remove(source);
    _pending.removeWhere((key, _) => key.$1 == source);
    _fileEntries.remove(source);
    _filePending.remove(source);
    _fileTokens.remove(source);
  }

  static void clear() {
    clearDecoded();
    _fileEpoch++;
    _fileEntries.clear();
    _filePending.clear();
    _fileTokens.clear();
  }

  /// Free GPU memory without discarding verified native artwork files.
  static void clearDecoded() {
    _epoch++;
    _entries.clear();
    _tokens.clear();
    _pending.clear();
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
    _bytes = 0;
  }

  static void _suspend() {
    _suspended = true;
    clear();
  }

  static void _resume() => _suspended = false;
}

class _PlaybackCover {
  const _PlaybackCover(this.previewPath, this.signature, this.digest, this.width);
  final String previewPath;
  final String signature;
  final String digest;
  final int width;
}
