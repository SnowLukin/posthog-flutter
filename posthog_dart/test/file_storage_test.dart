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
    });

    test('transient read failure does not clobber persisted data', () {
      final dir = Directory.systemTemp.createTempSync('posthog_storage_rd');
      FileStorage(dir.path)
          .setProperty(PostHogPersistedProperty.distinctId, 'keep');

      final dataFile = '${dir.path}/posthog_data.json';
      Process.runSync('chmod', ['000', dataFile]);
      addTearDown(() {
        Process.runSync('chmod', ['644', dataFile]);
        dir.deleteSync(recursive: true);
      });

      final blindStorage = FileStorage(dir.path);
      expect(
          blindStorage.getProperty<String>(PostHogPersistedProperty.distinctId),
          isNull);
      expect(
          () => blindStorage.setProperty(
              PostHogPersistedProperty.distinctId, 'clobber'),
          returnsNormally);

      Process.runSync('chmod', ['644', dataFile]);
      expect(
          FileStorage(dir.path)
              .getProperty<String>(PostHogPersistedProperty.distinctId),
          'keep');
    });
  });
}
