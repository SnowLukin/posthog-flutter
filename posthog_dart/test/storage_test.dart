import 'dart:io';

import 'package:posthog_dart/posthog_dart.dart';
import 'package:test/test.dart';

void main() {
  // Both implementations promise the same contract, so the same cases run
  // against each: `reopen` returns a second view of the same underlying
  // store (a fresh instance for FileStorage, the same one for InMemory).
  final implementations = <(String, _StoragePair Function())>[
    (
      'InMemoryStorage',
      () {
        final storage = InMemoryStorage();
        return (storage: storage, reopen: () => storage);
      }
    ),
    (
      'FileStorage',
      () {
        final dir = Directory.systemTemp.createTempSync('posthog_storage');
        addTearDown(() => dir.deleteSync(recursive: true));
        return (
          storage: FileStorage(dir.path),
          reopen: () => FileStorage(dir.path),
        );
      }
    ),
  ];

  group('FileStorage', () {
    test('drops a value that cannot be JSON-encoded', () {
      final dir = Directory.systemTemp.createTempSync('posthog_storage');
      addTearDown(() => dir.deleteSync(recursive: true));
      final storage = FileStorage(dir.path);

      storage.setProperty(
          PostHogPersistedProperty.props, {'date': DateTime.now()});

      expect(
          storage.getProperty<Map<String, Object?>>(
              PostHogPersistedProperty.props),
          isNull,
          reason: 'a value the snapshot cannot serialize must not stay in '
              'the cache, or every later write would fail');

      // The store keeps working after the rejected write.
      storage.setProperty(PostHogPersistedProperty.distinctId, 'id-1');
      expect(
          FileStorage(dir.path)
              .getProperty<String>(PostHogPersistedProperty.distinctId),
          'id-1');
    });
  });

  group('InMemoryStorage', () {
    test('stores a value that cannot be JSON-encoded as-is', () {
      // Nothing is serialized in memory, so unlike FileStorage there is no
      // reason to reject the value.
      final storage = InMemoryStorage();
      final value = {'date': DateTime.now()};

      storage.setProperty(PostHogPersistedProperty.props, value);

      expect(
          storage.getProperty<Map<String, Object?>>(
              PostHogPersistedProperty.props),
          value);
    });
  });

  for (final (name, open) in implementations) {
    group(name, () {
      test('reads a stored value of an unexpected type as null', () {
        final (:storage, :reopen) = open();

        storage.setProperty<Object>(PostHogPersistedProperty.queue, 'garbage');

        expect(
            reopen().getProperty<List<Object?>>(PostHogPersistedProperty.queue),
            isNull);
        expect(reopen().getProperty<String>(PostHogPersistedProperty.queue),
            'garbage');
      });
    });
  }
}

typedef _StoragePair = ({
  PostHogStorage storage,
  PostHogStorage Function() reopen,
});
