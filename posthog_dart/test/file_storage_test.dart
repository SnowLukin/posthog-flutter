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
      expect(storage.getProperty<String>(PostHogPersistedProperty.distinctId),
          'id-1');

      // The value made it to disk, not just into the in-memory cache.
      storage.clearCache();
      expect(storage.getProperty<String>(PostHogPersistedProperty.distinctId),
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
      expect(storage.getProperty<String>(PostHogPersistedProperty.distinctId),
          'b');

      Process.runSync('chmod', ['755', dir.path]);
      storage.setProperty(PostHogPersistedProperty.sessionId, 's');
      storage.clearCache();
      expect(storage.getProperty<String>(PostHogPersistedProperty.distinctId),
          'b');
    },
        skip: Platform.isWindows
            ? 'simulates IO failures via POSIX chmod'
            : false);

    test('invalid UTF-8 resets the store instead of bricking it', () {
      final dir = Directory.systemTemp.createTempSync('posthog_storage_utf8');
      addTearDown(() => dir.deleteSync(recursive: true));
      // Torn write: a multibyte character truncated mid-sequence.
      File('${dir.path}/posthog_data.json')
          .writeAsBytesSync([0x7b, 0x22, 0xd0]);

      final storage = FileStorage(dir.path);
      expect(storage.isDegraded, isFalse);
      expect(storage.getProperty<String>(PostHogPersistedProperty.distinctId),
          isNull);

      // Self-heal: the next write persists a fresh valid snapshot.
      storage.setProperty(PostHogPersistedProperty.distinctId, 'healed');
      storage.clearCache();
      expect(storage.getProperty<String>(PostHogPersistedProperty.distinctId),
          'healed');
    });

    test('value of an unexpected type reads as null instead of throwing', () {
      final dir = Directory.systemTemp.createTempSync('posthog_storage_type');
      addTearDown(() => dir.deleteSync(recursive: true));
      final storage = FileStorage(dir.path);

      storage.setProperty<Object>(PostHogPersistedProperty.queue, 'garbage');

      expect(storage.getProperty<List<Object?>>(PostHogPersistedProperty.queue),
          isNull);
      expect(storage.getProperty<String>(PostHogPersistedProperty.queue),
          'garbage');

      final memory = InMemoryStorage();
      memory.setProperty<Object>(PostHogPersistedProperty.distinctId, 42);
      expect(memory.getProperty<String>(PostHogPersistedProperty.distinctId),
          isNull);
    });

    test('writes while the disk is unreadable are dropped, disk intact', () {
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
      expect(blind.isDegraded, isTrue);
      expect(
          () =>
              blind.setProperty(PostHogPersistedProperty.distinctId, 'clobber'),
          returnsNormally);
      expect(blind.getProperty<String>(PostHogPersistedProperty.distinctId),
          isNull);

      Process.runSync('chmod', ['644', dataFile]);
      expect(blind.getProperty<String>(PostHogPersistedProperty.distinctId),
          'keep');
      expect(blind.getProperty<String>(PostHogPersistedProperty.sessionId),
          'sess');
    },
        skip: Platform.isWindows
            ? 'simulates IO failures via POSIX chmod'
            : false);

    test('refused rename falls back to copy and reports it', () {
      final dir = Directory.systemTemp.createTempSync('posthog_storage_rn');
      addTearDown(() => dir.deleteSync(recursive: true));
      final reports = <String>[];
      final storage = FileStorage(
        dir.path,
        onError: (message, error) => reports.add(message),
        rename: (source, targetPath) => throw const FileSystemException(
            'rename refused by antivirus', '', OSError('', 17)),
      );

      storage.setProperty(PostHogPersistedProperty.distinctId, 'id-1');

      storage.clearCache();
      expect(storage.getProperty<String>(PostHogPersistedProperty.distinctId),
          'id-1');
      expect(File('${dir.path}/posthog_data.json.tmp').existsSync(), isFalse);
      expect(reports.single, contains('rename refused'));
    });

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
      expect(blind.getProperty<String>(PostHogPersistedProperty.distinctId),
          isNull);

      Process.runSync('chmod', ['755', sub.path]);
      expect(blind.getProperty<String>(PostHogPersistedProperty.distinctId),
          'keep');
    },
        skip: Platform.isWindows
            ? 'simulates IO failures via POSIX chmod'
            : false);
  });
}
