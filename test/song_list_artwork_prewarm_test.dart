import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/song_list_artwork_prewarm.dart';

Future<List<int>> _testPng() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xff4477aa), ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(224, 224);
  picture.dispose();
  try {
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
  } finally {
    image.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(SongListDecodedArtworkCache.clear);

  testWidgets('prepares only requested FLAC rows', (tester) async {
    await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp('song-prewarm');
      final picture = File('${directory.path}/cover.png');
      final calls = <String>[];
      try {
        await picture.writeAsBytes(await _testPng());
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
        final prepared = SongListDecodedArtworkCache.imageFor(picture.path, 112);
        expect(prepared, isNotNull);
        expect(prepared!.width, 112);
        expect(prepared.height, 112);
        prepared.dispose();
      } finally {
        await directory.delete(recursive: true);
      }
    });
  });

  testWidgets('all 300 real covers render from decoded cache on first frame', (
    tester,
  ) async {
    Directory? directory;
    final paths = <String>[];
    final covers = <String, String>{};
    final cache = PaintingBinding.instance.imageCache;
    final previousLimit = cache.maximumSize;
    try {
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('song-page');
        final bytes = await _testPng();
        cache.maximumSize = 2;
        for (var i = 0; i < 300; i++) {
          final song = '/music/song-$i.flac';
          final picture = File('${directory!.path}/cover-$i.png');
          await picture.writeAsBytes(bytes);
          paths.add(song);
          covers[song] = picture.path;
        }
        await prewarmSongListArtwork(
          paths,
          cacheWidth: 112,
          isActive: () => true,
          resolve: (path) async => covers[path],
        );
        cache.clear();
        cache.clearLiveImages();
        for (final song in paths) {
          final image = SongListDecodedArtworkCache.imageFor(covers[song]!, 112);
          expect(image, isNotNull, reason: song);
          expect(image!.width, 112);
          expect(image.height, 112);
          image.dispose();
        }
        // Prove the subsequent widget frames need neither the ordinary image
        // cache nor disk I/O. The image handles already own the decoded pixels.
        await directory!.delete(recursive: true);
        directory = null;
      });
      for (final i in [0, 17, 18, 150, 299, 0]) {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: SongListPreparedImage(
                key: ValueKey(i),
                path: covers[paths[i]]!,
                cacheWidth: 112,
                width: 56,
                height: 56,
                placeholder: const Text('loading'),
              ),
            ),
          ),
        );
        final raw = tester.widget<RawImage>(find.byType(RawImage));
        expect(raw.image, isNotNull, reason: 'first frame for row $i');
        expect(find.text('loading'), findsNothing);
      }
      // An on-screen widget has its own handle even after a memory-pressure
      // eviction. Its frame must remain valid.
      tester.binding.handleMemoryPressure();
      await tester.pump();
      expect(SongListDecodedArtworkCache.imageFor(covers[paths.first]!, 112), isNull);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      SongListDecodedArtworkCache.clear();
      cache.maximumSize = previousLimit;
      if (directory != null) {
        await tester.runAsync(() => directory!.delete(recursive: true));
      }
    }
  });

  testWidgets('a slow thumbnail cannot block a page beyond its time budget', (
    tester,
  ) async {
    final extraction = Completer<void>();
    var released = false;
    final wait = waitForSongPageArtwork(extraction.future).then((_) {
      released = true;
    });
    await tester.pump(const Duration(milliseconds: 499));
    expect(released, isFalse);
    await tester.pump(const Duration(milliseconds: 1));
    expect(released, isTrue);
    expect(extraction.isCompleted, isFalse);
    extraction.complete();
    await wait;
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

  test('bulk song preparation yields to a player transition', () async {
    final moving = ValueNotifier(false);
    final release = Completer<void>();
    final started = Completer<void>();
    final calls = <String>[];
    final warm = prewarmSongListArtwork(
      List.generate(8, (i) => '/music/$i.flac'),
      cacheWidth: 112,
      isActive: () => true,
      transitioning: moving,
      resolve: (path) async {
        calls.add(path);
        if (path == '/music/0.flac') {
          started.complete();
          await release.future;
        }
        return null;
      },
    );
    await started.future;
    moving.value = true;
    release.complete();
    await Future<void>.delayed(Duration.zero);
    final duringMotion = List.of(calls);
    moving.value = false;
    await warm;
    expect(duringMotion, hasLength(4));
    expect(calls, hasLength(8));
    moving.dispose();
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
