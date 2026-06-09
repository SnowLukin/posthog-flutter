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

    test('disk write failure does not throw into the caller', () {
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
    });
  });
}
