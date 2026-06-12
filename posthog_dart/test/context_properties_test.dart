import 'package:posthog_dart/posthog_dart.dart';
import 'package:test/test.dart';

import 'test_client.dart';

class ContextTestClient extends TestClient {
  ContextTestClient(super.apiKey, {super.options, super.storage});

  @override
  Map<String, Object?> getContextProperties() => {
        r'$os_name': 'TestOS',
        r'$app_version': '1.0.0',
      };
}

Map<String, Object?> queuedProps(PostHogStorage storage) {
  final message =
      getQueue(storage).single['message']! as Map<String, Object?>;
  return message['properties']! as Map<String, Object?>;
}

void main() {
  group('context properties', () {
    test('attached to every captured event', () {
      final storage = InMemoryStorage();
      final client =
          ContextTestClient('k', options: testOptions(), storage: storage);

      client.capture('event', properties: {'foo': 'bar'});

      final props = queuedProps(storage);
      expect(props[r'$os_name'], 'TestOS');
      expect(props[r'$app_version'], '1.0.0');
      expect(props['foo'], 'bar');
    });

    test('overridden by super properties and event properties', () {
      final storage = InMemoryStorage();
      final client =
          ContextTestClient('k', options: testOptions(), storage: storage);

      client.register({r'$os_name': 'FromSuperProps'});
      client.capture('event', properties: {r'$app_version': '2.0.0'});

      final props = queuedProps(storage);
      expect(props[r'$os_name'], 'FromSuperProps');
      expect(props[r'$app_version'], '2.0.0');
    });

    test('absent by default', () {
      final storage = InMemoryStorage();
      final client = TestClient('k', options: testOptions(), storage: storage);

      client.capture('event');

      final props = queuedProps(storage);
      expect(props.containsKey(r'$os_name'), isFalse);
    });
  });
}
