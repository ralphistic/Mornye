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
    await stale.writeAsBytes([1, 2, 3]);
    final flac = File('${directory.path}/track.flac');
    await flac.writeAsBytes([4, 5, 6]);

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

  testWidgets('FLAC uses extracted picture rather than existing scan image', (
    tester,
  ) async {
    final stale = File('${directory.path}/old.png');
    await stale.writeAsBytes([1, 2, 3]);
    final flac = File('${directory.path}/edited.flac');
    await flac.writeAsBytes([4, 5, 6]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backendChannel, (call) async {
          expect(call.method, 'extractCoverToFile');
          final args = call.arguments as Map<Object?, Object?>;
          await File(args['output_path']! as String).writeAsBytes([7, 8, 9]);
          return jsonEncode({'success': true});
        });
    final extracted = await DownloadedEmbeddedCoverResolver.resolveOrExtract(
      flac.path,
    );
    expect(extracted, isNotNull);
    expect(await File(extracted!).readAsBytes(), [7, 8, 9]);

    String? shown;
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
    expect(shown, extracted);
    expect(shown, isNot(stale.path));
  });

  testWidgets('non-FLAC files retain the scanned cover fallback', (
    tester,
  ) async {
    final cover = File('${directory.path}/cover.png');
    await cover.writeAsBytes([1, 2, 3]);
    final mp3 = File('${directory.path}/track.mp3');
    await mp3.writeAsBytes([4, 5, 6]);

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
