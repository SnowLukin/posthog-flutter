import 'package:posthog_dart/posthog_dart.dart';
import 'package:test/test.dart';

import 'test_client.dart';

class _DegradedStorage extends InMemoryStorage {
  @override
  bool get isDegraded => true;
}

void main() {
  group('opt-out', () {
    test('optOut: true blocks events until optIn()', () {
      final storage = InMemoryStorage();
      final client =
          TestClient('k', options: testOptions(optOut: true), storage: storage);

      client.capture('evt');
      expect(getQueue(storage), isEmpty);
      expect(client.optedOut, isTrue);
    });

    test('optIn() re-enables a client created with optOut: true', () {
      final storage = InMemoryStorage();
      final client =
          TestClient('k', options: testOptions(optOut: true), storage: storage);

      client.optIn();
      client.capture('evt');

      expect(client.isDisabled, isFalse);
      expect(client.optedOut, isFalse);
      expect(getQueue(storage), hasLength(1));
    });

    test('reset() keeps the persisted opt-out', () {
      final storage = InMemoryStorage();
      final client = TestClient('k', options: testOptions(), storage: storage);

      client.optOut();
      client.reset();

      expect(client.optedOut, isTrue);
      client.capture('evt');
      expect(getQueue(storage), isEmpty);
    });

    test('consent fails closed while the store is unreadable', () {
      final storage = _DegradedStorage();
      final client = TestClient('k', options: testOptions(), storage: storage);

      client.capture('evt');
      expect(getQueue(storage), isEmpty);

      // An explicit opt-in during the window lifts the block.
      client.optIn();
      client.capture('evt');
      expect(getQueue(storage), hasLength(1));
    });
  });
}
