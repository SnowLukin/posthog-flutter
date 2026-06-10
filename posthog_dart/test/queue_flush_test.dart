import 'dart:io';

import 'package:posthog_dart/posthog_dart.dart';
import 'package:posthog_dart/src/http.dart';
import 'package:posthog_dart/src/posthog_core_stateless.dart';
import 'package:test/test.dart';

import 'test_client.dart';

void main() {
  group('flush queue removal', () {
    test('removes sent events by identity, not by position', () async {
      final storage = InMemoryStorage();
      final client = TestClient('k', options: testOptions(), storage: storage);

      client.capture('first');
      expect(getQueue(storage), hasLength(1));

      // The queue mutates while a batch is in flight.
      var enqueuedDuringFlight = false;
      client.fetchHandler = (url, options) async {
        if (!enqueuedDuringFlight) {
          enqueuedDuringFlight = true;
          client.capture('second');
        }
        return const PostHogFetchResponse(
            status: 200, body: '{"status": "ok"}');
      };

      await client.flush();

      // 'first' is removed by uuid, 'second' goes out on the next
      // iteration - nothing lost, nothing duplicated.
      final batchEvents = client.fetchCalls
          .where((c) => c.url.contains('/batch'))
          .map((c) => c.options.body)
          .toList();
      expect(batchEvents, hasLength(2));
      expect(batchEvents[0], contains('first'));
      expect(batchEvents[1], contains('second'));
      expect(getQueue(storage), isEmpty);
    });

    test('transient 500 is retried and keeps the batch queued', () async {
      final storage = InMemoryStorage();
      final client = TestClient('k',
          options: testOptions(fetchRetryCount: 1), storage: storage);
      client.fetchHandler = (url, options) =>
          const PostHogFetchResponse(status: 500, body: 'oops');

      client.capture('evt');
      await expectLater(
          client.flush(), throwsA(isA<PostHogFetchHttpError>()));

      expect(client.fetchCalls, hasLength(2));
      expect(getQueue(storage), hasLength(1));
    });

    test('hard 400 is not retried and drops the batch', () async {
      final storage = InMemoryStorage();
      final client = TestClient('k',
          options: testOptions(fetchRetryCount: 2), storage: storage);
      client.fetchHandler = (url, options) =>
          const PostHogFetchResponse(status: 400, body: 'bad');

      client.capture('evt');
      await expectLater(
          client.flush(), throwsA(isA<PostHogFetchHttpError>()));

      expect(client.fetchCalls, hasLength(1));
      expect(getQueue(storage), isEmpty);
    });

    test('failed flush re-arms the periodic timer', () async {
      final storage = InMemoryStorage();
      final client = TestClient('k',
          options:
              testOptions(flushInterval: const Duration(milliseconds: 50)),
          storage: storage);
      var failures = 0;
      client.fetchHandler = (url, options) {
        if (failures < 1) {
          failures++;
          throw PostHogFetchNetworkError(const SocketException('offline'));
        }
        return const PostHogFetchResponse(
            status: 200, body: '{"status": "ok"}');
      };

      client.capture('evt');
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(failures, 1);
      expect(getQueue(storage), isEmpty);
    });
  });

  group('super properties', () {
    test('props read through to storage without in-core memoization', () {
      final storage = InMemoryStorage();
      final client = TestClient('k', options: testOptions(), storage: storage);

      client.register({'a': 1});
      client.capture('warmup');

      // An external write to the store must be visible without a restart.
      storage.setProperty(PostHogPersistedProperty.props,
          <String, Object?>{'a': 1, 'external': true});
      client.capture('evt');

      final props = getQueue(storage)
          .map((item) =>
              (item as Map)['message'] as Map<String, Object?>)
          .lastWhere((m) => m['event'] == 'evt')['properties']
          as Map<String, Object?>;
      expect(props['external'], true);
    });
  });
}
