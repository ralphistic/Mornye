import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';

/// The same image-cache key used by Image.file(cacheWidth: ...) in song rows.
/// Resolve only the initial viewport and a small scroll buffer. Native
/// extraction stays bounded, and the remainder of the library stays lazy.
Future<void> prewarmSongListArtwork(
  Iterable<String> filePaths, {
  required int cacheWidth,
  required bool Function() isActive,
  required Future<String?> Function(String) resolve,
  int initialRows = 18,
}) async {
  final paths = filePaths
      .take(initialRows)
      .where(DownloadedEmbeddedCoverResolver.isLocalFlac)
      .toSet()
      .toList(growable: false);

  Future<void> warm(String path) async {
    try {
      final coverPath = await resolve(path);
      if (!isActive() || coverPath == null) return;
      final provider = ResizeImage.resizeIfNeeded(
        cacheWidth,
        null,
        FileImage(File(coverPath)),
      );
      final stream = provider.resolve(ImageConfiguration.empty);
      final ready = Completer<void>();
      final listener = ImageStreamListener(
        (image, _) {
          image.dispose();
          if (!ready.isCompleted) ready.complete();
        },
        onError: (Object error, StackTrace? stackTrace) {
          if (!ready.isCompleted) ready.complete();
        },
      );
      stream.addListener(listener);
      try {
        // A damaged or inaccessible preview cannot hold the list forever.
        await ready.future.timeout(const Duration(seconds: 2));
      } finally {
        stream.removeListener(listener);
      }
    } catch (_) {
      // The row keeps its ordinary recovery/placeholder behavior.
    }
  }

  // Do not enqueue an entire page as foreground work ahead of playback.
  for (var index = 0; index < paths.length && isActive(); index += 2) {
    await Future.wait([
      warm(paths[index]),
      if (index + 1 < paths.length) warm(paths[index + 1]),
    ]);
  }
}
