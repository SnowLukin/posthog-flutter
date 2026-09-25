import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:posthog_flutter/src/core/file_storage.dart';
import 'package:posthog_flutter/src/core/persistence.dart';
import 'package:posthog_flutter/src/core/posthog_core_stateless.dart';

import '../posthog_api_fake.dart';
import 'test_client.dart';

void main() {
  group('PostHogCore.flush', () {
    late LocalPostHogServer server;

    setUp(() async {
      server = await LocalPostHogServer.start();
    });

    test('sends queued events in one batch and empties the queue', () async {
      final storage = tempStorage();
      final client = testClient(server, storage: storage);

      client.capture('sign_in');
      client.capture('sign_out');
      await client.flush();

      expect(server.batchRequests.single.eventNames, ['sign_in', 'sign_out']);
      expect(getQueue(storage), isEmpty);
    });

    test('removes sent events by identity when the queue head shifts',
        () async {
      final storage = tempStorage();
      final client = testClient(server,
          config: testConfig(flushAt: 2, maxBatchSize: 2, maxQueueSize: 2),
          storage: storage);

      final inFlight = Completer<void>();
      final release = Completer<void>();
      server.respond = (request) async {
        if (!inFlight.isCompleted) {
          inFlight.complete();
          await release.future;
        }
        return const PostHogResponse(HttpStatus.ok);
      };

      client.capture('first');
      client.capture('second'); // reaches flushAt, the batch takes off
      await inFlight.future;
      // Overflow while the batch is in flight: 'first' is evicted, so the
      // batch and the queue no longer line up positionally.
      client.capture('third');
      release.complete();
      await client.flush();

      expect(
        [for (final request in server.batchRequests) request.eventNames],
        [
          ['first', 'second'],
          ['third'],
        ],
        reason: "removal must match by uuid: positional removal would delete "
            "'third' from the queue instead of the already-evicted 'first'",
      );
      expect(getQueue(storage), isEmpty);
    });

    test('halves the batch size on HTTP 413 until the server accepts',
        () async {
      final storage = tempStorage();
      final client = testClient(server, storage: storage);
      // This server rejects anything bigger than two events per request.
      server.respond = (request) => PostHogResponse(request.events.length > 2
          ? HttpStatus.requestEntityTooLarge
          : HttpStatus.ok);

      for (var i = 0; i < 8; i++) {
        client.capture('event_$i');
      }
      await client.flush();

      final batches = [
        for (final request in server.batchRequests) request.eventNames,
      ];
      expect(batches.map((batch) => batch.length).toList(), [8, 4, 2, 2, 2, 2]);
      expect(batches.skip(2).expand((batch) => batch).toList(),
          [for (var i = 0; i < 8; i++) 'event_$i']);
      expect(getQueue(storage), isEmpty);
    });

    test('shares one network cycle between concurrent calls', () async {
      final storage = tempStorage();
      final client = testClient(server, storage: storage);
      final release = Completer<void>();
      server.respond = (request) async {
        await release.future;
        return const PostHogResponse(HttpStatus.ok);
      };

      client.capture('evt');
      final first = client.flush();
      final second = client.flush();
      release.complete();
      await Future.wait([first, second]);

      expect(server.batchRequests, hasLength(1));
      expect(getQueue(storage), isEmpty);
    });

    test('hard HTTP 400 is not retried and drops the batch', () async {
      final storage = tempStorage();
      final client = testClient(server, storage: storage);
      server.respond = (_) => const PostHogResponse(HttpStatus.badRequest);

      client.capture('evt');
      await expectLater(client.flush(), throwsA(isA<PostHogFetchHttpError>()));

      expect(server.batchRequests, hasLength(1));
      expect(getQueue(storage), isEmpty);
    });

    test('retries a transient failure three times, three seconds apart', () {
      final api = InProcessPostHogApi()
        ..respond = (_) => const PostHogResponse(HttpStatus.serviceUnavailable);
      final storage = tempStorage();
      fakeAsync((async) {
        final client = testClient(api, storage: storage);
        Object? error;

        client.capture('evt');
        client.flush().catchError((Object e) {
          error = e;
        });

        async.elapse(Duration.zero);
        expect(api.batchRequests, hasLength(1));
        for (final attempts in [2, 3, 4]) {
          async.elapse(const Duration(milliseconds: 2999));
          expect(api.batchRequests, hasLength(attempts - 1));
          async.elapse(const Duration(milliseconds: 1));
          expect(api.batchRequests, hasLength(attempts));
        }
        expect(error, isA<PostHogFetchHttpError>());
        expect(getQueue(storage), hasLength(1));
      });
    });

    // (status, reason the batch stays queued)
    const transientStatuses = <(int, String)>[
      (408, 'the server timed out'),
      (429, 'the server asks to slow down'),
      (500, 'the server failed'),
      (
        301,
        'a POST redirect is not followed, so the batch never reached '
            'ingestion'
      ),
      (
        307,
        'a POST redirect is not followed, so the batch never reached '
            'ingestion'
      ),
    ];

    for (final (status, reason) in transientStatuses) {
      test('HTTP $status keeps the batch queued after the retries', () {
        final api = InProcessPostHogApi()
          ..respond = (_) => PostHogResponse(status);
        final storage = tempStorage();
        fakeAsync((async) {
          final client = testClient(api, storage: storage);
          Object? error;

          client.capture('evt');
          client.flush().catchError((Object e) {
            error = e;
          });
          async.elapse(const Duration(seconds: 9));

          expect(error, isA<PostHogFetchHttpError>());
          expect(api.batchRequests, hasLength(4));
          expect(getQueue(storage), hasLength(1), reason: reason);
        });
      });
    }

    test('a failed flush re-arms the periodic timer', () {
      final api = InProcessPostHogApi();
      var online = false;
      api.respond = (_) => online
          ? const PostHogResponse(HttpStatus.ok)
          : const PostHogResponse.dropped();
      final storage = tempStorage();
      fakeAsync((async) {
        testClient(api, storage: storage).capture('evt');

        // The periodic flush and its retries fail.
        async.elapse(const Duration(seconds: 39));
        expect(api.batchRequests, hasLength(4));

        online = true;
        // Only a re-armed timer can produce the next, successful attempt.
        async.elapse(const Duration(seconds: 30));

        expect(api.batchRequests, hasLength(5));
        expect(getQueue(storage), isEmpty);
      });
    });

    test('the timer firing while a flush is in flight stays re-armable', () {
      final api = InProcessPostHogApi();
      final storage = tempStorage();
      fakeAsync((async) {
        final release = Completer<void>();
        var online = false;
        api.respond = (_) async {
          await release.future;
          return PostHogResponse(
              online ? HttpStatus.ok : HttpStatus.serviceUnavailable);
        };
        final client = testClient(api,
            config: testConfig(flushInterval: const Duration(milliseconds: 20)),
            storage: storage);

        client.capture('first');
        client.flush().catchError((Object _) {});
        // Arms the timer again while the flush above is still in flight, and
        // lets it fire during that flush.
        client.capture('second');
        async.elapse(const Duration(milliseconds: 60));
        release.complete();
        // The flush and its retries fail.
        async.elapse(const Duration(seconds: 9));
        expect(api.batchRequests, hasLength(4));

        online = true;
        async.elapse(const Duration(milliseconds: 20));

        expect(api.batchRequests.last.eventNames, ['first', 'second'],
            reason: 'only a re-armed timer sends the queue again');
        expect(getQueue(storage), isEmpty);
      });
    });
  });

  group('Automatic flushing', () {
    test('flushes as soon as the queue reaches flushAt', () async {
      final server = await LocalPostHogServer.start();
      final storage = tempStorage();
      final client =
          testClient(server, config: testConfig(flushAt: 3), storage: storage);

      client.capture('one');
      client.capture('two');
      client.capture('three');
      await server.waitForEvent('three');
      await client.flush();

      expect(server.batchRequests.first.eventNames, ['one', 'two', 'three'],
          reason: 'a flush that took off before flushAt would have sent the '
              'first events on their own');
      expect(getQueue(storage), isEmpty);
    });

    test('drops the oldest events once the queue exceeds maxQueueSize', () {
      final api = InProcessPostHogApi()
        ..respond = (_) => const PostHogResponse(HttpStatus.serviceUnavailable);
      final storage = tempStorage();
      fakeAsync((async) {
        final client = testClient(api,
            config: testConfig(
                flushAt: 1, maxQueueSize: 100, flushInterval: Duration.zero),
            storage: storage);
        // Delivery keeps failing, so every event stays queued and only the
        // overflow rule decides which ones survive.

        for (var i = 0; i < 102; i++) {
          client.capture('event_$i');
        }
        async.elapse(const Duration(seconds: 9));

        expect(
            queuedEvents(storage), [for (var i = 2; i <= 101; i++) 'event_$i']);
      });
    });

    test('keeps at most maxQueueSize events, also below flushAt', () {
      final api = InProcessPostHogApi();
      final storage = tempStorage();
      fakeAsync((async) {
        final client = testClient(api,
            config: testConfig(flushAt: 20, maxQueueSize: 2, debug: true),
            storage: storage);

        final lines = printedLines(() {
          for (var i = 0; i < 3; i++) {
            client.capture('event_$i');
          }
        });

        expect(queuedEvents(storage), ['event_1', 'event_2']);
        expect(lines, contains(contains('Queue is full')));

        // The queue cannot reach flushAt: the periodic flush sends it.
        async.elapse(const Duration(seconds: 30));
        expect(api.batchRequests.single.eventNames, ['event_1', 'event_2']);
        expect(getQueue(storage), isEmpty);
      });
    });

    test('sends batches of at most maxBatchSize, also below flushAt', () {
      final api = InProcessPostHogApi();
      final storage = tempStorage();
      fakeAsync((async) {
        final client = testClient(api,
            config: testConfig(flushAt: 5, maxBatchSize: 2), storage: storage);

        for (var i = 0; i < 5; i++) {
          client.capture('event_$i');
        }
        async.elapse(Duration.zero);

        expect([
          for (final request in api.batchRequests) request.eventNames
        ], [
          ['event_0', 'event_1'],
          ['event_2', 'event_3'],
          ['event_4'],
        ]);
        expect(getQueue(storage), isEmpty);
      });
    });
  });

  group('Queue persistence', () {
    late LocalPostHogServer server;

    setUp(() async {
      server = await LocalPostHogServer.start();
    });

    test('flushes events captured by a previous process from FileStorage',
        () async {
      final dir = tempDirectory();
      testClient(server, storage: FileStorage(dir.path))
        ..capture('sign_in')
        ..capture('sign_out')
        ..close();

      final storage = FileStorage(dir.path);
      await testClient(server, storage: storage).flush();

      expect(server.batchRequests.single.eventNames, ['sign_in', 'sign_out']);
      expect(getQueue(storage), isEmpty);
      expect(Directory('${dir.path}/posthog_queue').listSync(), isEmpty,
          reason: 'delivered events must also leave the on-disk queue');
    });

    test('sends events of a previous run without waiting for a capture',
        () async {
      final dir = tempDirectory();
      testClient(server, storage: FileStorage(dir.path))
        ..capture('sign_in')
        ..close();

      final storage = FileStorage(dir.path);
      final client = testClient(server,
          config: testConfig(flushInterval: const Duration(milliseconds: 20)),
          storage: storage);
      await server.waitForEvent('sign_in');
      await client.flush();

      expect(server.batchRequests.single.eventNames, ['sign_in']);
      expect(getQueue(storage), isEmpty);
    });
  });

  group('PostHogCore.close', () {
    late LocalPostHogServer server;

    setUp(() async {
      server = await LocalPostHogServer.start();
    });

    test('aborts a batch in flight without retrying it; the batch stays queued',
        () async {
      final storage = tempStorage();
      final client = testClient(server, storage: storage);
      final received = Completer<void>();
      server.respond = (_) {
        received.complete();
        return Completer<PostHogResponse>().future;
      };
      client.capture('evt');
      final inFlight = client.flush();
      await received.future;

      client.close();

      // Well within the request timeout, so only an aborted request fails.
      await expectLater(inFlight.timeout(const Duration(seconds: 5)),
          throwsA(isA<PostHogFetchNetworkError>()));
      expect(server.batchRequests, hasLength(1), reason: 'it is not retried');
      expect(getQueue(storage), hasLength(1),
          reason: 'the next client using the storage sends it');
    });

    test('closes its connections to PostHog', () async {
      final client = testClient(server);
      client.capture('evt');
      await client.flush();
      expect(server.openConnections, 1,
          reason: 'the client keeps its connection alive between requests');

      client.close();

      await server.connectionsClosed();
    });

    test('ignores calls made afterwards', () async {
      final storage = tempStorage();
      final client =
          testClient(server, config: testConfig(debug: true), storage: storage);
      final distinctId = client.getDistinctId();
      client.close();

      late Future<void> reload;
      final lines = printedLines(() {
        client.capture('After Close');
        client.identify('user-1');
        client.register({'plan': 'pro'});
        reload = client.reloadFeatureFlagsAsync();
      });
      await reload;
      await client.flush();

      expect(getQueue(storage), isEmpty);
      expect(client.getDistinctId(), distinctId);
      expect(
          storage.getProperty<Object>(PostHogPersistedProperty.props), isNull);
      expect(server.requests, isEmpty);
      expect(lines, contains(contains('closed')));
    });

    test('stops the periodic flush', () {
      final api = InProcessPostHogApi();
      fakeAsync((async) {
        final client = testClient(api);
        client.capture('before close');

        client.close();

        expect(async.pendingTimers, isEmpty);
      });
    });

    test('a flush that fails after close does not re-arm the timer', () {
      final api = InProcessPostHogApi();
      fakeAsync((async) {
        final release = Completer<void>();
        api.respond = (_) async {
          await release.future;
          return const PostHogResponse(HttpStatus.serviceUnavailable);
        };
        final client = testClient(api);
        Object? error;
        client.capture('evt');
        client.flush().catchError((Object e) {
          error = e;
        });
        async.elapse(Duration.zero);

        client.close();
        release.complete();
        async.flushMicrotasks();

        expect(error, isA<PostHogFetchHttpError>());
        expect(api.batchRequests, hasLength(1));
        expect(async.pendingTimers, isEmpty,
            reason: 'a re-armed timer would flush a client whose resources '
                'are already released');
      });
    });

    test('releases the storage directory for the next client', () async {
      final dir = tempDirectory();
      testClient(server, storage: FileStorage(dir.path))
        ..capture('queued before close')
        ..close();

      final next = testClient(server, storage: FileStorage(dir.path));
      next.identify('next-user');
      await next.flush();

      expect(
          FileStorage(dir.path)
              .getProperty<String>(PostHogPersistedProperty.distinctId),
          'next-user');
      expect(server.batchRequests.single.eventNames,
          ['queued before close', r'$identify']);
    });
  });
}
