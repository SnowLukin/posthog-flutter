import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'persistence.dart';
import 'storage.dart';

/// File-based storage implementation.
///
/// Stores all persisted properties as a single JSON file on disk.
/// This is not available on web platforms since it uses `dart:io`.
///
/// For Flutter apps, pass the directory from `path_provider`'s
/// `getApplicationDocumentsDirectory()` or `getApplicationSupportDirectory()`.
///
/// Example:
/// ```dart
/// final dir = await getApplicationSupportDirectory();
/// final storage = FileStorage(dir.path);
/// ```
///
/// Storage never throws into the host app. While the file is unreadable
/// (locked by AV/backup, permissions), mutations are kept in an in-memory
/// overlay - consent and identity must survive the session - and are merged
/// over the on-disk data and persisted once the disk becomes readable again,
/// so a transient failure never replaces good persisted data.
class FileStorage implements PostHogStorage {
  final String _directoryPath;
  Map<String, Object?>? _cache;

  // Mutations made while the disk state is unknown: values waiting to be
  // merged, and tombstones for keys removed during the degraded window.
  final Map<String, Object?> _pendingWrites = {};
  final Set<String> _pendingRemovals = {};

  static const _fileName = 'posthog_data.json';

  FileStorage(this._directoryPath);

  String get _filePath => p.join(_directoryPath, _fileName);

  @override
  bool get isDegraded => _tryLoadCache() == null;

  /// Returns the authoritative store, or null while the disk is unreadable.
  Map<String, Object?>? _tryLoadCache() {
    if (_cache == null) {
      final List<int> bytes;
      try {
        bytes = File(_filePath).readAsBytesSync();
      } on PathNotFoundException {
        // No file (or directory) yet: a genuinely fresh store. Checked via
        // the read exception, not existsSync() - the latter reports false
        // on access-denied too, which would misclassify a transient outage
        // as a fresh store and later overwrite live data.
        _cache = {};
        return _finishLoad();
      } catch (_) {
        // Transient IO failure: the on-disk state is unknown.
        return null;
      }
      try {
        // allowMalformed: invalid UTF-8 (e.g. a torn write) is corrupt
        // content, not a transient failure - it must reset the store, not
        // brick it into a permanent degraded mode.
        final content = utf8.decode(bytes, allowMalformed: true);
        _cache = jsonDecode(content) as Map<String, Object?>;
      } catch (_) {
        // Corrupt content: resetting to an empty store is the only option.
        _cache = {};
      }
    }
    return _finishLoad();
  }

  Map<String, Object?> _finishLoad() {
    if (_pendingWrites.isNotEmpty || _pendingRemovals.isNotEmpty) {
      for (final entry in _pendingWrites.entries) {
        _cache![entry.key] =
            _mergePending(entry.key, _cache![entry.key], entry.value);
      }
      _pendingRemovals.forEach(_cache!.remove);
      _pendingWrites.clear();
      _pendingRemovals.clear();
      _writeSnapshot();
    }
    return _cache!;
  }

  /// Merge policy for values written while the disk was unreadable: a value
  /// rebuilt from a null read during the window must not blindly replace
  /// good persisted data.
  static Object? _mergePending(String key, Object? disk, Object? pending) {
    if (disk == null) return pending;
    if (key == PostHogPersistedProperty.queue.key) {
      // Window events go after the persisted backlog.
      if (disk is List && pending is List) return [...disk, ...pending];
      return pending;
    }
    if (key == PostHogPersistedProperty.anonymousId.key ||
        key == PostHogPersistedProperty.sessionId.key ||
        key == PostHogPersistedProperty.sessionStartTimestamp.key ||
        key == PostHogPersistedProperty.sessionLastTimestamp.key) {
      // Generated-if-absent identity: the disk wins - a uuid generated
      // during the window would split the user's history. The session triple
      // merges as one unit: a fresh lastTimestamp glued to a stale sessionId
      // would keep an expired session alive past its expiration.
      return disk;
    }
    if ((key == PostHogPersistedProperty.props.key ||
            key == PostHogPersistedProperty.personProperties.key ||
            key == PostHogPersistedProperty.groupProperties.key) &&
        disk is Map &&
        pending is Map) {
      // Accumulator maps only: union with the window's writes on top. Other
      // map values (flag details, remote config) have replace semantics - a
      // union would resurrect stale sibling keys. The result is typed
      // explicitly: a spread of dynamic maps would reify as
      // Map<dynamic, dynamic> and fail the typed read back.
      return <String, Object?>{
        for (final entry in disk.entries) entry.key.toString(): entry.value,
        for (final entry in pending.entries)
          entry.key.toString(): entry.value,
      };
    }
    // Explicit overwrites (distinct_id, opted_out, snapshots ...): latest
    // write wins.
    return pending;
  }

  void _writeSnapshot() {
    final String payload;
    try {
      payload = jsonEncode(_cache);
    } catch (_) {
      return;
    }
    try {
      final dir = Directory(_directoryPath);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      // Atomic-on-volume replace: a crash mid-write must never leave a
      // truncated snapshot in place of the real one.
      final tmp = File('$_filePath.tmp');
      tmp.writeAsStringSync(payload, flush: true);
      tmp.renameSync(_filePath);
    } catch (_) {
      // Transient IO failure: the cache keeps the new state, the next
      // successful write persists the whole snapshot anyway.
    }
  }

  static bool _isEncodable(Object? value) {
    try {
      jsonEncode(value);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  T? getProperty<T>(PostHogPersistedProperty key) {
    // Load first: on disk recovery this is what merges and clears pending,
    // otherwise pending keys would bypass the merge forever.
    final data = _tryLoadCache();
    if (_pendingRemovals.contains(key.key)) return null;
    Object? value;
    if (_pendingWrites.containsKey(key.key)) {
      value = _pendingWrites[key.key];
    } else {
      if (data == null) return null;
      value = data[key.key];
    }
    // The shared store's content is untrusted: a value of an unexpected
    // type (another writer, version skew) must not throw into the host app.
    return value is T ? value : null;
  }

  @override
  void setProperty<T>(PostHogPersistedProperty key, T? value) {
    // A non-encodable value is dropped up front, otherwise it would fail
    // every subsequent write of the shared snapshot.
    if (value != null && !_isEncodable(value)) return;

    final data = _tryLoadCache();
    if (data == null) {
      if (value == null) {
        _pendingWrites.remove(key.key);
        _pendingRemovals.add(key.key);
      } else {
        _pendingRemovals.remove(key.key);
        _pendingWrites[key.key] = value;
      }
      return;
    }

    if (value == null) {
      data.remove(key.key);
    } else {
      data[key.key] = value;
    }
    _writeSnapshot();
  }

  /// Clears the in-memory cache, forcing next read from disk.
  void clearCache() {
    _cache = null;
  }
}
