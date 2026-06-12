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
/// Storage never throws into the host app. While the file is unreadable the
/// store reports [isDegraded] and drops writes, so a transient failure never
/// replaces good persisted data.
class FileStorage implements PostHogStorage {
  final String _directoryPath;
  Map<String, Object?>? _cache;
  static const _fileName = 'posthog_data.json';

  FileStorage(this._directoryPath);

  String get _filePath => p.join(_directoryPath, _fileName);

  @override
  bool get isDegraded => _readAll() == null;

  /// Returns the store, or null while the disk is unreadable.
  Map<String, Object?>? _readAll() {
    if (_cache != null) return _cache;

    final List<int> bytes;
    try {
      bytes = File(_filePath).readAsBytesSync();
    } on PathNotFoundException {
      // No file yet. Detected via the read exception, not existsSync(),
      // which also reports false on access-denied.
      return _cache = {};
    } catch (_) {
      // Transient IO failure: the on-disk state is unknown.
      return null;
    }

    try {
      // allowMalformed: invalid UTF-8 (a torn write) is corrupt content and
      // must reset the store rather than disable it permanently.
      final content = utf8.decode(bytes, allowMalformed: true);
      return _cache = jsonDecode(content) as Map<String, Object?>;
    } catch (_) {
      return _cache = {};
    }
  }

  @override
  T? getProperty<T>(PostHogPersistedProperty key) {
    final value = _readAll()?[key.key];
    // Untrusted on-disk content: unexpected types read as null.
    return value is T ? value : null;
  }

  @override
  void setProperty<T>(PostHogPersistedProperty key, T? value) {
    // A non-encodable value would fail every snapshot write from now on.
    if (value != null && !_isEncodable(value)) return;

    final data = _readAll();
    // Unknown disk state: drop the write instead of clobbering good data.
    // Consent is protected separately - consumers fail closed on isDegraded.
    if (data == null) return;

    if (value == null) {
      data.remove(key.key);
    } else {
      data[key.key] = value;
    }

    try {
      final dir = Directory(_directoryPath);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      // Atomic replace: a crash mid-write must not truncate the snapshot.
      final tmp = File('$_filePath.tmp');
      tmp.writeAsStringSync(jsonEncode(data), flush: true);
      tmp.renameSync(_filePath);
    } catch (_) {
      // Best effort: the cache keeps the new value, the next successful
      // write persists the whole snapshot.
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

  /// Clears the in-memory cache, forcing next read from disk.
  void clearCache() {
    _cache = null;
  }
}
