import 'package:posthog_dart/posthog_dart.dart';
import 'package:posthog_dart/src/http.dart';
import 'package:test/test.dart';

import 'test_client.dart';

void main() {
  group('flush queue removal', () {
    test('removes sent events by identity, not by position', () async {
      final storage = InMemoryStorage();
      final client = TestClient('k', options: testOptions(), storage: storage);

      client.capture('first');
      expect(getQueue(storage), hasLength(1));

      // Очередь мутирует, пока батч в полёте: capture во время await POST.
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

      // 'first' удалён по uuid, 'second' (встал в очередь во время полёта
      // первого батча) отправлен следующей итерацией - ничего не потеряно
      // и не задублировано.
      final batchEvents = client.fetchCalls
          .where((c) => c.url.contains('/batch'))
          .map((c) => c.options.body)
          .toList();
      expect(batchEvents, hasLength(2));
      expect(batchEvents[0], contains('first'));
      expect(batchEvents[1], contains('second'));
      expect(getQueue(storage), isEmpty);
    });
  });

  group('super properties', () {
    test('props read through to storage without in-core memoization', () {
      final storage = InMemoryStorage();
      final client = TestClient('k', options: testOptions(), storage: storage);

      client.register({'a': 1});
      client.capture('warmup');

      // Внешняя запись в стор (storage-recovery merge, другой слой) должна
      // быть видна core без рестарта.
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
