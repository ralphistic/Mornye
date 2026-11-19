import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/playback_artwork.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('restored-artwork-');
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'SAF artwork recovers from missing scan covers and tolerates provider errors',
    () async {
      const source = 'content://example.documents/nas/song.flac';
      final cover = File('${directory.path}/recovered #1.jpg');
      await cover.writeAsBytes([1]);
      for (final missing in [null, '${directory.path}/removed.jpg']) {
        expect(
          await resolveEmbeddedArtworkUri(
            source,
            missing,
            extract: (path) async {
              expect(path, source);
              return cover.path;
            },
          ),
          cover.uri.toString(),
        );
      }
      var unnecessaryReads = 0;
      Future<String?> unexpectedRead(String _) async {
        unnecessaryReads++;
        return null;
      }

      for (final existing in [cover.path, cover.uri.toString()]) {
        expect(
          await resolveEmbeddedArtworkUri(
            source,
            existing,
            extract: unexpectedRead,
          ),
          isNull,
        );
      }
      expect(
        await resolveEmbeddedArtworkUri(
          source,
          null,
          extract: (_) async => throw const SocketException('NAS offline'),
        ),
        isNull,
      );
      for (final remote in [
        'network://share/song.flac',
        'https://example.test/song.flac',
      ]) {
        expect(
          await resolveEmbeddedArtworkUri(
            remote,
            null,
            extract: unexpectedRead,
          ),
          isNull,
        );
      }
      expect(unnecessaryReads, 0);
    },
  );

  test(
    'local files prefer embedded art over an online cover for offline use',
    () async {
      final cover = File('${directory.path}/embedded.jpg');
      await cover.writeAsBytes([1]);
      for (final source in [
        'content://example.documents/music/song.m4a',
        '${directory.path}/song.m4a',
      ]) {
        expect(
          await resolveEmbeddedArtworkUri(
            source,
            'https://example.test/cover.jpg',
            extract: (path) async {
              expect(path, source);
              return cover.path;
            },
          ),
          cover.uri.toString(),
        );
      }
      // A file without embedded art keeps its online cover.
      expect(
        await resolveEmbeddedArtworkUri(
          '${directory.path}/song.m4a',
          'https://example.test/cover.jpg',
          extract: (_) async => null,
        ),
        isNull,
      );
    },
  );

  test(
    'FLAC playback replaces a valid but stale scan thumbnail with embedded art',
    () async {
      final stale = File('${directory.path}/stale.png');
      final embedded = File('${directory.path}/embedded.png');
      await stale.writeAsBytes([1]);
      await embedded.writeAsBytes([2]);
      for (final source in [
        '${directory.path}/song.flac',
        'content://example.documents/music/song.flac',
      ]) {
        for (final artwork in [stale.path, stale.uri.toString()]) {
          var reads = 0;
          expect(
            await resolveEmbeddedArtworkUri(
              source,
              artwork,
              extract: (path) async {
                expect(path, source);
                reads++;
                return embedded.path;
              },
            ),
            embedded.uri.toString(),
          );
          expect(reads, 1);
        }
        // An extraction failure leaves the current artwork in place.
        expect(
          await resolveEmbeddedArtworkUri(
            source,
            stale.path,
            extract: (_) async => null,
          ),
          isNull,
        );
      }
    },
  );

  test(
    'restored queue replaces a removed scan cover with current Library art',
    () async {
      final removed = File(
        '${directory.path}/old-scan/cover.jpg',
      ).uri.toString();
      final current = File('${directory.path}/current cover #1.jpg');
      await current.writeAsBytes([1]);
      final resolved = await resolveRestoredArtworkUri(
        removed,
        loadLibraryCoverPath: () async => current.path,
      );
      expect(resolved, current.uri.toString());
      expect(File(Uri.parse(resolved!).toFilePath()).existsSync(), isTrue);
    },
  );

  test(
    'valid local and remote covers do not trigger Library lookups',
    () async {
      final current = File('${directory.path}/cover.jpg');
      await current.writeAsBytes([1]);
      for (final artwork in [
        current.path,
        current.uri.toString(),
        'https://example.com/cover.jpg',
      ]) {
        var lookups = 0;
        final resolved = await resolveRestoredArtworkUri(
          artwork,
          loadLibraryCoverPath: () async {
            lookups++;
            return null;
          },
        );
        expect(resolved, artwork);
        expect(lookups, 0);
      }
    },
  );

  test(
    'a missing Library image or lookup failure leaves the session usable',
    () async {
      final missing = File('${directory.path}/missing.jpg').uri.toString();
      expect(
        await resolveRestoredArtworkUri(
          missing,
          loadLibraryCoverPath: () async =>
              '${directory.path}/also-missing.jpg',
        ),
        missing,
      );
      expect(
        await resolveRestoredArtworkUri(
          missing,
          loadLibraryCoverPath: () async =>
              throw StateError('Library unavailable'),
        ),
        missing,
      );
    },
  );
}
