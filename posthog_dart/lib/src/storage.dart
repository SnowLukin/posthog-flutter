import 'persistence.dart';

/// Interface for persisted property storage.
abstract interface class PostHogStorage {
  /// Returns the value stored under [key], or null when the key is absent
  /// or the stored value is not a [T].
  T? getProperty<T>(PostHogPersistedProperty key);

  /// Stores [value] under [key]; null removes the entry. Stores that
  /// serialize (like [FileStorage]) drop a value that cannot be
  /// JSON-encoded instead of failing every later write.
  void setProperty<T>(PostHogPersistedProperty key, T? value);

  /// Whether the underlying store is currently unreadable.
  ///
  /// While degraded, persisted state (including consent) is unknown -
  /// consumers should treat it conservatively, e.g. consent checks fail
  /// closed.
  bool get isDegraded;
}

/// In-memory storage implementation (useful for tests or server-side).
class InMemoryStorage implements PostHogStorage {
  final Map<String, Object?> _data = {};

  @override
  bool get isDegraded => false;

  @override
  T? getProperty<T>(PostHogPersistedProperty key) {
    final value = _data[key.key];
    return value is T ? value : null;
  }

  @override
  void setProperty<T>(PostHogPersistedProperty key, T? value) {
    if (value == null) {
      _data.remove(key.key);
    } else {
      _data[key.key] = value;
    }
  }
}
