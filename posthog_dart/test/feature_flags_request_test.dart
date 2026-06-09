import 'dart:async';
import 'dart:convert';

import 'package:posthog_dart/posthog_dart.dart';
import 'package:test/test.dart';

import 'test_client.dart';

class _ThrowingStorage extends InMemoryStorage {
  @override
  T? getProperty<T>(PostHogPersistedProperty key) {
    if (key == PostHogPersistedProperty.distinctId) {
      throw StateError('storage failure');
    }
    return super.getProperty(key);
  }
}

void main() {
  group('feature flags request', () {
    test('non-string person properties are sent to /flags/', () async {
      final client = TestClient('k', options: testOptions());

      client.setPersonProperties(
        userPropertiesToSet: {'age': 30, 'beta': true, 'plan': 'pro'},
      );
      await client.reloadFeatureFlagsAsync();

      final flagsCalls =
          client.fetchCalls.where((c) => c.url.contains('/flags')).toList();
      expect(flagsCalls, isNotEmpty);

      final body =
          jsonDecode(flagsCalls.last.options.body!) as Map<String, Object?>;
      final personProperties = body['person_properties'] as Map<String, Object?>;
      expect(personProperties['age'], 30);
      expect(personProperties['beta'], true);
      expect(personProperties['plan'], 'pro');
    });

    test('pipeline errors do not become unhandled async errors', () async {
      final unhandled = <Object>[];
      await runZonedGuarded(() async {
        final client = TestClient(
          'k',
          options: testOptions(),
          storage: _ThrowingStorage(),
        );
        try {
          await client.reloadFeatureFlagsAsync();
        } catch (_) {
          // The direct caller handles the rethrown error; nothing should
          // leak through the shared flags future.
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }, (error, _) => unhandled.add(error));

      expect(unhandled, isEmpty);
    });
  });
}
