import 'package:mornye/models/library_collections.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/unified_library_item.dart';

final _containerRoot = RegExp(
  r'^(?:/private)?/var/mobile/Containers/Data/Application/[A-F0-9\-]+(?=/)'
  r'|^/[^\n]+/Library/Developer/CoreSimulator/Devices/[A-F0-9\-]+'
  r'/data/Containers/Data/Application/[A-F0-9\-]+(?=/)',
  caseSensitive: false,
);

String? portableLocalTrackPath(String path) {
  final root = _containerRoot.firstMatch(path);
  if (root == null) return null;
  final relative = path.substring(root.end);
  return relative.startsWith('/Documents/') && !relative.split('/').contains('..')
      ? relative
      : null;
}

/// Same unsigned UTF-16 DJB2 ID as LibraryDatabase and the native scanner.
String localTrackIdForPath(String path) {
  var hash = 5381;
  for (final unit in path.codeUnits) {
    hash = ((hash * 33) + unit) & 0xffffffff;
  }
  return 'lib_${hash.toRadixString(16)}';
}

String? _oldContainer(Track track) {
  var path = track.coverUrl ?? '';
  if (path.startsWith('file://')) {
    try {
      path = Uri.parse(path).toFilePath();
    } catch (_) {
      return null;
    }
  }
  final root = _containerRoot.firstMatch(path);
  return root == null ? null : path.substring(0, root.end);
}

String _norm(String? value) => (value ?? '').trim().toLowerCase();

bool _sameRelease(Track old, LocalLibraryItem item) =>
    _norm(old.artistName) == _norm(item.artistName) &&
    _norm(old.albumName) == _norm(item.albumName);

bool _sameMetadata(Track old, LocalLibraryItem item) =>
    _sameRelease(old, item) &&
    _norm(old.name) == _norm(item.trackName) &&
    _norm(old.name).isNotEmpty &&
    _norm(old.artistName).isNotEmpty &&
    _norm(old.albumName).isNotEmpty;

bool _noConflict(Track old, LocalLibraryItem item) {
  bool number(int? a, int? b) =>
      a == null || a <= 0 || b == null || b <= 0 || a == b;
  final a = _norm(old.isrc);
  final b = _norm(item.isrc);
  return (a.isEmpty || b.isEmpty || a == b) &&
      number(old.trackNumber, item.trackNumber) &&
      number(old.discNumber, item.discNumber) &&
      (old.duration <= 0 || (item.duration ?? 0) <= 0 ||
          (old.duration - item.duration!).abs() <= 2);
}

class RestoredLocalTrack {
  const RestoredLocalTrack(this.track, this.relativePath);
  final Track track;
  final String? relativePath;

