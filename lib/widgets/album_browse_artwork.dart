import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';
import 'package:mornye/widgets/cached_cover_image.dart';

/// Use the same content-verified, persistent FLAC thumbnails as the song
/// list. A missing or failed embedded picture must never reveal old scan art.
String? albumBrowsePreviewPath(
  String filePath,
  String? cover, {
  VoidCallback? onChanged,
}) {
  if (SongListArtworkCache.supports(filePath)) {
    final embedded = SongListArtworkCache.resolve(
      filePath, onChanged: onChanged,
    );
    return embedded ??
        (SongListArtworkCache.hasNoEmbeddedCover(filePath)
            ? coverFilePath(cover)
            : null);
  }
  return coverFilePath(cover);
}

Future<String?> prepareAlbumBrowsePreviewPath(
  String filePath,
  String? cover,
) async {
  if (SongListArtworkCache.supports(filePath)) {
    final embedded = await SongListArtworkCache.prepare(filePath);
    return embedded ??
        (SongListArtworkCache.hasNoEmbeddedCover(filePath)
            ? coverFilePath(cover)
            : null);
  }
  return coverFilePath(cover);
}

/// Small immediately drawable covers for the album grid. Independent of the
/// song list and Flutter's ordinary image cache: a large grid cannot evict
/// prepared song rows. The original full-quality cover still loads normally.
class AlbumBrowseArtworkCache with WidgetsBindingObserver {
  AlbumBrowseArtworkCache({
    this.maxEntries = 320,
    this.maxBytes = 32 << 20,
  }) : assert(maxEntries > 0), assert(maxBytes > 0);

  static final shared = AlbumBrowseArtworkCache();
  static const previewEdge = 160;
  final int maxEntries;
  final int maxBytes;
  final _images = <String, ui.Image>{};
  final _pending = <String, Future<void>>{};
  int _bytes = 0;
  int _generation = 0;
  bool _listening = false;

  int get generation => _generation;
  int get length => _images.length;
  int get bytes => _bytes;
  bool contains(String path) => _images.containsKey(path);

  void ensureListeners() {
    if (_listening) return;
    _listening = true;
    DownloadedEmbeddedCoverResolver.previewsCleared.addListener(clear);
    WidgetsBinding.instance.addObserver(this);
  }

  ui.Image? _touch(String path) {
    final image = _images.remove(path);
    if (image != null) _images[path] = image;
    return image;
  }

  /// An independent image handle for a visible cell.
  ui.Image? imageFor(String path) => _touch(path)?.clone();

  Future<void> prepare(String path) async {
    if (_touch(path) != null) return;
    final existing = _pending[path];
    if (existing != null) return existing;
    final generation = _generation;
    final future = _prepare(path, generation);
    _pending[path] = future;
    try {
      await future;
    } finally {
      if (identical(_pending[path], future)) _pending.remove(path);
    }
  }

  Future<void> _prepare(String path, int generation) async {
    ui.Image? image;
    try {
      image = await _decode(path);
      if (generation != _generation) return;
      final previous = _images.remove(path);
      if (previous != null) _release(previous);
      _images[path] = image;
      _bytes += _cost(image);
      image = null;
      while (_images.length > maxEntries || _bytes > maxBytes) {
        _release(_images.remove(_images.keys.first)!);
      }
    } catch (_) {
      // A missing cover cannot block the rest of the page.
    } finally {
      image?.dispose();
    }
  }

  static int _cost(ui.Image image) => image.width * image.height * 4;

  void _release(ui.Image image) {
    _bytes -= _cost(image);
    image.dispose();
  }

  void clear() {
    _generation++;
    _pending.clear();
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
    _bytes = 0;
  }

  @override
  void didHaveMemoryPressure() => clear();

