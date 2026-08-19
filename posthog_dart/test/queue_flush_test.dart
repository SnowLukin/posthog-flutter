import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:posthog_dart/posthog_dart.dart';
import 'package:test/test.dart';

import 'posthog_core_fake.dart';

void main() {
  group('PostHogCore.flush', () {
    test('sends queued events in one batch and empties the queue', () async {
      final storage = InMemoryStorage();
      final client =
          PostHogCoreFake('k', options: testOptions(), storage: storage);
      addTearDown(client.shutdown);

      client.capture('sign_in');
      client.capture('sign_out');
      await client.flush();

      expect(client.fetchCalls.single.url, 'https://us.i.posthog.com/batch/');
      expect(_batchEvents(client.fetchCalls.single.options),
          ['sign_in', 'sign_out']);
      expect(getQueue(storage), isEmpty);
    });

    test('removes sent events by identity when the queue head shifts',
        () async {
      final storage = InMemoryStorage();
      final client = PostHogCoreFake('k',
          options: testOptions(flushAt: 2, maxBatchSize: 2, maxQueueSize: 2),
          storage: storage);
      addTearDown(client.shutdown);

      final inFlight = Completer<void>();
      final release = Completer<void>();
      client.fetchHandler = (url, options) async {
        if (!inFlight.isCompleted) {
          inFlight.complete();
          await release.future;
        }
        return _ok;
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
        client.fetchCalls.map((call) => _batchEvents(call.options)).toList(),
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
      final storage = InMemoryStorage();
      final client =
          PostHogCoreFake('k', options: testOptions(), storage: storage);
      addTearDown(client.shutdown);
      client.fetchHandler = (url, options) {
        // This server rejects anything bigger than two events per request.
        if (_batchEvents(options).length > 2) {
          return const PostHogFetchResponse(status: 413, body: 'too large');
        }
        return _ok;
      };

      for (var i = 0; i < 8; i++) {
        client.capture('event_$i');
      }
      await client.flush();

      final batches =
          client.fetchCalls.map((call) => _batchEvents(call.options)).toList();
      expect(batches.map((batch) => batch.length).toList(), [8, 4, 2, 2, 2, 2]);
      expect(batches.skip(2).expand((batch) => batch).toList(),
          [for (var i = 0; i < 8; i++) 'event_$i']);
      expect(getQueue(storage), isEmpty);
    });

    test('shares one network cycle between concurrent calls', () async {
      final storage = InMemoryStorage();
      final client =
          PostHogCoreFake('k', options: testOptions(), storage: storage);
      addTearDown(client.shutdown);
      final release = Completer<void>();
      client.fetchHandler = (url, options) async {
        await release.future;
        return _ok;
      };

      client.capture('evt');
      final first = client.flush();
      final second = client.flush();
      expect(second, same(first));

      release.complete();
      await first;

      expect(client.fetchCalls, hasLength(1));
      expect(getQueue(storage), isEmpty);
    });

    for (final statusCode in [408, 429, 500]) {
      test('transient HTTP $statusCode is retried and keeps the batch queued',
          () async {
        final storage = InMemoryStorage();
        final client = PostHogCoreFake('k',
            options: testOptions(fetchRetryCount: 1), storage: storage);
        addTearDown(client.shutdown);
        client.fetchHandler = (url, options) =>
            PostHogFetchResponse(status: statusCode, body: 'try later');

        client.capture('evt');
        await expectLater(
            client.flush(), throwsA(isA<PostHogFetchHttpError>()));

        expect(client.fetchCalls, hasLength(2));
        expect(getQueue(storage), hasLength(1));
      });
    }

    test('hard HTTP 400 is not retried and drops the batch', () async {
      final storage = InMemoryStorage();
      final client = PostHogCoreFake('k',
          options: testOptions(fetchRetryCount: 2), storage: storage);
      addTearDown(client.shutdown);
      client.fetchHandler = (url, options) =>
          const PostHogFetchResponse(status: 400, body: 'bad');

      client.capture('evt');
      await expectLater(client.flush(), throwsA(isA<PostHogFetchHttpError>()));

      expect(client.fetchCalls, hasLength(1));
      expect(getQueue(storage), isEmpty);
    });

    test('a failed flush re-arms the periodic timer', () async {
      final storage = InMemoryStorage();
      final client = PostHogCoreFake('k',
          options: testOptions(flushInterval: const Duration(milliseconds: 20)),
          storage: storage);
      addTearDown(client.shutdown);
      var failures = 0;
      client.fetchHandler = (url, options) {
        if (failures < 1) {
          failures++;
          throw PostHogFetchNetworkError(const SocketException('offline'));
        }
        return _ok;
      };
      final flushed = Completer<void>();
      client.on('flush', (_) => flushed.complete());

      client.capture('evt');
      // Only a re-armed timer can produce the second, successful attempt.
      await flushed.future;

      expect(failures, 1);
      expect(client.fetchCalls, hasLength(2));
      expect(getQueue(storage), isEmpty);
    });
  });

  group('Automatic flushing', () {
    test('flushes as soon as the queue reaches flushAt', () async {
      final storage = InMemoryStorage();
      final client = PostHogCoreFake('k',
          options: testOptions(flushAt: 3), storage: storage);
      addTearDown(client.shutdown);
      final flushed = Completer<void>();
      client.on('flush', (_) => flushed.complete());

      client.capture('one');
      client.capture('two');
      // One event-loop turn: enough for an unwanted early flush to reach
      // fetch. Staying quiet here is part of the assertion.
      await Future<void>.delayed(Duration.zero);
      expect(client.fetchCalls, isEmpty);

      client.capture('three');
      await flushed.future;

      expect(_batchEvents(client.fetchCalls.single.options),
          ['one', 'two', 'three']);
      expect(getQueue(storage), isEmpty);
    });

    test('drops the oldest events once the queue exceeds maxQueueSize',
        () async {
      final storage = InMemoryStorage();
      final client = PostHogCoreFake('k',
          options: testOptions(
              flushAt: 1, maxQueueSize: 100, flushInterval: Duration.zero),
          storage: storage);
      addTearDown(client.shutdown);
      // Delivery keeps failing, so every event stays queued and only the
      // overflow rule decides which ones survive.
      client.fetchHandler = (url, options) =>
          const PostHogFetchResponse(status: 503, body: 'unavailable');

      for (var i = 0; i < 102; i++) {
        client.capture('event_$i');
      }
      await expectLater(client.flush(), throwsA(isA<PostHogFetchHttpError>()));

      final queuedEvents = [
        for (final item in getQueue(storage))
          (item['message'] as Map<String, Object?>)['event'],
      ];
      expect(queuedEvents, [for (var i = 2; i <= 101; i++) 'event_$i']);
    });
  });

  group('Queue persistence', () {
    test('flushes events captured by a previous process from FileStorage',
        () async {
      final dir = Directory.systemTemp.createTempSync('posthog_queue_restart');
      addTearDown(() => dir.deleteSync(recursive: true));

      final before = PostHogCoreFake('k',
          options: testOptions(), storage: FileStorage(dir.path));
      addTearDown(before.shutdown);
      before.fetchHandler = (url, options) =>
          throw PostHogFetchNetworkError(const SocketException('offline'));
      before.capture('sign_in');
      before.capture('sign_out');

      // A new client over the same directory stands in for a restart.
      final after = PostHogCoreFake('k',
          options: testOptions(), storage: FileStorage(dir.path));
      addTearDown(after.shutdown);
      await after.flush();

      expect(_batchEvents(after.fetchCalls.single.options),
          ['sign_in', 'sign_out']);
      expect(getQueue(FileStorage(dir.path)), isEmpty,
          reason: 'delivered events must also leave the on-disk queue');
    });
  });

  group('PostHogCore.shutdown', () {
    test('delivers queued events and leaves the queue empty', () async {
      final storage = InMemoryStorage();
      final client =
          PostHogCoreFake('k', options: testOptions(), storage: storage);
      addTearDown(client.shutdown);

      client.capture('sign_in');
      client.capture('sign_out');
      await client.shutdown();

      expect(_batchEvents(client.fetchCalls.single.options),
          ['sign_in', 'sign_out']);
      expect(getQueue(storage), isEmpty);
    });

    test('returns after its timeout when the network hangs', () async {
      final storage = InMemoryStorage();
      final client =
          PostHogCoreFake('k', options: testOptions(), storage: storage);
      addTearDown(client.shutdown);
      final release = Completer<void>();
      // Unblock the hanging fetch before the teardown shutdown re-awaits it.
      addTearDown(release.complete);
      client.fetchHandler = (url, options) async {
        await release.future;
        return _ok;
      };

      client.capture('evt');
      await client.shutdown(timeout: const Duration(milliseconds: 20));

      expect(getQueue(storage), hasLength(1),
          reason: 'the batch was never confirmed, so it must stay queued');
    });

    test('a flush that fails after shutdown does not re-arm the timer',
        () async {
      final storage = InMemoryStorage();
      final client = PostHogCoreFake('k',
          options: testOptions(flushInterval: const Duration(milliseconds: 40)),
          storage: storage);
      addTearDown(client.shutdown);
      final release = Completer<void>();
      var firstCall = true;
      client.fetchHandler = (url, options) async {
        if (firstCall) {
          firstCall = false;
          await release.future;
        }
        return const PostHogFetchResponse(status: 503, body: 'unavailable');
      };

      client.capture('evt');
      final pendingFlush = client.flush();
      await client.shutdown(timeout: const Duration(milliseconds: 20));

      // Only now does the hung flush fail - after shutdown has already
      // cancelled the timer for the last time.
      release.complete();
      await expectLater(pendingFlush, throwsA(isA<PostHogFetchHttpError>()));
      expect(client.fetchCalls, hasLength(1));

      // Real wait spanning several timer periods: staying quiet is the point.
      await Future<void>.delayed(const Duration(milliseconds: 160));

      expect(client.fetchCalls, hasLength(1),
          reason: 'a re-armed timer would retry forever against a client '
              'whose resources are already released');
    });

    test('is safe to call twice', () async {
      final storage = InMemoryStorage();
      final client =
          PostHogCoreFake('k', options: testOptions(), storage: storage);
      addTearDown(client.shutdown);

      client.capture('evt');
      await client.shutdown();
      await client.shutdown();

      expect(client.fetchCalls, hasLength(1));
      expect(getQueue(storage), isEmpty);
    });
  });

  group('PostHog', () {
    test('posts gzip-compressed batches a real server can decode', () async {
      final server = await _BatchServer.start();
      addTearDown(server.close);
      final posthog = PostHog('k', options: _serverOptions(server.url));
      addTearDown(posthog.shutdown);

      posthog.capture('desktop_event', properties: {'source': 'test'});
      await posthog.flush();

      expect(server.contentEncodings, ['gzip']);
      final body = server.batchBodies.single;
      expect(body['api_key'], 'k');
      final batch = body['batch'] as List<Object?>;
      expect([for (final message in batch) (message as Map)['event']],
          ['desktop_event']);
    });

    test('shutdown closes the HTTP client it owns', () async {
      final server = await _BatchServer.start();
      addTearDown(server.close);
      final posthog = PostHog('k', options: _serverOptions(server.url));
      addTearDown(posthog.shutdown);

      await posthog.shutdown();

      posthog.capture('late_event');
      await expectLater(
          posthog.flush(), throwsA(isA<PostHogFetchNetworkError>()));
      expect(server.batchBodies, isEmpty);
    });
  });
}

const _ok = PostHogFetchResponse(status: 200, body: '{"status": "ok"}');

PostHogConfig _serverOptions(String host) => PostHogConfig(
      host: host,
      flushAt: 100,
      preloadFeatureFlags: false,
      fetchRetryCount: 0,
      fetchRetryDelay: Duration.zero,
    );

List<Object?> _batchEvents(PostHogFetchOptions options) {
  final body = jsonDecode(options.body!) as Map<String, Object?>;
  final batch = body['batch'] as List<Object?>;
  return [for (final message in batch) (message as Map)['event']];
}

class _BatchServer {
  _BatchServer._(this._server);

  final HttpServer _server;
  final List<Map<String, Object?>> batchBodies = [];
  final List<String?> contentEncodings = [];

  String get url => 'http://127.0.0.1:${_server.port}';

  static Future<_BatchServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final batchServer = _BatchServer._(server);
    unawaited(batchServer._serve());
    return batchServer;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _serve() async {
    await for (final request in _server) {
      final bytes = <int>[];
      await request.forEach(bytes.addAll);
      if (request.method == 'POST' && request.uri.path == '/batch/') {
        contentEncodings.add(request.headers.value('content-encoding'));
        batchBodies.add(jsonDecode(utf8.decode(gzip.decode(bytes)))
            as Map<String, Object?>);
        request.response.statusCode = HttpStatus.ok;
        request.response.write('{"status": 1}');
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    }
  }
}
