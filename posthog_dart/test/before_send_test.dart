import 'package:posthog_dart/posthog_dart.dart';
import 'package:test/test.dart';

import 'test_client.dart';

Map<String, Object?> queuedProps(PostHogStorage storage, int index) {
  final message =
      getQueue(storage)[index]['message'] as Map<String, Object?>;
  return message['properties'] as Map<String, Object?>;
}

void main() {
  group('beforeSend', () {
    test('null property values do not crash the pipeline', () {
      final storage = InMemoryStorage();
      final client = TestClient(
        'k',
        options: testOptions(beforeSend: [(event) => event]),
        storage: storage,
      );

      client.capture('evt', properties: {'a': null, 'b': 1});

      expect(getQueue(storage), hasLength(1));
      expect(queuedProps(storage, 0)['b'], 1);
    });

    test('internal \$set maps of loose runtime types do not crash', () {
      final storage = InMemoryStorage();
      final client = TestClient(
        'k',
        options: testOptions(beforeSend: [(event) => event]),
        storage: storage,
      );

      client.setPersonProperties(userPropertiesToSet: {'plan': 'pro'});

      expect(getQueue(storage), hasLength(1));
    });

    test('an async callback runs exactly once per event', () async {
      var calls = 0;
      final storage = InMemoryStorage();
      final client = TestClient(
        'k',
        options: testOptions(beforeSend: [
          (event) async {
            calls++;
            return event;
          }
        ]),
        storage: storage,
      );

      client.capture('evt');
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(calls, 1);
      expect(getQueue(storage), hasLength(1));
    });

    test('mixed sync/async chain runs each callback once, in order', () async {
      final invocations = <String>[];
      PostHogEvent mark(PostHogEvent event, String name) {
        invocations.add(name);
        event.properties = {...?event.properties, name: true};
        return event;
      }

      final storage = InMemoryStorage();
      final client = TestClient(
        'k',
        options: testOptions(beforeSend: [
          (event) => mark(event, 'first'),
          (event) async => mark(event, 'second'),
          (event) => mark(event, 'third'),
        ]),
        storage: storage,
      );

      client.capture('evt');
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(invocations, ['first', 'second', 'third']);
      final props = queuedProps(storage, 0);
      expect(props['first'], true);
      expect(props['second'], true);
      expect(props['third'], true);
    });
  });
}