  static Future<ui.Image> _decode(String path) async {
    final buffer = await ui.ImmutableBuffer.fromFilePath(path);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        // Bound the longest edge, including unusual non-square artwork.
        final longest = descriptor.width > descriptor.height
            ? descriptor.width : descriptor.height;
        final scale = longest > previewEdge ? previewEdge / longest : 1.0;
        final width = (descriptor.width * scale).round().clamp(1, previewEdge);
        final height = (descriptor.height * scale).round().clamp(1, previewEdge);
        final codec = await descriptor.instantiateCodec(
          targetWidth: width.toInt(), targetHeight: height.toInt(),
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
}

/// Bounded concurrent preparation of already-loaded database rows. Cancels
/// between batches on navigation, backgrounding, or memory/cache clearing.
Future<void> prewarmAlbumBrowseArtwork(
  Iterable<({String filePath, String? cover})> entries, {
  required AlbumBrowseArtworkCache cache,
  required bool Function() isActive,
  Future<String?> Function(String, String?) resolve =
      prepareAlbumBrowsePreviewPath,
}) async {
  final generation = cache.generation;
  bool active() => isActive() && cache.generation == generation;
  final candidates = entries.toSet().toList(growable: false);
  Future<void> warm(({String filePath, String? cover}) entry) async {
    if (!active()) return;
    try {
      final path = await resolve(entry.filePath, entry.cover);
      if (path != null && active()) await cache.prepare(path);
    } catch (_) {
      // Let the normal artwork path handle unavailable previews.
    }
  }

  const batchSize = 3;
  for (var i = 0; i < candidates.length && active(); i += batchSize) {
    await Future.wait(candidates.skip(i).take(batchSize).map(warm));
  }
}

/// Avoid expensive full-size file reads/decodes for cells newly encountered
/// in a fling. Existing full-quality cells never downgrade when scrolling
/// starts; new cells upgrade as soon as the scroll activity settles.
class AlbumBrowseCoverQuality extends StatefulWidget {
  const AlbumBrowseCoverQuality({
    super.key,
    required this.scrolling,
    required this.previewReady,
    required this.preview,
    required this.fullQuality,
  });

  final ValueListenable<bool>? scrolling;
  final bool previewReady;
  final Widget preview;
  final Widget fullQuality;

  @override
  State<AlbumBrowseCoverQuality> createState() =>
      _AlbumBrowseCoverQualityState();
}

class _AlbumBrowseCoverQualityState extends State<AlbumBrowseCoverQuality> {
  bool _showFull = false;

  void _allowFull() {
    if (!_showFull &&
        (!widget.previewReady || widget.scrolling?.value != true)) {
      setState(() => _showFull = true);
    }
  }

  @override
  void initState() {
    super.initState();
    _showFull = !widget.previewReady || widget.scrolling?.value != true;
    widget.scrolling?.addListener(_allowFull);
  }

  @override
  void didUpdateWidget(covariant AlbumBrowseCoverQuality oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrolling != widget.scrolling) {
      oldWidget.scrolling?.removeListener(_allowFull);
      widget.scrolling?.addListener(_allowFull);
    }
    if (!widget.previewReady || widget.scrolling?.value != true) {
      _showFull = true;
    }
  }

  @override
  void dispose() {
    widget.scrolling?.removeListener(_allowFull);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _showFull ? widget.fullQuality : widget.preview;
}

/// First-frame preview when prepared; ordinary file decoding on a genuine
/// miss. The caller uses this behind the full-quality album cover.
class AlbumBrowsePreparedImage extends StatefulWidget {
  const AlbumBrowsePreparedImage({
    super.key,
    required this.path,
    required this.cache,
    required this.placeholder,
  });

  final String path;
  final AlbumBrowseArtworkCache cache;
  final Widget placeholder;

  @override
  State<AlbumBrowsePreparedImage> createState() =>
      _AlbumBrowsePreparedImageState();
}

class _AlbumBrowsePreparedImageState extends State<AlbumBrowsePreparedImage> {
  ui.Image? _image;
  int _generation = -1;

  void _refresh() {
    _image?.dispose();
    _image = widget.cache.imageFor(widget.path);
    _generation = widget.cache.generation;
  }

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(covariant AlbumBrowsePreparedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path || oldWidget.cache != widget.cache ||
        _generation != widget.cache.generation || _image == null) {
      _refresh();
    }
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
      return RawImage(image: image, fit: BoxFit.cover,
          filterQuality: ui.FilterQuality.medium);
    }
    return Image.file(
      File(widget.path),
      fit: BoxFit.cover,
      cacheWidth: AlbumBrowseArtworkCache.previewEdge,
      gaplessPlayback: false,
      frameBuilder: (_, child, frame, _) =>
          frame == null ? widget.placeholder : child,
      errorBuilder: (_, _, _) => widget.placeholder,
    );
  }
}
