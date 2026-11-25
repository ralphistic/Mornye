import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';

/// Keeps small decoded song thumbnails live independently of the ordinary
/// global LRU. An entire database page fits, even when Home and the player
/// are using the normal image cache. Release promptly on OS memory pressure.
class SongListDecodedArtworkCache {
  static const _maxEntries = 600;
  static const _maxBytes = 36 << 20;
  static final _pins = <Object, _PinnedSongImage>{};
  static int _bytes = 0;
  static int _generation = 0;
  static bool _listenerAttached = false;

  static void _ensureClearListener() {
    if (_listenerAttached) return;
    _listenerAttached = true;
    DownloadedEmbeddedCoverResolver.previewsCleared.addListener(clear);
  }

  static bool _touch(Object key) {
    final pin = _pins.remove(key);
    if (pin == null) return false;
    if (!PaintingBinding.instance.imageCache.statusForKey(key).live) {
      _release(pin);
      return false;
    }
    _pins[key] = pin;
    return true;
  }

  static void _pin(Object key, _PinnedSongImage pin) {
    final previous = _pins.remove(key);
    if (previous != null) _release(previous);
    _pins[key] = pin;
    _bytes += pin.bytes;
    while (_pins.length > _maxEntries || _bytes > _maxBytes) {
      _release(_pins.remove(_pins.keys.first)!);
    }
  }

  static void _release(_PinnedSongImage pin) {
    pin.stream.removeListener(pin.listener);
    _bytes -= pin.bytes;
  }

  static void clear() {
    _generation++;
    for (final pin in _pins.values) {
      _release(pin);
    }
    _pins.clear();
    _bytes = 0;
  }
}

class _PinnedSongImage {
  final ImageStream stream;
  final ImageStreamListener listener;
  final int bytes;

  const _PinnedSongImage(this.stream, this.listener, this.bytes);
}

/// Prepare every row of a bounded database page, not just its first viewport.
/// Use the exact image-cache key of Image.file(cacheWidth: ...) in song rows.
Future<void> prewarmSongListArtwork(
  Iterable<String> filePaths, {
  required int cacheWidth,
  required bool Function() isActive,
  required Future<String?> Function(String) resolve,
  int? initialRows,
}) async {
  SongListDecodedArtworkCache._ensureClearListener();
  final generation = SongListDecodedArtworkCache._generation;
  bool active() =>
      isActive() && generation == SongListDecodedArtworkCache._generation;
  final candidates = initialRows == null ? filePaths : filePaths.take(initialRows);
  final paths = candidates
      .where(DownloadedEmbeddedCoverResolver.isLocalFlac)
      .toSet()
      .toList(growable: false);

  Future<void> warm(String path) async {
    try {
      final coverPath = await resolve(path);
      if (!active() || coverPath == null) return;
      final provider = ResizeImage.resizeIfNeeded(
        cacheWidth,
        null,
        FileImage(File(coverPath)),
      );
      final key = await provider.obtainKey(ImageConfiguration.empty);
      if (!active() || SongListDecodedArtworkCache._touch(key)) return;
      final stream = provider.resolve(ImageConfiguration.empty);
      final ready = Completer<void>();
      var bytes = 0;
      final listener = ImageStreamListener(
        (image, _) {
          bytes = image.image.width * image.image.height * 4;
          image.dispose();
          if (!ready.isCompleted) ready.complete();
        },
        onError: (Object error, StackTrace? stackTrace) {
          if (!ready.isCompleted) ready.complete();
        },
      );
      stream.addListener(listener);
      var pinned = false;
      try {
        await ready.future.timeout(const Duration(seconds: 2));
        if (active() && bytes > 0) {
          SongListDecodedArtworkCache._pin(
            key,
            _PinnedSongImage(stream, listener, bytes),
          );
          pinned = true;
        }
      } finally {
        if (!pinned) stream.removeListener(listener);
      }
    } catch (_) {
      // Damaged or unavailable artwork must not block the rest of the list.
    }
  }

  const batchSize = 4;
  for (var index = 0; index < paths.length && active(); index += batchSize) {
    await Future.wait(paths.skip(index).take(batchSize).map(warm));
  }
}
