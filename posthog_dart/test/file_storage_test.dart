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

      // Snapshots go through tmp+rename, so blocking the write means
      // removing write permission from the directory, not the file.
      Process.runSync('chmod', ['555', dir.path]);
      addTearDown(() {
        Process.runSync('chmod', ['755', dir.path]);
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

      Process.runSync('chmod', ['755', dir.path]);
      storage.setProperty(PostHogPersistedProperty.sessionId, 's');
      storage.clearCache();
      expect(
          storage.getProperty<String>(PostHogPersistedProperty.distinctId),
          'b');
    }, skip: Platform.isWindows ? 'simulates IO failures via POSIX chmod' : false);

    test('invalid UTF-8 resets the store instead of bricking it', () {
      final dir = Directory.systemTemp.createTempSync('posthog_storage_utf8');
      addTearDown(() => dir.deleteSync(recursive: true));
      // Torn write: a multibyte character truncated mid-sequence.
      File('${dir.path}/posthog_data.json')
          .writeAsBytesSync([0x7b, 0x22, 0xd0]);

      final storage = FileStorage(dir.path);
      expect(storage.isDegraded, isFalse);
      expect(
          storage.getProperty<String>(PostHogPersistedProperty.distinctId),
          isNull);

      // Self-heal: the next write persists a fresh valid snapshot.
      storage.setProperty(PostHogPersistedProperty.distinctId, 'healed');
      storage.clearCache();
      expect(
          storage.getProperty<String>(PostHogPersistedProperty.distinctId),
          'healed');
    });

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

      // During the window the core reads null and rebuilds values from scratch.
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
      // Disk identity wins over the one generated during the window.
      expect(
          blind.getProperty<String>(PostHogPersistedProperty.anonymousId),
          'anon-disk');
      // An explicit overwrite from the window wins.
      expect(
          blind.getProperty<String>(PostHogPersistedProperty.distinctId),
          'user-window');
    }, skip: Platform.isWindows ? 'simulates IO failures via POSIX chmod' : false);

    test('merged accumulator maps stay readable through typed getProperty',
        () {
      final dir = Directory.systemTemp.createTempSync('posthog_storage_union');
      final seed = FileStorage(dir.path);
      seed.setProperty(PostHogPersistedProperty.props,
          <String, Object?>{'disk': 1});

      final dataFile = '${dir.path}/posthog_data.json';
      Process.runSync('chmod', ['000', dataFile]);
      addTearDown(() {
        Process.runSync('chmod', ['644', dataFile]);
        dir.deleteSync(recursive: true);
      });

      final blind = FileStorage(dir.path);
      blind.setProperty(PostHogPersistedProperty.props,
          <String, Object?>{'window': 2});

      Process.runSync('chmod', ['644', dataFile]);
      final merged = blind.getProperty<Map<String, Object?>>(
          PostHogPersistedProperty.props);
      expect(merged, isNotNull);
      expect(merged!['disk'], 1);
      expect(merged['window'], 2);
    }, skip: Platform.isWindows ? 'simulates IO failures via POSIX chmod' : false);

    test('unreadable directory is degraded, not a fresh store', () {
      final dir = Directory.systemTemp.createTempSync('posthog_storage_dir');
      final sub = Directory('${dir.path}/store')..createSync();
      FileStorage(sub.path)
          .setProperty(PostHogPersistedProperty.distinctId, 'keep');

      Process.runSync('chmod', ['000', sub.path]);
      addTearDown(() {
        Process.runSync('chmod', ['755', sub.path]);
        dir.deleteSync(recursive: true);
      });

      final blind = FileStorage(sub.path);
      expect(blind.isDegraded, isTrue);
      expect(
          blind.getProperty<String>(PostHogPersistedProperty.distinctId),
          isNull);

      Process.runSync('chmod', ['755', sub.path]);
      expect(
          blind.getProperty<String>(PostHogPersistedProperty.distinctId),
          'keep');
    }, skip: Platform.isWindows ? 'simulates IO failures via POSIX chmod' : false);
  });
}
