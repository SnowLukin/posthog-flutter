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
/// Reports a persist failure the store recovered from or gave up on.
typedef FileStorageErrorHandler = void Function(String message, Object error);

/// Renames the written temporary file onto the snapshot path.
typedef FileRenamer = void Function(File source, String targetPath);

class FileStorage implements PostHogStorage {
  final String _directoryPath;
  final FileStorageErrorHandler? _onError;
  final FileRenamer _rename;
  Map<String, Object?>? _cache;
  static const _fileName = 'posthog_data.json';

  /// [rename] exists so the antivirus behaviour this store guards against -
  /// a refused rename - can be exercised on a machine where rename works.
  FileStorage(
    this._directoryPath, {
    FileStorageErrorHandler? onError,
    FileRenamer rename = _renameFile,
  })  : _onError = onError,
        _rename = rename;

  static void _renameFile(File source, String targetPath) =>
      source.renameSync(targetPath);

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
      _replace(tmp);
    } catch (e) {
      // Best effort: the cache keeps the new value, the next successful
      // write persists the whole snapshot. Reported because a store that
      // silently stops persisting looks exactly like one that works.
      _onError?.call('failed to persist to $_filePath', e);
    }
  }

  /// Moves the written temporary file onto the snapshot path.
  ///
  /// Rename is the atomic path. Some antivirus products hold a file open
  /// while scanning it and refuse the rename to the calling process while
  /// still allowing a copy; without the fallback such a machine never
  /// persists anything again. The copy is not atomic, so its result is
  /// size-checked before the temporary file goes away.
  void _replace(File tmp) {
    try {
      _rename(tmp, _filePath);

      return;
    } on FileSystemException catch (e) {
      _onError?.call('rename refused, copying to $_filePath instead', e);
    }

    final expectedLength = tmp.lengthSync();
    tmp.copySync(_filePath);
    final actualLength = File(_filePath).lengthSync();
    if (actualLength != expectedLength) {
      throw FileSystemException(
        'copy truncated: expected $expectedLength bytes, got $actualLength',
        _filePath,
      );
    }

    try {
      tmp.deleteSync();
    } on FileSystemException {
      // Leftover temporary file is overwritten by the next write.
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
