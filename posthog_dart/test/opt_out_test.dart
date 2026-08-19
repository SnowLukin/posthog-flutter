import 'package:posthog_dart/posthog_dart.dart';
import 'package:test/test.dart';

import 'posthog_core_fake.dart';

void main() {
  group('Opt-out consent', () {
    test('optOut: true blocks events until optIn()', () {
      final storage = InMemoryStorage();
      final client = PostHogCoreFake('k',
          options: testOptions(optOut: true), storage: storage);
      addTearDown(client.shutdown);

      client.capture('evt');

      expect(getQueue(storage), isEmpty);
      expect(client.optedOut, isTrue);
    });

    test('optIn() re-enables a client created with optOut: true', () {
      final storage = InMemoryStorage();
      final client = PostHogCoreFake('k',
          options: testOptions(optOut: true), storage: storage);
      addTearDown(client.shutdown);

      client.optIn();
      client.capture('evt');

      expect(client.optedOut, isFalse);
      expect(getQueue(storage), hasLength(1));
    });

    test('reset() keeps the persisted opt-out', () {
      final storage = InMemoryStorage();
      final client =
          PostHogCoreFake('k', options: testOptions(), storage: storage);
      addTearDown(client.shutdown);

      client.optOut();
      client.reset();

      expect(client.optedOut, isTrue);
      client.capture('evt');
      expect(getQueue(storage), isEmpty);
    });

    test('consent fails closed while the store is unreadable', () {
      final storage = _DegradedStorage();
      final client =
          PostHogCoreFake('k', options: testOptions(), storage: storage);
      addTearDown(client.shutdown);

      client.capture('evt');
      expect(getQueue(storage), isEmpty,
          reason: 'with consent unknown, tracking without it would be worse '
              'than dropping events');

      // An explicit opt-in during the window lifts the block.
      client.optIn();
      client.capture('evt');
      expect(getQueue(storage), hasLength(1));
    });
  });

  group('Disabled client', () {
    test('disabled: true drops events without queueing or network', () async {
      final storage = InMemoryStorage();
      final client = PostHogCoreFake('k',
          options: testOptions(disabled: true), storage: storage);
      addTearDown(client.shutdown);

      client.capture('evt');
      client.identify('user-1');
      await client.flush();

      expect(getQueue(storage), isEmpty);
      expect(client.fetchCalls, isEmpty);
    });
  });
}

class _DegradedStorage extends InMemoryStorage {
  @override
  bool get isDegraded => true;
}
