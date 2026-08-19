import 'dart:io';

import 'package:posthog_dart/posthog_dart.dart';
import 'package:test/test.dart';

void main() {
  group('FileStorage', () {
    test('setting a property to null removes it from the persisted snapshot',
        () {
      final dir = Directory.systemTemp.createTempSync('posthog_storage_null');
      addTearDown(() => dir.deleteSync(recursive: true));
      final storage = FileStorage(dir.path);
      storage.setProperty(PostHogPersistedProperty.distinctId, 'user-1');
      storage.setProperty(PostHogPersistedProperty.sessionId, 'session-1');

      storage.setProperty(PostHogPersistedProperty.distinctId, null);

      final reopened = FileStorage(dir.path);
      expect(reopened.getProperty<String>(PostHogPersistedProperty.distinctId),
          isNull);
      expect(reopened.getProperty<String>(PostHogPersistedProperty.sessionId),
          'session-1');
    });

    // (description, on-disk bytes)
    final utf8Corruptions = <(String, List<int>)>[
      (
        'a multi-byte character truncated by a torn write',
        [0x7b, 0x22, 0xd0],
      ),
      (
        // {"distinct_id":"a<0xD0>b"}: the JSON structure is intact, but the
        // continuation-less byte fails strict UTF-8 decoding.
        'an invalid byte inside a string value',
        [...'{"distinct_id":"a'.codeUnits, 0xd0, ...'b"}'.codeUnits],
      ),
    ];

    for (final (description, bytes) in utf8Corruptions) {
      test('resets the store when the file holds $description', () {
        final dir = Directory.systemTemp.createTempSync('posthog_storage_utf8');
        addTearDown(() => dir.deleteSync(recursive: true));
        File('${dir.path}/posthog_data.json').writeAsBytesSync(bytes);

        final storage = FileStorage(dir.path);
        expect(storage.isDegraded, isFalse);
        expect(storage.getProperty<String>(PostHogPersistedProperty.distinctId),
            isNull,
            reason: 'corrupt bytes must reset the store, not brick it or '
                'resurrect mangled values via lenient decoding');

        // Self-heal: the next write persists a fresh valid snapshot.
        storage.setProperty(PostHogPersistedProperty.distinctId, 'healed');
        expect(
            FileStorage(dir.path)
                .getProperty<String>(PostHogPersistedProperty.distinctId),
            'healed');
      });
    }

    // (description, on-disk content)
    const corruptContents = <(String, String)>[
      ('an empty file', ''),
      ('a JSON string', '"posthog"'),
      ('a JSON array', '[1, 2]'),
      ('truncated JSON', '{"distinct_id":'),
    ];

    for (final (description, content) in corruptContents) {
      test('resets a store holding $description and heals on the next write',
          () {
        final dir = Directory.systemTemp.createTempSync('posthog_storage_bad');
        addTearDown(() => dir.deleteSync(recursive: true));
        File('${dir.path}/posthog_data.json').writeAsStringSync(content);

        final storage = FileStorage(dir.path);
        expect(storage.isDegraded, isFalse);
        expect(storage.getProperty<String>(PostHogPersistedProperty.distinctId),
            isNull);

        storage.setProperty(PostHogPersistedProperty.distinctId, 'healed');
        expect(
            FileStorage(dir.path)
                .getProperty<String>(PostHogPersistedProperty.distinctId),
            'healed');
      });
    }

    test('a failed write keeps the value in memory and does not throw', () {
      final dir = Directory.systemTemp.createTempSync('posthog_storage_ro');
      addTearDown(() {
        _chmod('755', dir.path);
        dir.deleteSync(recursive: true);
      });
      final storage = FileStorage(dir.path);
      storage.setProperty(PostHogPersistedProperty.distinctId, 'a');

      // Snapshots go through tmp+rename, so blocking the write means
      // removing write permission from the directory, not the file.
      _chmod('555', dir.path);

      expect(
          () => storage.setProperty(PostHogPersistedProperty.distinctId, 'b'),
          returnsNormally);
      expect(storage.getProperty<String>(PostHogPersistedProperty.distinctId),
          'b');

      _chmod('755', dir.path);
      storage.setProperty(PostHogPersistedProperty.sessionId, 's');
      // The next successful write persists the whole snapshot, 'b' included.
      expect(
          FileStorage(dir.path)
              .getProperty<String>(PostHogPersistedProperty.distinctId),
          'b');
    }, skip: _chmodSkip);

    test('a failed write leaves the on-disk snapshot untouched', () {
      final dir = Directory.systemTemp.createTempSync('posthog_storage_disk');
      addTearDown(() {
        _chmod('755', dir.path);
        dir.deleteSync(recursive: true);
      });
      final storage = FileStorage(dir.path);
      storage.setProperty(PostHogPersistedProperty.distinctId, 'a');

      _chmod('555', dir.path);
      storage.setProperty(PostHogPersistedProperty.distinctId, 'b');

      expect(
          FileStorage(dir.path)
              .getProperty<String>(PostHogPersistedProperty.distinctId),
          'a',
          reason: 'the data file itself stayed writable, so an in-place '
              'write (instead of tmp+rename) would have replaced the good '
              'snapshot');
    }, skip: _chmodSkip);

    test('writes while the disk is unreadable are dropped, disk intact', () {
      final dir = Directory.systemTemp.createTempSync('posthog_storage_rd');
      final dataFile = '${dir.path}/posthog_data.json';
      addTearDown(() {
        _chmod('644', dataFile);
        dir.deleteSync(recursive: true);
      });
      final seed = FileStorage(dir.path);
      seed.setProperty(PostHogPersistedProperty.distinctId, 'keep');
      seed.setProperty(PostHogPersistedProperty.sessionId, 'sess');

      _chmod('000', dataFile);

      final blind = FileStorage(dir.path);
      expect(blind.isDegraded, isTrue);
      expect(
          () =>
              blind.setProperty(PostHogPersistedProperty.distinctId, 'clobber'),
          returnsNormally);
      expect(blind.getProperty<String>(PostHogPersistedProperty.distinctId),
          isNull);

      _chmod('644', dataFile);
      expect(blind.isDegraded, isFalse,
          reason: 'degradation describes the disk, not the instance: it '
              'must lift as soon as the disk is readable again');
      expect(blind.getProperty<String>(PostHogPersistedProperty.distinctId),
          'keep');
      expect(blind.getProperty<String>(PostHogPersistedProperty.sessionId),
          'sess');
    }, skip: _chmodSkip);

    test('an unreadable directory reads as degraded, not as a fresh store', () {
      final dir = Directory.systemTemp.createTempSync('posthog_storage_dir');
      final sub = Directory('${dir.path}/store')..createSync();
      addTearDown(() {
        _chmod('755', sub.path);
        dir.deleteSync(recursive: true);
      });
      FileStorage(sub.path)
          .setProperty(PostHogPersistedProperty.distinctId, 'keep');

      _chmod('000', sub.path);

      final blind = FileStorage(sub.path);
      expect(blind.isDegraded, isTrue);
      expect(blind.getProperty<String>(PostHogPersistedProperty.distinctId),
          isNull);

      _chmod('755', sub.path);
      expect(blind.getProperty<String>(PostHogPersistedProperty.distinctId),
          'keep');
    }, skip: _chmodSkip);
  });
}

final _chmodSkip =
    Platform.isWindows ? 'simulates IO failures via POSIX chmod' : false;

/// Applies [mode] via chmod, failing the test if the probe cannot be set up.
void _chmod(String mode, String path) {
  final result = Process.runSync('chmod', [mode, path]);
  expect(result.exitCode, 0,
      reason: 'chmod $mode must succeed for the probe to prove anything');
}
