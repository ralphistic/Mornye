import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/song_list_artwork_prewarm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(SongListDecodedArtworkCache.clear);

  testWidgets('prepares the same decoded image cache key as the song row', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp('song-prewarm');
      final picture = File('${directory.path}/cover.png');
      final cache = PaintingBinding.instance.imageCache;
      final calls = <String>[];
      try {
        // Valid 1x1 PNG, enough to exercise a real image decode.
        await picture.writeAsBytes(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aWZkAAAAASUVORK5CYII=',
          ),
        );
        final rowProvider = ResizeImage.resizeIfNeeded(
          112,
          null,
          FileImage(picture),
        );
        final key = await rowProvider.obtainKey(ImageConfiguration.empty);
        cache.evict(key);
        await prewarmSongListArtwork(
          ['/music/one.flac', '/music/two.mp3', '/music/three.flac'],
          cacheWidth: 112,
          initialRows: 2,
          isActive: () => true,
          resolve: (path) async {
            calls.add(path);
            return picture.path;
          },
        );
        expect(calls, ['/music/one.flac']);
        expect(cache.containsKey(key), isTrue);
        cache.evict(key);
      } finally {
        await directory.delete(recursive: true);
      }
    });
  });

  testWidgets('decoded covers survive the normal image-cache entry limit', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp('song-pins');
      final cache = PaintingBinding.instance.imageCache;
      final previousLimit = cache.maximumSize;
      final providers = <ImageProvider<Object>>[];
      try {
        cache.maximumSize = 2;
        final paths = <String>[];
        final covers = <String, String>{};
        for (var i = 0; i < 24; i++) {
          final song = '/music/song-$i.flac';
          final picture = File('${directory.path}/cover-$i.png');
          await picture.writeAsBytes(base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aWZkAAAAASUVORK5CYII=',
          ));
          paths.add(song);
          covers[song] = picture.path;
          providers.add(ResizeImage.resizeIfNeeded(112, null, FileImage(picture)));
        }
        await prewarmSongListArtwork(
          paths,
          cacheWidth: 112,
          isActive: () => true,
          resolve: (path) async => covers[path],
        );
        for (final provider in providers) {
          final key = await provider.obtainKey(ImageConfiguration.empty);
          expect(cache.statusForKey(key).live, isTrue);
          var immediatelyAvailable = false;
          final stream = provider.resolve(ImageConfiguration.empty);
          final listener = ImageStreamListener((image, synchronous) {
            immediatelyAvailable = synchronous;
            image.dispose();
          });
          stream.addListener(listener);
          expect(immediatelyAvailable, isTrue);
          stream.removeListener(listener);
        }
      } finally {
        SongListDecodedArtworkCache.clear();
        for (final provider in providers) {
          cache.evict(await provider.obtainKey(ImageConfiguration.empty));
        }
        cache.maximumSize = previousLimit;
        await directory.delete(recursive: true);
      }
    });
  });

  test('prepares every FLAC row in a full page, including beyond row 18', () async {
    final paths = List.generate(300, (i) => '/music/$i.flac');
    final calls = <String>[];
    await prewarmSongListArtwork(
      paths,
      cacheWidth: 112,
      isActive: () => true,
      resolve: (path) async {
        calls.add(path);
        return null;
      },
    );
    expect(calls, paths);
  });

  test('stops warming once the page is no longer active', () async {
    var active = true;
    final calls = <String>[];
    await prewarmSongListArtwork(
      List.generate(10, (i) => '/music/$i.flac'),
      cacheWidth: 112,
      isActive: () => active,
      resolve: (path) async {
        calls.add(path);
        active = false;
        return null;
      },
    );
    expect(calls, hasLength(4));
  });
}
