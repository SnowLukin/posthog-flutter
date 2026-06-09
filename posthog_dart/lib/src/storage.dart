import 'persistence.dart';

/// Interface for persisted property storage.
abstract interface class PostHogStorage {
  T? getProperty<T>(PostHogPersistedProperty key);
  void setProperty<T>(PostHogPersistedProperty key, T? value);
}

/// In-memory storage implementation (useful for tests or server-side).
class InMemoryStorage implements PostHogStorage {
  final Map<String, Object?> _data = {};

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
