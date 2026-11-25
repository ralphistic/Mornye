import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/services/restored_local_collections.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const oldRoot = '/var/mobile/Containers/Data/Application/11111111-1111-4111-8111-111111111111';
const newRoot = '/var/mobile/Containers/Data/Application/22222222-2222-4222-8222-222222222222';

LocalLibraryItem row(String name, String file, {String album = 'Kirby', int duration = 80}) {
  final path = '$newRoot/Documents/Mornye/$file';
  return LocalLibraryItem(
    id: localTrackIdForPath(path), trackName: name, artistName: 'Artist',
    albumName: album, filePath: path, duration: duration,
    coverPath: '$newRoot/Library/Caches/cover.png', scannedAt: DateTime.utc(2026),
  );
}

Track old(String name, String file, {String source = 'local', String album = 'Kirby'}) =>
    Track(id: localTrackIdForPath('$oldRoot/Documents/Mornye/$file'),
        name: name, artistName: 'Artist', albumName: album,
        coverUrl: '$oldRoot/Library/Caches/cover.png', duration: 80, source: source);

Map<String, dynamic> entry(Track track, {String? key, String? relative}) => {
  'key': key ?? '${track.source}:${track.id}',
  'track': track.toJson(), 'addedAt': '2026-01-01T00:00:00',
  'localRelativePath': ?relative,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('portable paths and reconstructed IDs survive a different iOS container', () {
    final a = row('Continue?', 'Continue?.flac');
    final b = row('Continue?', 'another.flac');
    final index = RestoredLocalTrackIndex([a, b]);
    expect(localTrackIdForPath('$newRoot/Documents/Mornye/Continue?.flac'), 'lib_48f4aec1');
    expect(index.match(RestoredLocalTrack(old('Continue?', 'Continue?.flac'), null))?.id, a.id);
    expect(index.match(RestoredLocalTrack(old('Continue?', 'old-name.flac'), null)), isNull);
    expect(index.match(RestoredLocalTrack(old('Continue?', 'old-name.flac'),
      '/Documents/Mornye/another.flac'))?.id, b.id);
    expect(index.match(RestoredLocalTrack(old('Continue?', 'old-name.flac', album: 'Other'), null)), isNull);
  });

  test('restore deduplicates local likes, preserves remote IDs and repeated playlists', () {
    final current = row('Continue?', 'Continue?.flac');
    final oldA = old('Continue?', 'Continue?.flac');
    final oldB = old('Continue?', 'renamed.flac');
    final remote = old('Continue?', 'remote.flac', source: 'tidal-web');
    final missing = old('Missing', 'missing.flac');
    final index = RestoredLocalTrackIndex([current]);
    final plan = planRestoredCollections({
      'loved': [entry(oldA), entry(oldB), entry(remote), entry(missing)],
      'playlists': [
        {'id': 'p', 'name': 'Playlist', 'tracks': [
          entry(oldA), entry(oldB), entry(oldA, key: 'occurrence:2:local:${oldA.id}'),
        ]},
      ],
    }, index);
    final loved = (plan.collections['loved'] as List<Object?>).cast<Map<String, dynamic>>();
    expect(loved.map((e) => e['key']), ['local:${current.id}', 'tidal-web:${remote.id}', 'local:${missing.id}']);
    expect((loved.first['track'] as Map<String, dynamic>)['coverUrl'], current.coverPath);
    final playlistData = (plan.collections['playlists'] as List<Object?>).single as Map<Object?, Object?>;
    final tracks = (playlistData['tracks'] as List<Object?>).cast<Map<String, dynamic>>();
    expect(tracks.map((e) => (e['track'] as Map<String, dynamic>)['id']), [current.id, current.id, current.id]);
    expect(tracks.map((e) => e['key']).toSet(), hasLength(3));
    expect(tracks.map((e) => e['addedAt']).toSet(), {'2026-01-01T00:00:00'});
    expect(plan.pending.map((e) => e.track.id), [missing.id]);
  });

  test('deferred relink does not resurrect removed favorites and retains playlist order', () async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    final db = await LibraryCollectionsDatabase.openWithFactory(databaseFactoryFfi, inMemoryDatabasePath);
    addTearDown(db.close);
    final collections = LibraryCollectionsDatabase.withDatabase(db);
    final a = old('Continue?', 'old.flac');
    final current = row('Continue?', 'Continue?.flac');
    final match = RestoredLocalTrackIndex([current]).match(RestoredLocalTrack(a, null))!;
    await db.insert('playlists', {
      'id':'p','name':'Playlist','created_at':'2026-01-01','updated_at':'2026-01-01',
    });
    for (final (track, date) in [(a,'2026-01-01'), (match,'2026-01-02')]) {
      for (final table in ['loved_tracks','playlist_tracks']) {
        await db.insert(table, {
          if (table == 'playlist_tracks') 'playlist_id':'p',
          'track_key':'local:${track.id}', 'track_json':jsonEncode(track.toJson()), 'added_at':date,
        });
      }
    }
    final removed = old('Removed', 'removed.flac');
    await collections.relinkRestoredLocalTracks({a.id:match, removed.id:match});
    expect(await db.query('loved_tracks'), hasLength(1));
    final playlist = await db.query('playlist_tracks',orderBy:'added_at');
    expect(playlist, hasLength(2));
    expect(playlist.map((r) => r['added_at']), ['2026-01-01','2026-01-02']);
    expect(playlist.map((r) => (jsonDecode(r['track_json'] as String) as Map<String, dynamic>)['id']), [match.id,match.id]);
    expect(playlist.map((r) => r['track_key']).toSet(), hasLength(2));
  });
}
