import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/album_browse_artwork.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/song_list_artwork_prewarm.dart';

Future<List<int>> _png(ui.Color color) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(color, ui.BlendMode.src);
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

  testWidgets('a warm grid has first-frame previews in both directions', (
    tester,
  ) async {
    final cache = AlbumBrowseArtworkCache();
    final global = PaintingBinding.instance.imageCache;
    final covers = <String>[];
    Directory? directory;
    try {
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('album-grid');
        final bytes = await _png(const ui.Color(0xff2468ac));
        // Enough distinct albums to exercise multiple pages, including
        // eviction of Flutter's much smaller ordinary cache.
        for (var i = 0; i < 280; i++) {
          final file = File('${directory!.path}/$i.png');
          await file.writeAsBytes(bytes);
          covers.add(file.path);
        }
        await prewarmAlbumBrowseArtwork(
          covers.map((path) => (filePath: '', cover: path)),
          cache: cache,
          isActive: () => true,
        );
        expect(cache.length, 280);
        expect(cache.bytes, 280 * 160 * 160 * 4);
        expect(cache.bytes, lessThanOrEqualTo(cache.maxBytes));
        expect(SongListDecodedArtworkCache.imageFor(covers.first, 160), isNull);
        global.clear();
        global.clearLiveImages();
        // The first frame must not need a file read or the global cache.
        await directory!.delete(recursive: true);
        directory = null;
      });
      for (final i in [0, 79, 152, 279, 221, 98, 0, 279]) {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: SizedBox.square(
                dimension: 176,
                child: AlbumBrowsePreparedImage(
                  key: ValueKey(i),
                  path: covers[i],
                  cache: cache,
                  placeholder: const Text('loading'),
                ),
              ),
            ),
          ),
        );
        final raw = tester.widget<RawImage>(find.byType(RawImage));
        expect(raw.image, isNotNull, reason: 'first frame, album $i');
        expect(raw.image!.width, 160);
        expect(raw.image!.height, 160);
        expect(find.text('loading'), findsNothing);
      }
      cache.didHaveMemoryPressure();
      expect(cache.length, 0);
      expect(cache.bytes, 0);
      await tester.pump();
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull,
          reason: 'visible image owns a handle independently of the cache');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      cache.clear();
      if (directory != null) {
        await tester.runAsync(() => directory!.delete(recursive: true));
      }
    }
  });

  testWidgets('cached preview stays visible while the original cover loads', (
    tester,
  ) async {
    final cache = AlbumBrowseArtworkCache();
    Directory? directory;
    try {
      late String preview;
      late String full;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('album-quality');
        preview = '${directory!.path}/preview.png';
        full = '${directory!.path}/full.png';
        final bytes = await _png(const ui.Color(0xff2468ac));
        await File(preview).writeAsBytes(bytes);
        await File(full).writeAsBytes(bytes);
        await cache.prepare(preview);
      });
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(devicePixelRatio: 1),
          child: Center(
            child: SizedBox.square(
              dimension: 224,
              child: LocalOrNetworkCoverImage(
                url: full,
                localCacheWidth: 224,
                fadeInDuration: Duration.zero,
                placeholder: (_) => AlbumBrowsePreparedImage(
                  path: preview,
                  cache: cache,
                  placeholder: const Text('loading'),
                ),
              ),
            ),
          ),
        ),
      ));
      expect(find.text('loading'), findsNothing);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image!.width, 160);
      // The full-quality image is loaded asynchronously by the existing
      // widget; it must replace the smaller preview, not remain blurry.
      await tester.runAsync(() async {
        final stream = ResizeImage(FileImage(File(full)), width: 224)
            .resolve(ImageConfiguration.empty);
        final ready = Completer<void>();
        final listener = ImageStreamListener((info, _) {
          info.dispose();
          if (!ready.isCompleted) ready.complete();
        }, onError: (error, stack) {
          if (!ready.isCompleted) ready.completeError(error, stack);
        });
        stream.addListener(listener);
        try {
          await ready.future.timeout(const Duration(seconds: 10));
        } finally {
          stream.removeListener(listener);
        }
      });
      await tester.pump();
      expect(tester.widget<RawImage>(find.byType(RawImage)).image!.width, 224);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      cache.clear();
      if (directory != null) {
        await tester.runAsync(() => directory!.delete(recursive: true));
      }
    }
  });

  testWidgets('new flung cells defer full decode without downgrading old cells', (
    tester,
  ) async {
    final scrolling = ValueNotifier(true);
    addTearDown(scrolling.dispose);
    Future<void> show(int index, {bool ready = true}) => tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: AlbumBrowseCoverQuality(
          key: ValueKey(index),
          scrolling: scrolling,
          previewReady: ready,
          preview: const Text('preview'),
          fullQuality: const Text('full'),
        ),
      ),
    );
    await show(0);
    expect(find.text('preview'), findsOneWidget);
    expect(find.text('full'), findsNothing);
    scrolling.value = false;
    await tester.pump();
    expect(find.text('full'), findsOneWidget);
    scrolling.value = true;
    await tester.pump();
    expect(find.text('full'), findsOneWidget);
    await show(1);
    expect(find.text('preview'), findsOneWidget);
    await show(2, ready: false);
    expect(find.text('full'), findsOneWidget,
        reason: 'a genuine preview miss must load its original immediately');
    await show(2);
    expect(find.text('full'), findsOneWidget,
        reason: 'a late preview cannot downgrade an existing full image');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cache is bounded and a clear discards old artwork', (tester) async {
    final cache = AlbumBrowseArtworkCache(
      maxEntries: 2, maxBytes: 2 * 160 * 160 * 4,
    );
    await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('album-budget');
      try {
        final paths = <String>[];
        for (var i = 0; i < 3; i++) {
          final file = File('${root.path}/$i.png');
          await file.writeAsBytes(await _png(const ui.Color(0xff112233)));
          paths.add(file.path);
        }
        await cache.prepare(paths[0]);
        await cache.prepare(paths[1]);
        cache.imageFor(paths[0])!.dispose();
        await cache.prepare(paths[2]);
        expect(cache.length, 2);
        expect(cache.imageFor(paths[1]), isNull);
        cache.imageFor(paths[0])!.dispose();
        cache.imageFor(paths[2])!.dispose();
        cache.clear();
        expect(cache.imageFor(paths[0]), isNull);
        await File(paths[0]).writeAsBytes(await _png(const ui.Color(0xff8844cc)));
        await cache.prepare(paths[0]);
        final image = cache.imageFor(paths[0])!;
        try {
          final rgba = (await image.toByteData())!;
          expect(rgba.buffer.asUint8List(rgba.offsetInBytes, 4),
              [136, 68, 204, 255]);
        } finally {
          image.dispose();
        }
      } finally {
        cache.clear();
        await root.delete(recursive: true);
      }
    });
  });

  test('a canceled warmup does not start another batch', () async {
    final cache = AlbumBrowseArtworkCache();
    var active = true;
    final calls = <String>[];
    await prewarmAlbumBrowseArtwork(
      List.generate(30, (i) => (filePath: '$i.flac', cover: null)),
      cache: cache,
      isActive: () => active,
      resolve: (path, _) async {
        calls.add(path);
        active = false;
        return null;
      },
    );
    expect(calls, ['0.flac']);
    expect(cache.length, 0);
  });
}
