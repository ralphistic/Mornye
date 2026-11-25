import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';
import 'package:mornye/widgets/player_artwork.dart';

import 'support/prepared_playback_artwork_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('prepared playback covers render correct pixels on every rapid skip frame', (tester) async {
    Directory? root;
    final files = <File>[];
    final paths = <String>[];
    final calls = <String>[];
    final ordinaryCache = PaintingBinding.instance.imageCache;
    try {
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('prepared-playback');
        DownloadedEmbeddedCoverResolver.setPersistentCacheDirectoryForTesting(
          Directory('${root!.path}/previews'),
        );
        mockPreparedArtworkExtraction(calls);
        for (var i = 0; i < 30; i++) {
          final source = File('${root!.path}/song-$i ?!#% 日本語.flac');
          await writeArtworkFlac(source, await artworkPng(i));
          files.add(source);
          final prepared = await PlaybackArtworkCache.prepare(source.path, width: 64);
          expect(prepared, isNotNull);
          paths.add(prepared!);
        }
        expect(calls, hasLength(30));
        ordinaryCache.clear();
        ordinaryCache.clearLiveImages();
      });
      Widget player(String? path, {bool pending = false}) => MaterialApp(
        home: PlayerArtwork(
          artUri: path,
          cacheWidth: 64,
          colorScheme: const ColorScheme.dark(),
          holdPendingArtwork: true,
          embeddedArtworkPending: pending,
        ),
      );

      // One widget pump per track, without an intervening pumpAndSettle.
      // Ordinary Flutter cache is empty, so a synchronous RawImage must
      // already own the actual correct pixels for the selected song.
      for (final index in [
        ...List.generate(30, (i) => i),
        ...List.generate(29, (i) => 28 - i),
      ]) {
        await tester.pumpWidget(player(Uri.file(paths[index]).toString()));
        expect(find.byIcon(Icons.music_note), findsNothing);
        final raw = tester.widget<RawImage>(find.byType(RawImage));
        expect(raw.image, isNotNull, reason: 'first frame of track $index');
        await tester.runAsync(() async {
          final bytes = (await raw.image!.toByteData(format: ui.ImageByteFormat.rawRgba))!;
          expect(bytes.buffer.asUint8List(bytes.offsetInBytes, 4),
              [index, 255 - index, 77, 255]);
        });
      }
      expect(calls, hasLength(30), reason: 'skips must not extract again');
      await tester.pumpWidget(player(null, pending: true));
      expect(find.byIcon(Icons.music_note), findsNothing);
      await tester.pumpWidget(player(null));
      expect(find.byIcon(Icons.music_note), findsOneWidget);

      await tester.runAsync(() async {
        final source = files.first;
        final old = paths.first;
        final size = await source.length();
        final timestamp = await source.lastModified();
        // Same-size, same-mtime edit still invalidates the prepared artwork.
        await Future<void>.delayed(const Duration(milliseconds: 25));
        await writeArtworkFlac(source, await artworkPng(120));
        await source.setLastModified(timestamp);
        expect(await source.length(), size);
        expect(await source.lastModified(), timestamp);
        expect(PlaybackArtworkCache.readyPath(source.path, width: 64), isNull);
        final changed = await PlaybackArtworkCache.prepare(source.path, width: 64);
        expect(changed, isNotNull);
        expect(changed, isNot(old));
        expect(calls, hasLength(31));
        final decoded = PlaybackArtworkCache.imageForPath(changed!, 64)!;
        try {
          final bytes = (await decoded.toByteData(format: ui.ImageByteFormat.rawRgba))!;
          expect(bytes.buffer.asUint8List(bytes.offsetInBytes, 4), [120, 135, 77, 255]);
        } finally {
          decoded.dispose();
        }
        expect(await PlaybackArtworkCache.prepare(source.path, width: 64), changed);
        expect(calls, hasLength(31), reason: 'unchanged verified preview is reused');
        await DownloadedEmbeddedCoverResolver.clearPersistentCache(
          preserveVerifiedFlacPreviews: true,
        );
        expect(PlaybackArtworkCache.readyPath(source.path, width: 64), isNull);
        expect(await PlaybackArtworkCache.prepare(source.path, width: 64), changed);
        expect(calls, hasLength(31), reason: 'unchanged rescan reuses verified disk art');
      });
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await DownloadedEmbeddedCoverResolver.resetMemoryStateForTesting(
          preservePersistentFiles: false,
        );
        DownloadedEmbeddedCoverResolver.setPersistentCacheDirectoryForTesting(null);
        clearPreparedArtworkExtraction();
        if (root != null) await root!.delete(recursive: true);
      });
      ordinaryCache.clear();
      ordinaryCache.clearLiveImages();
    }
  }, skip: Platform.isWindows);
}
