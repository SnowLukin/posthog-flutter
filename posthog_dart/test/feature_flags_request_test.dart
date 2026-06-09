import 'dart:convert';

import 'package:test/test.dart';

import 'test_client.dart';

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
  });
}
