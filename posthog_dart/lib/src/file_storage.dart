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
class FileStorage implements PostHogStorage {
  final String _directoryPath;
  Map<String, Object?>? _cache;
  static const _fileName = 'posthog_data.json';

  FileStorage(this._directoryPath);

  String get _filePath => p.join(_directoryPath, _fileName);

  Map<String, Object?> _readAll() {
    if (_cache != null) return _cache!;

    final String content;
    try {
      final file = File(_filePath);
      if (!file.existsSync()) {
        _cache = {};
        return _cache!;
      }
      content = file.readAsStringSync();
    } catch (_) {
      // Transient IO failure (file locked by AV/backup, permissions): the
      // on-disk state is unknown, so don't cache this empty map - a later
      // write must not replace good persisted data with it.
      return {};
    }

    try {
      _cache = jsonDecode(content) as Map<String, Object?>;
    } catch (_) {
      // Corrupt content: resetting to an empty store is the only option.
      _cache = {};
    }
    return _cache!;
  }

  @override
  T? getProperty<T>(PostHogPersistedProperty key) {
    final data = _readAll();
    return data[key.key] as T?;
  }

  @override
  void setProperty<T>(PostHogPersistedProperty key, T? value) {
    final data = _readAll();
    final hadKey = data.containsKey(key.key);
    final previous = data[key.key];
    if (value == null) {
      data.remove(key.key);
    } else {
      data[key.key] = value;
    }

    // Storage must never throw into the host app (the read path already
    // swallows errors), but the failure modes differ:
    // - a non-encodable value is rolled back, otherwise it would fail every
    //   subsequent write of the shared snapshot;
    // - a transient IO failure keeps the new value in the cache (consent or
    //   queue updates must survive the session) - the next successful write
    //   persists the whole snapshot anyway.
    final String payload;
    try {
      payload = jsonEncode(data);
    } catch (_) {
      if (hadKey) {
        data[key.key] = previous;
      } else {
        data.remove(key.key);
      }
      return;
    }

    // Ephemeral map after a failed read: the on-disk state is unknown, so
    // skip the write instead of clobbering it.
    if (!identical(data, _cache)) return;

    try {
      final dir = Directory(_directoryPath);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      File(_filePath).writeAsStringSync(payload);
    } catch (_) {
      // Transient IO failure - see above.
    }
  }

  /// Clears the in-memory cache, forcing next read from disk.
  void clearCache() {
    _cache = null;
  }
}
