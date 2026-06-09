import 'dart:io';

import 'package:posthog_dart/posthog_dart.dart';
import 'package:test/test.dart';

void main() {
  group('FileStorage', () {
    test('non-encodable value does not throw or poison the cache', () {
      final dir = Directory.systemTemp.createTempSync('posthog_storage_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final storage = FileStorage(dir.path);

      storage.setProperty(
          PostHogPersistedProperty.props, {'date': DateTime.now()});

      expect(
          storage.getProperty<Map<String, Object?>>(
              PostHogPersistedProperty.props),
          isNull);

      storage.setProperty(PostHogPersistedProperty.distinctId, 'id-1');
      expect(
          storage.getProperty<String>(PostHogPersistedProperty.distinctId),
          'id-1');

      // The value made it to disk, not just into the in-memory cache.
      storage.clearCache();
      expect(
          storage.getProperty<String>(PostHogPersistedProperty.distinctId),
          'id-1');
    });

    test('transient write failure keeps the value in memory, no throw', () {
      final dir = Directory.systemTemp.createTempSync('posthog_storage_ro');
      final storage = FileStorage(dir.path);
      storage.setProperty(PostHogPersistedProperty.distinctId, 'a');

      final dataFile = '${dir.path}/posthog_data.json';
      Process.runSync('chmod', ['444', dataFile]);
      addTearDown(() {
        Process.runSync('chmod', ['644', dataFile]);
        dir.deleteSync(recursive: true);
      });

      expect(
          () => storage.setProperty(PostHogPersistedProperty.distinctId, 'b'),
          returnsNormally);
      // Consent/queue updates must survive the session even if the disk
      // write failed - the next successful write persists the snapshot.
      expect(
          storage.getProperty<String>(PostHogPersistedProperty.distinctId),
          'b');

      Process.runSync('chmod', ['644', dataFile]);
      storage.setProperty(PostHogPersistedProperty.sessionId, 's');
      storage.clearCache();
      expect(
          storage.getProperty<String>(PostHogPersistedProperty.distinctId),
          'b');
    }, skip: Platform.isWindows ? 'simulates IO failures via POSIX chmod' : false);

    test('value of an unexpected type reads as null instead of throwing', () {
      final dir = Directory.systemTemp.createTempSync('posthog_storage_type');
      addTearDown(() => dir.deleteSync(recursive: true));
      final storage = FileStorage(dir.path);

      storage.setProperty<Object>(PostHogPersistedProperty.queue, 'garbage');

      expect(
          storage
              .getProperty<List<Object?>>(PostHogPersistedProperty.queue),
          isNull);
      expect(
          storage.getProperty<String>(PostHogPersistedProperty.queue),
          'garbage');

      final memory = InMemoryStorage();
      memory.setProperty<Object>(PostHogPersistedProperty.distinctId, 42);
      expect(
          memory.getProperty<String>(PostHogPersistedProperty.distinctId),
          isNull);
    });

    test('mutations during a read-failure window survive in memory and merge',
        () {
      final dir = Directory.systemTemp.createTempSync('posthog_storage_rd');
      final seed = FileStorage(dir.path);
      seed.setProperty(PostHogPersistedProperty.distinctId, 'keep');
      seed.setProperty(PostHogPersistedProperty.sessionId, 'sess');

      final dataFile = '${dir.path}/posthog_data.json';
      Process.runSync('chmod', ['000', dataFile]);
      addTearDown(() {
        Process.runSync('chmod', ['644', dataFile]);
        dir.deleteSync(recursive: true);
      });

      final blind = FileStorage(dir.path);
      expect(
          blind.getProperty<String>(PostHogPersistedProperty.distinctId),
          isNull);
      expect(
          () => blind.setProperty(
              PostHogPersistedProperty.distinctId, 'updated'),
          returnsNormally);
      // Consent/identity updates must survive the degraded window in memory.
      expect(
          blind.getProperty<String>(PostHogPersistedProperty.distinctId),
          'updated');

      // Once the disk is readable again, pending mutations merge over the
      // on-disk data (unrelated keys intact) and get persisted.
      Process.runSync('chmod', ['644', dataFile]);
      expect(
          blind.getProperty<String>(PostHogPersistedProperty.sessionId),
          'sess');
      expect(
          blind.getProperty<String>(PostHogPersistedProperty.distinctId),
          'updated');

      final fresh = FileStorage(dir.path);
      expect(
          fresh.getProperty<String>(PostHogPersistedProperty.distinctId),
          'updated');
      expect(
          fresh.getProperty<String>(PostHogPersistedProperty.sessionId),
          'sess');
    }, skip: Platform.isWindows ? 'simulates IO failures via POSIX chmod' : false);

    test('recovery merge keeps the disk backlog and identity', () {
      final dir = Directory.systemTemp.createTempSync('posthog_storage_merge');
      final seed = FileStorage(dir.path);
      seed.setProperty(PostHogPersistedProperty.queue, <Object?>[
        {'message': 'backlog-1'},
      ]);
      seed.setProperty(PostHogPersistedProperty.anonymousId, 'anon-disk');

      final dataFile = '${dir.path}/posthog_data.json';
      Process.runSync('chmod', ['000', dataFile]);
      addTearDown(() {
        Process.runSync('chmod', ['644', dataFile]);
        dir.deleteSync(recursive: true);
      });

      // Во время окна core читает null и пересобирает значения с нуля.
      final blind = FileStorage(dir.path);
      blind.setProperty(PostHogPersistedProperty.queue, <Object?>[
        {'message': 'window-1'},
      ]);
      blind.setProperty(PostHogPersistedProperty.anonymousId, 'anon-window');
      blind.setProperty(PostHogPersistedProperty.distinctId, 'user-window');

      Process.runSync('chmod', ['644', dataFile]);
      final queue =
          blind.getProperty<List<Object?>>(PostHogPersistedProperty.queue);
      expect(queue, hasLength(2));
      expect((queue![0] as Map)['message'], 'backlog-1');
      expect((queue[1] as Map)['message'], 'window-1');
      // Identity с диска побеждает сгенерированную в окне.
      expect(
          blind.getProperty<String>(PostHogPersistedProperty.anonymousId),
          'anon-disk');
      // Явная перезапись из окна побеждает.
      expect(
          blind.getProperty<String>(PostHogPersistedProperty.distinctId),
          'user-window');
    }, skip: Platform.isWindows ? 'simulates IO failures via POSIX chmod' : false);
  });
}
