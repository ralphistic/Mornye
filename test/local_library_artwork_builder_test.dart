import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';
import 'package:mornye/widgets/local_library_artwork_builder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backendChannel = MethodChannel('com.zarz.mornye/backend');
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('local-cover-priority-');
    DownloadedEmbeddedCoverResolver.setPersistentCacheDirectoryForTesting(
      Directory('${directory.path}/previews'),
    );
  });

  tearDown(() async {
    await DownloadedEmbeddedCoverResolver.resetMemoryStateForTesting(
      preservePersistentFiles: false,
    );
    DownloadedEmbeddedCoverResolver.setPersistentCacheDirectoryForTesting(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backendChannel, null);
    await directory.delete(recursive: true);
  });

  testWidgets('FLAC never displays a stale scan cover while extracting', (
    tester,
  ) async {
    final stale = File('${directory.path}/stale.png');
    await tester.runAsync(() => stale.writeAsBytes([1, 2, 3]));
    final flac = File('${directory.path}/track.flac');
    await tester.runAsync(() => flac.writeAsBytes([4, 5, 6]));

    // Prime a transient extraction failure outside Flutter's fake clock.
    // The failed-extraction cooldown keeps the widget from scheduling
    // background file I/O that would otherwise block test tearDown.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backendChannel, (call) async {
          expect(call.method, 'extractCoverToFile');
          return jsonEncode({'error': 'temporary extraction failure'});
        });
    final missing = await tester.runAsync(
      () => DownloadedEmbeddedCoverResolver.resolveOrExtract(flac.path),
    );
    expect(missing, isNull);
    expect(
      DownloadedEmbeddedCoverResolver.hasNoEmbeddedCover(flac.path),
      isFalse,
    );

    String? shown = 'not built';
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: LocalLibraryArtworkBuilder(
          coverPath: stale.path,
          filePath: flac.path,
          builder: (_, cover) {
            shown = cover;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(shown, isNull);
  });

  // Extracted-picture selection is covered by the resolver tests. Avoid
  // preloading the resolver inside a fake-async widget test: its background
  // preview validation can outlive the widget and deadlock test teardown.
  // The widget test above covers the essential stale-thumbnail suppression.

  testWidgets('non-FLAC files retain the scanned cover fallback', (
    tester,
  ) async {
    final cover = File('${directory.path}/cover.png');
    await tester.runAsync(() => cover.writeAsBytes([1, 2, 3]));
    final mp3 = File('${directory.path}/track.mp3');
    await tester.runAsync(() => mp3.writeAsBytes([4, 5, 6]));

    String? shown;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: LocalLibraryArtworkBuilder(
          coverPath: cover.path,
          filePath: mp3.path,
          builder: (_, resolved) {
            shown = resolved;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(shown, cover.path);
  });
}
