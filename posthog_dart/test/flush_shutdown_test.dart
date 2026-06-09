import 'dart:io';

import 'package:posthog_dart/posthog_dart.dart';
import 'package:posthog_dart/src/posthog_core_stateless.dart';
import 'package:test/test.dart';

import 'test_client.dart';

void main() {
  group('shutdown', () {
    test('completes despite network errors and keeps events queued', () async {
      final storage = InMemoryStorage();
      final client = TestClient('k', options: testOptions(), storage: storage);
      client.fetchHandler = (url, options) =>
          throw PostHogFetchNetworkError(const SocketException('offline'));

      client.capture('evt');
      await client.shutdown();

      expect(getQueue(storage), hasLength(1));
    });
  });
}
