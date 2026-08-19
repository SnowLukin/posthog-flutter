import 'package:posthog_dart/posthog_dart.dart';
import 'package:test/test.dart';

import 'posthog_core_fake.dart';

void main() {
  group('Context properties', () {
    test('attached to every captured event', () {
      final storage = InMemoryStorage();
      final client =
          _ContextPropertiesFake('k', options: testOptions(), storage: storage);
      addTearDown(client.shutdown);

      client.capture('event', properties: {'foo': 'bar'});

      final props = queuedProps(storage, 0);
      expect(props[r'$os_name'], 'TestOS');
      expect(props[r'$app_version'], '1.0.0');
      expect(props['foo'], 'bar');
    });

    test('overridden by super properties and event properties', () {
      final storage = InMemoryStorage();
      final client =
          _ContextPropertiesFake('k', options: testOptions(), storage: storage);
      addTearDown(client.shutdown);

      client.register({r'$os_name': 'FromSuperProps'});
      client.capture('event', properties: {r'$app_version': '2.0.0'});

      final props = queuedProps(storage, 0);
      expect(props[r'$os_name'], 'FromSuperProps');
      expect(props[r'$app_version'], '2.0.0');
    });

    test('absent by default', () {
      final storage = InMemoryStorage();
      final client =
          PostHogCoreFake('k', options: testOptions(), storage: storage);
      addTearDown(client.shutdown);

      client.capture('event');

      expect(queuedProps(storage, 0).containsKey(r'$os_name'), isFalse);
    });
  });
}

class _ContextPropertiesFake extends PostHogCoreFake {
  _ContextPropertiesFake(super.apiKey, {super.options, super.storage});

  @override
  Map<String, Object?> getContextProperties() => {
        r'$os_name': 'TestOS',
        r'$app_version': '1.0.0',
      };
}