  static RestoredLocalTrack? fromEntry(Map<Object?, Object?> entry) {
    final data = entry['track'];
    if (data is! Map<Object?, Object?>) return null;
    try {
      final track = Track.fromJson(Map<String, dynamic>.from(data));
      if (track.source != 'local' || track.id.isEmpty) return null;
      final hint = entry['localRelativePath'];
      final relative = hint is String && hint.startsWith('/Documents/') &&
          !hint.split('/').contains('..') ? hint : null;
      return RestoredLocalTrack(track, relative);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toEntry() => {
    'track': track.toJson(),
    'localRelativePath': ?relativePath,
  };
}

/// Never picks the first of multiple metadata matches. An explicit portable
/// path or a reconstructed old installation ID is stronger than tag equality.
/// Network/catalog IDs and unresolved entries are not rewritten.
class RestoredLocalTrackIndex {
  RestoredLocalTrackIndex(Iterable<LocalLibraryItem> items)
    : _items = items.where((item) =>
          portableLocalTrackPath(item.filePath) != null).toList() {
    for (final item in _items) {
      _byId[item.id] = item;
      _byPath.putIfAbsent(portableLocalTrackPath(item.filePath)!, () => [])
          .add(item);
      _byTags.putIfAbsent(
        (_norm(item.trackName), _norm(item.artistName), _norm(item.albumName)),
        () => [],
      ).add(item);
    }
  }

  final List<LocalLibraryItem> _items;
  final _byId = <String, LocalLibraryItem>{};
  final _byPath = <String, List<LocalLibraryItem>>{};
  final _byTags = <(String, String, String), List<LocalLibraryItem>>{};
  final _oldIds = <String, Map<String, List<LocalLibraryItem>>>{};

  LocalLibraryItem? _unique(Iterable<LocalLibraryItem> rows) {
    final list = rows.take(2).toList();
    return list.length == 1 ? list.single : null;
  }

  Track? match(RestoredLocalTrack saved) {
    final old = saved.track;
    final exact = _byId[old.id];
    if (exact != null) return UnifiedLibraryItem.fromLocalLibrary(exact).toTrack();

    LocalLibraryItem? matched;
    final relative = saved.relativePath;
    if (relative != null) {
      final pathMatches = _byPath[relative] ?? const <LocalLibraryItem>[];
      matched = _unique(pathMatches.where((item) =>
          _sameRelease(old, item) && _noConflict(old, item)));
      // A new-format backup with a path is not evidence for another file
      // at a different path if its explicit path is ambiguous.
      if (pathMatches.isNotEmpty && matched == null) return null;
    }
    final previousRoot = _oldContainer(old);
    if (matched == null && previousRoot != null) {
      final index = _oldIds.putIfAbsent(previousRoot, () {
        final result = <String, List<LocalLibraryItem>>{};
        for (final item in _items) {
          final suffix = portableLocalTrackPath(item.filePath)!;
          final id = localTrackIdForPath('$previousRoot$suffix');
          result.putIfAbsent(id, () => []).add(item);
        }
        return result;
      });
      final rows = index[old.id] ?? const <LocalLibraryItem>[];
      matched = _unique(rows.where((item) => _sameMetadata(old, item)));
    }
    if (matched == null) {
      final candidates = _byTags[
        (_norm(old.name), _norm(old.artistName), _norm(old.albumName))
      ] ?? const <LocalLibraryItem>[];
      matched = _unique(candidates.where((item) =>
          _sameMetadata(old, item) && _noConflict(old, item)));
    }
    return matched == null ? null :
        UnifiedLibraryItem.fromLocalLibrary(matched).toTrack();
  }
}

Iterable<Map<Object?, Object?>> restoredCollectionEntries(Map<Object?, Object?> collections) sync* {
  for (final kind in ['wishlist', 'loved']) {
    final entries = collections[kind];
    if (entries is List<Object?>) yield* entries.whereType<Map<Object?, Object?>>();
  }
  final playlists = collections['playlists'];
  if (playlists is List<Object?>) {
    for (final playlist in playlists.whereType<Map<Object?, Object?>>()) {
      final entries = playlist['tracks'];
      if (entries is List<Object?>) yield* entries.whereType<Map<Object?, Object?>>();
    }
  }
}

/// Add optional portable paths to backups without changing their wire format
/// or storing any extra fields in the collection database.
void attachPortableCollectionPaths(
  Map<Object?, Object?> collections,
  Map<String, String> relativePaths,
) {
  for (final entry in restoredCollectionEntries(collections)) {
    final track = RestoredLocalTrack.fromEntry(entry);
    if (track == null) continue;
    final relative = relativePaths[track.track.id];
    if (relative != null) entry['localRelativePath'] = relative;
  }
}

String remappedRestoredCollectionKey(String key, Track old, Track updated) {
  final previous = trackCollectionKey(old);
  final next = trackCollectionKey(updated);
  if (key == previous) return next;
  if (key.startsWith('occurrence:') && key.endsWith(':$previous')) {
    return '${key.substring(0, key.length - previous.length)}$next';
  }
  return key;
}

class RestoredCollectionPlan {
  const RestoredCollectionPlan(this.collections, this.pending);
  final Map<String, dynamic> collections;
  final List<RestoredLocalTrack> pending;
}

/// Resolve before the native transactional import. Keep unresolved entries
/// untouched and preserve every intentional playlist occurrence.
RestoredCollectionPlan planRestoredCollections(
  Map<String, dynamic> collections,
  RestoredLocalTrackIndex index,
) {
  final pending = <String, RestoredLocalTrack>{};
  final matches = <String, Track?>{};
  List<dynamic> rewrite(List<Object?> entries, {required bool playlist}) {
    final result = <dynamic>[];
    final used = <String>{};
    for (final entry in entries) {
      if (entry is! Map<Object?, Object?> || entry['key'] is! String) {
        result.add(entry);
        continue;
      }
      final saved = RestoredLocalTrack.fromEntry(entry);
      final updated = saved == null ? null :
          matches.putIfAbsent(saved.track.id, () => index.match(saved));
      var key = entry['key'] as String;
      var value = Map<String, dynamic>.from(entry);
      if (saved != null && updated != null) {
        key = remappedRestoredCollectionKey(key, saved.track, updated);
        value = {...value, 'key': key, 'track': updated.toJson()};
      } else if (saved != null) {
        pending[saved.track.id] = saved;
      }
      if (!used.add(key)) {
        if (!playlist) continue;
        final base = updated == null
            ? (saved == null ? key : trackCollectionKey(saved.track))
            : trackCollectionKey(updated);
        var occurrence = 2;
        do {
          key = 'occurrence:${occurrence++}:$base';
        } while (!used.add(key));
        value['key'] = key;
      }
      result.add(value);
    }
    return result;
  }

  final result = Map<String, dynamic>.from(collections);
  for (final kind in ['wishlist', 'loved']) {
    final entries = result[kind];
    if (entries is List<Object?>) result[kind] = rewrite(entries, playlist: false);
  }
  final playlists = result['playlists'];
  if (playlists is List<Object?>) {
    result['playlists'] = [
      for (final playlist in playlists)
        if (playlist is Map<Object?, Object?> && playlist['tracks'] is List<Object?>)
          {...playlist, 'tracks': rewrite(playlist['tracks'] as List<Object?>, playlist: true)}
        else playlist,
    ];
  }
  return RestoredCollectionPlan(result, pending.values.toList(growable: false));
}
