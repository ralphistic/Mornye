import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';
import 'package:mornye/widgets/album_browse_artwork.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backend = MethodChannel('com.zarz.mornye/backend');

  Future<void> writeFlac(File file, List<int> picture) async {
    List<int> be32(int value) => [
      (value >> 24) & 0xff,
      (value >> 16) & 0xff,
      (value >> 8) & 0xff,
      value & 0xff,
    ];
    final block = [
      ...be32(3),
      ...be32(10),
      ...ascii.encode('image/jpeg'),
      ...be32(0),
      ...List<int>.filled(16, 0),
      ...be32(picture.length),
      ...picture,
    ];
    await file.writeAsBytes([
      ...ascii.encode('fLaC'),
      0, 0, 0, 34,
      ...List<int>.filled(34, 0),
      0x86, ...be32(block.length).skip(1),
      ...block,
      0xff, 0xf8,
    ]);
  }

  Future<List<int>> png(ui.Color color) async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(color, ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(448, 224);
    picture.dispose();
    try {
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
    } finally {
      image.dispose();
    }
  }

  Future<void> expectThumbnail(String path, List<int> color) async {
    final codec = await ui.instantiateImageCodec(await File(path).readAsBytes());
    try {
      final frame = await codec.getNextFrame();
      try {
        expect(frame.image.width, 224);
        expect(frame.image.height, 112);
        final bytes = (await frame.image.toByteData())!;
        expect(bytes.buffer.asUint8List(bytes.offsetInBytes, 4), color);
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }

  testWidgets('small persistent row thumbnails keep colors and detect edits', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('row-cache');
      final previews = Directory('${root.path}/previews');
      final source = File('${root.path}/song.flac');
      final red = await png(const ui.Color(0xffff0000));
      final blue = await png(const ui.Color(0xff0000ff));
      var current = red;
      var extractions = 0;
      var failExtraction = false;
      DownloadedEmbeddedCoverResolver.setPersistentCacheDirectoryForTesting(previews);
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(backend, (call) async {
        expect(call.method, 'extractCoverToFile');
        extractions++;
        if (failExtraction) {
          return jsonEncode({'error': 'temporary cover read failure'});
        }
        await File((call.arguments as Map)['output_path'] as String)
            .writeAsBytes(current);
        return jsonEncode({'success': true});
      });
      try {
        await writeFlac(source, [1, 2, 3]);
        final timestamp = await source.lastModified();
        final size = await source.length();

        final first = (await SongListArtworkCache.prepare(source.path))!;
        expect(first, contains('song_rows_v1'));
        expect(extractions, 1);
        await expectThumbnail(first, [255, 0, 0, 255]);
        expect(SongListArtworkCache.resolve(source.path), first);
        expect(albumBrowsePreviewPath(source.path, '/old/scan.png'), first);
        expect(await prepareAlbumBrowsePreviewPath(source.path, '/old/scan.png'), first);
        expect(extractions, 1, reason: 'album previews share the verified thumbnail');

        await DownloadedEmbeddedCoverResolver.resetMemoryStateForTesting();
        expect(await SongListArtworkCache.prepare(source.path), first);
        expect(extractions, 1, reason: 'restart must reuse the small thumbnail');
        expect(SongListArtworkCache.resolve(source.path), first);

        await DownloadedEmbeddedCoverResolver.clearPersistentCache(
          preserveVerifiedFlacPreviews: true,
        );
        expect(await SongListArtworkCache.prepare(source.path), first);
        expect(extractions, 1, reason: 'unchanged full scan must not extract');

        // Change only embedded picture metadata, with same length and mtime.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        current = blue;
        await writeFlac(source, [4, 5, 6]);
        await source.setLastModified(timestamp);
        expect(await source.lastModified(), timestamp);
        expect(await source.length(), size);
        await DownloadedEmbeddedCoverResolver.resetMemoryStateForTesting();
        final changed = (await SongListArtworkCache.prepare(source.path))!;
        expect(changed, isNot(first));
        expect(extractions, 2);
        await expectThumbnail(changed, [0, 0, 255, 255]);
        expect(await File(first).exists(), isFalse);
        expect(albumBrowsePreviewPath(source.path, '/old/scan.png'), changed);

        // Full scan checks content, not merely source timestamps.
        current = red;
        await writeFlac(source, [7, 8, 9]);
        await source.setLastModified(timestamp);
        await DownloadedEmbeddedCoverResolver.clearPersistentCache(
          preserveVerifiedFlacPreviews: true,
        );
        final rescanned = (await SongListArtworkCache.prepare(source.path))!;
        expect(rescanned, isNot(changed));
        expect(extractions, 3);
        await expectThumbnail(rescanned, [255, 0, 0, 255]);

        // Explicit refresh survives process restart, even if stat is unchanged.
        current = blue;
        await DownloadedEmbeddedCoverResolver.scheduleRefreshForPath(
          source.path,
          force: true,
        );
        await DownloadedEmbeddedCoverResolver.resetMemoryStateForTesting();
        final forced = (await SongListArtworkCache.prepare(source.path))!;
        expect(extractions, 4);
        expect(forced, isNot(rescanned));
        await expectThumbnail(forced, [0, 0, 255, 255]);

        // A confirmed source edit followed by an extraction failure must
        // not continue showing an older thumbnail as if it were current.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await writeFlac(source, [10, 11, 12]);
        await source.setLastModified(timestamp);
        failExtraction = true;
        expect(await SongListArtworkCache.prepare(source.path), isNull);
        expect(SongListArtworkCache.resolve(source.path), isNull);
        expect(albumBrowsePreviewPath(source.path, '/old/scan.png'), isNull,
            reason: 'a failed extraction must not show an obsolete scan cover');
        expect(extractions, 5);

        await DownloadedEmbeddedCoverResolver.clearPersistentCache();
        expect(await previews.list().toList(), isEmpty);
        expect(await source.length(), size);
        expect(await source.lastModified(), timestamp);
      } finally {
        await DownloadedEmbeddedCoverResolver.resetMemoryStateForTesting(
          preservePersistentFiles: false,
        );
        DownloadedEmbeddedCoverResolver.setPersistentCacheDirectoryForTesting(null);
        messenger.setMockMethodCallHandler(backend, null);
        await root.delete(recursive: true);
      }
    });
  });
}
