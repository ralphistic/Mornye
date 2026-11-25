import 'dart:io';
import 'dart:ui' as ui;

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

  static void _ensureClearListener() {
    if (_listenerAttached) return;
    _listenerAttached = true;
    DownloadedEmbeddedCoverResolver.previewsCleared.addListener(clear);
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
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
    _bytes = 0;
  }
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
      final width = cacheWidth.clamp(1, descriptor.width).toInt();
      final height = (descriptor.height * width / descriptor.width)
          .round()
          .clamp(1, descriptor.height)
          .toInt();
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
      final key = (coverPath, cacheWidth);
      if (SongListDecodedArtworkCache._touch(key) != null) return;
      final image = await _decodeSongThumbnail(coverPath, cacheWidth);
      if (active()) {
        SongListDecodedArtworkCache._put(key, image);
      } else {
        image.dispose();
      }
    } catch (_) {
      // Damaged or unavailable artwork must not block the remaining rows.
    }
  }

  const batchSize = 4;
  for (var index = 0; index < paths.length && active(); index += batchSize) {
    await Future.wait(paths.skip(index).take(batchSize).map(warm));
  }
}
