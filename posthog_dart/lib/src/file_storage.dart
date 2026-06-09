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
      final String content;
      try {
        final file = File(_filePath);
        if (!file.existsSync()) {
          _cache = {};
        } else {
          content = file.readAsStringSync();
          try {
            _cache = jsonDecode(content) as Map<String, Object?>;
          } catch (_) {
            // Corrupt content: resetting to an empty store is the only option.
            _cache = {};
          }
        }
      } catch (_) {
        // Transient IO failure: the on-disk state is unknown.
        return null;
      }
    }

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
    return _cache;
  }

  /// Merge-политика для значений, записанных при нечитаемом диске: значение,
  /// собранное из null-чтения во время окна, не должно слепо затирать
  /// хорошие persisted-данные.
  static Object? _mergePending(String key, Object? disk, Object? pending) {
    if (disk == null) return pending;
    if (key == PostHogPersistedProperty.queue.key) {
      // События окна встают после накопленного на диске бэклога.
      if (disk is List && pending is List) return [...disk, ...pending];
      return pending;
    }
    if (key == PostHogPersistedProperty.anonymousId.key ||
        key == PostHogPersistedProperty.sessionId.key ||
        key == PostHogPersistedProperty.sessionStartTimestamp.key) {
      // Generated-if-absent identity: побеждает диск - uuid, сгенерированный
      // в окне, расколол бы историю пользователя.
      return disk;
    }
    if (disk is Map && pending is Map) {
      // Аккумуляторы (props, person/group properties): union, записи окна
      // сверху.
      return {...disk, ...pending};
    }
    // Осознанные перезаписи (distinct_id, opted_out, ...): последняя побеждает.
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
      File(_filePath).writeAsStringSync(payload);
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
    // Сначала попытка загрузки: при восстановлении диска именно она мержит
    // и очищает pending, иначе pending-ключи навсегда обходили бы merge.
    final data = _tryLoadCache();
    if (_pendingRemovals.contains(key.key)) return null;
    Object? value;
    if (_pendingWrites.containsKey(key.key)) {
      value = _pendingWrites[key.key];
    } else {
      if (data == null) return null;
      value = data[key.key];
    }
    // Содержимому общего стора нельзя доверять: значение неожиданного типа
    // (другой писатель, version skew) не должно кидать в host app.
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
