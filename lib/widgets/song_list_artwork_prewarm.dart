import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';

/// Owns small, decoded song-row images independently of Flutter's global
/// image-cache eviction policy. Visible widgets hold their own image handles.
class SongListDecodedArtworkCache {
  static const _maxEntries = 600;
  static const _maxBytes = 36 << 20;
  static final _images = <(String, int), ui.Image>{};
  static int _bytes = 0;
  static int _generation = 0;
  static bool _listenerAttached = false;
  static final _memoryObserver = _SongListMemoryObserver();
  static final _pending = <(String, int), Future<void>>{};

  static void _ensureClearListener() {
    if (_listenerAttached) return;
    _listenerAttached = true;
    DownloadedEmbeddedCoverResolver.previewsCleared.addListener(clear);
    WidgetsBinding.instance.addObserver(_memoryObserver);
  }

  static int _cost(ui.Image image) => image.width * image.height * 4;

  static ui.Image? _touch((String, int) key) {
    final image = _images.remove(key);
    if (image != null) _images[key] = image;
    return image;
  }

  /// Returns a separate handle; the caller must dispose it. The backing
  /// pixels remain valid if the cache evicts its own handle.
  static ui.Image? imageFor(String path, int cacheWidth) =>
      _touch((path, cacheWidth))?.clone();

  /// Used only for the current track or a details transition, never by
  /// every scrolling row. The caller can draw an existing thumbnail now.
  static int? preparedWidth(String path) {
    int? best;
    for (final key in _images.keys) {
      if (key.$1 == path && (best == null || key.$2 > best)) best = key.$2;
    }
    return best;
  }

  static Future<void> prepare(String path, int cacheWidth) async {
    final key = (path, cacheWidth);
    if (_touch(key) != null) return;
    final existing = _pending[key];
    if (existing != null) return existing;
    final generation = _generation;
    final future = () async {
      final image = await _decodeSongThumbnail(path, cacheWidth);
      if (generation == _generation) {
        _put(key, image);
      } else {
        image.dispose();
      }
    }();
    _pending[key] = future;
    try {
      await future;
    } finally {
      if (identical(_pending[key], future)) _pending.remove(key);
    }
  }

  static void _put((String, int) key, ui.Image image) {
    final previous = _images.remove(key);
    if (previous != null) _release(previous);
    _images[key] = image;
    _bytes += _cost(image);
    while (_images.length > _maxEntries || _bytes > _maxBytes) {
      _release(_images.remove(_images.keys.first)!);
    }
  }

  static void _release(ui.Image image) {
    _bytes -= _cost(image);
    image.dispose();
  }

  static void clear() {
    _generation++;
    _pending.clear();
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
    _bytes = 0;
  }
}

class _SongListMemoryObserver with WidgetsBindingObserver {
  @override
  void didHaveMemoryPressure() => SongListDecodedArtworkCache.clear();
}

/// A prepared thumbnail is rendered on the first frame without opening or
/// decoding a file. For a real cache miss, keep the normal local image path.
class SongListPreparedImage extends StatefulWidget {
  const SongListPreparedImage({
    super.key,
    required this.path,
    required this.cacheWidth,
    required this.width,
    required this.height,
    required this.placeholder,
  });

  final String path;
  final int cacheWidth;
  final double? width;
  final double? height;
  final Widget placeholder;

  @override
  State<SongListPreparedImage> createState() => _SongListPreparedImageState();
}

class _SongListPreparedImageState extends State<SongListPreparedImage> {
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    _image = SongListDecodedArtworkCache.imageFor(widget.path, widget.cacheWidth);
  }

  @override
  void didUpdateWidget(covariant SongListPreparedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sameImage = oldWidget.path == widget.path &&
        oldWidget.cacheWidth == widget.cacheWidth;
    if (sameImage && _image != null) return;
    final next = SongListDecodedArtworkCache.imageFor(widget.path, widget.cacheWidth);
    _image?.dispose();
    _image = next;
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image != null) {
      return RawImage(
        image: image,
        width: widget.width,
        height: widget.height,
        fit: BoxFit.cover,
        filterQuality: ui.FilterQuality.medium,
      );
    }
    return Image.file(
      File(widget.path),
      width: widget.width,
      height: widget.height,
      fit: BoxFit.cover,
      cacheWidth: widget.cacheWidth,
      gaplessPlayback: false,
      frameBuilder: (_, child, frame, _) =>
          frame == null ? widget.placeholder : child,
      errorBuilder: (_, _, _) => widget.placeholder,
    );
  }
}

Future<ui.Image> _decodeSongThumbnail(String path, int cacheWidth) async {
  final buffer = await ui.ImmutableBuffer.fromFilePath(path);
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      final longest = descriptor.width > descriptor.height
          ? descriptor.width
          : descriptor.height;
      final scale = longest > cacheWidth ? cacheWidth / longest : 1.0;
      final width = (descriptor.width * scale).round().clamp(1, cacheWidth).toInt();
      final height = (descriptor.height * scale).round().clamp(1, cacheWidth).toInt();
      final codec = await descriptor.instantiateCodec(
        targetWidth: width,
        targetHeight: height,
      );
      try {
        final frame = await codec.getNextFrame();
        return frame.image;
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

/// Prepare every row of a bounded database page. No reliance on the
/// ordinary image cache retaining a previously decoded provider.
Future<void> prewarmSongListArtwork(
  Iterable<String> filePaths, {
  required int cacheWidth,
  required bool Function() isActive,
  required Future<String?> Function(String) resolve,
  int? initialRows,
  ValueListenable<bool>? transitioning,
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

  Future<void> waitForMotion() async {
    final moving = transitioning;
    if (moving == null) return;
    while (active() && moving.value) {
      final ready = Completer<void>();
      void changed() {
        if (!moving.value && !ready.isCompleted) ready.complete();
      }
      moving.addListener(changed);
      try {
        changed();
        await ready.future;
      } finally {
        moving.removeListener(changed);
      }
    }
  }

  Future<void> warm(String path) async {
    try {
      final coverPath = await resolve(path);
      if (!active() || coverPath == null) return;
      if (transitioning?.value == true) await waitForMotion();
      if (!active()) return;
      await SongListDecodedArtworkCache.prepare(coverPath, cacheWidth);
    } catch (_) {
      // Damaged or unavailable artwork must not block the remaining rows.
    }
  }

  const batchSize = 4;
  for (var index = 0; index < paths.length && active(); index += batchSize) {
    if (transitioning?.value == true) await waitForMotion();
    if (!active()) break;
    await Future.wait(paths.skip(index).take(batchSize).map(warm));
  }
}

/// Never hold database rows hostage to artwork I/O. Preparation can continue
/// in the existing provider while the user scrolls; visible misses retain
/// the normal on-demand path. The original future is not canceled by timeout.
Future<void> waitForSongPageArtwork(
  Future<void> preparation, {
  Duration budget = const Duration(milliseconds: 500),
}) => preparation.timeout(budget, onTimeout: () {});
