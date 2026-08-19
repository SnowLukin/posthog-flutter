import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:posthog_dart/posthog_dart.dart';
import 'package:test/test.dart';

import 'posthog_core_fake.dart';

void main() {
  group('PostHogCore.reloadFeatureFlagsAsync', () {
    test('sends non-string person properties to /flags/', () async {
      final client = PostHogCoreFake('k', options: testOptions());
      addTearDown(client.shutdown);

      client.setPersonProperties(
        userPropertiesToSet: {'age': 30, 'beta': true, 'plan': 'pro'},
      );
      await client.reloadFeatureFlagsAsync();

      expect(_flagsRequestBody(client)['person_properties'],
          {'age': 30, 'beta': true, 'plan': 'pro'});
    });

    test('group properties keep their JSON types in the /flags request',
        () async {
      final client = PostHogCoreFake('k', options: testOptions());
      addTearDown(client.shutdown);

      client.setGroupPropertiesForFlags({
        'company': {'beta': true, 'seats': 50, 'tier': 'scale'},
      });
      await client.reloadFeatureFlagsAsync();

      expect(_flagsRequestBody(client)['group_properties'], {
        'company': {'beta': true, 'seats': 50, 'tier': 'scale'},
      });
    });

    test('an empty response clears stale flags and the recorded error',
        () async {
      final storage = InMemoryStorage();
      final client =
          PostHogCoreFake('k', options: testOptions(), storage: storage);
      addTearDown(client.shutdown);

      client.fetchHandler =
          (url, options) => _flagsResponse({'stale-flag': _flag('stale-flag')});
      await client.reloadFeatureFlagsAsync();
      expect(client.getFeatureFlag('stale-flag'), isTrue);

      client.fetchHandler = (url, options) =>
          const PostHogFetchResponse(status: 500, body: 'oops');
      expect(await client.reloadFeatureFlagsAsync(), isNull);
      expect(client.getFeatureFlag('stale-flag'), isTrue,
          reason: 'a failed refresh keeps serving the cached flags');
      expect(_storedFlagDetails(storage)['requestError'], isNotNull);

      client.fetchHandler = (url, options) => _flagsResponse({});
      final emitted = <Map<String, PostHogFeatureFlagValue>>[];
      client.onFeatureFlags(emitted.add);
      final flags = await client.reloadFeatureFlagsAsync();

      expect(flags, isEmpty);
      expect(client.getFeatureFlag('stale-flag'), isNull,
          reason: 'an empty success is an answer, not a failure: '
              'stale flags must not survive it');
      expect(emitted, [isEmpty]);
      expect(_storedFlagDetails(storage).containsKey('requestError'), isFalse);
    });

    test('a malformed flag in the response is skipped, its neighbours stay',
        () async {
      final client = PostHogCoreFake('k', options: testOptions());
      addTearDown(client.shutdown);
      client.fetchHandler = (url, options) => _flagsResponse({
            'good-flag': _flag('good-flag'),
            'bad-flag': {'enabled': 'yes'},
          });

      await client.reloadFeatureFlagsAsync();

      expect(client.getFeatureFlag('good-flag'), isTrue);
      expect(client.getFeatureFlag('bad-flag'), isNull);
    });

    test('pipeline errors do not become unhandled async errors', () async {
      final unhandled = <Object>[];
      await runZonedGuarded(() async {
        final client = PostHogCoreFake(
          'k',
          options: testOptions(),
          storage: _ThrowingStorage(),
        );
        addTearDown(client.shutdown);
        try {
          await client.reloadFeatureFlagsAsync();
        } catch (_) {
          // The direct caller handles the rethrown error; nothing should
          // leak through the shared flags future.
        }
        // Negative wait: give a stray async error a beat to reach the zone
        // handler before asserting none did.
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }, (error, _) => unhandled.add(error));

      expect(unhandled, isEmpty);
    });
  });

  group('Feature flag reads', () {
    test('a missing key reads as null through every accessor', () async {
      final client = PostHogCoreFake('k', options: testOptions());
      addTearDown(client.shutdown);
      client.fetchHandler = (url, options) =>
          _flagsResponse({'existing-flag': _flag('existing-flag')});
      await client.reloadFeatureFlagsAsync();

      expect(client.isFeatureEnabled('existing-flag'), isTrue);
      expect(client.getFeatureFlag('missing'), isNull);
      expect(client.getFeatureFlagResult('missing'), isNull);
      expect(client.isFeatureEnabled('missing'), isNull);
    });

    test('payloads accompany only enabled flags', () async {
      final client = PostHogCoreFake('k', options: testOptions());
      addTearDown(client.shutdown);
      client.fetchHandler = (url, options) => _flagsResponse({
            'paid-flag': _flag('paid-flag', payload: '{"tier":"gold"}'),
            'off-flag': _flag('off-flag', enabled: false, payload: '"nope"'),
          });
      await client.reloadFeatureFlagsAsync();

      expect(
          client.getFeatureFlagResult('paid-flag')?.payload, {'tier': 'gold'});
      final offResult = client.getFeatureFlagResult('off-flag');
      expect(offResult?.enabled, isFalse);
      expect(offResult?.payload, isNull);
      expect(client.getFeatureFlagDetails()?.featureFlagPayloads, {
        'paid-flag': {'tier': 'gold'},
      });
    });

    test('malformed persisted flag details are discarded, not thrown', () {
      final storage = InMemoryStorage();
      // Valid JSON, unexpected shape - e.g. written by another SDK version
      // sharing the same store.
      storage.setProperty(PostHogPersistedProperty.featureFlagDetails,
          <String, Object?>{'flags': 'garbage'});

      final client =
          PostHogCoreFake('k', options: testOptions(), storage: storage);
      addTearDown(client.shutdown);

      expect(() => client.capture('evt'), returnsNormally);
      expect(getQueue(storage), hasLength(1));
      expect(client.getFeatureFlag('missing'), isNull);
      expect(
          storage.getProperty<Map<String, Object?>>(
              PostHogPersistedProperty.featureFlagDetails),
          isNull);
    });
  });

  group('Quota limiting', () {
    test('keeps serving cached flags through every channel', () async {
      final client = PostHogCoreFake('k', options: testOptions());
      addTearDown(client.shutdown);
      client.fetchHandler = (url, options) =>
          _flagsResponse({'cached-flag': _flag('cached-flag')});
      await client.reloadFeatureFlagsAsync();

      client.fetchHandler =
          (url, options) => _flagsResponse({}, quotaLimited: ['feature_flags']);
      final emitted = <Map<String, PostHogFeatureFlagValue>>[];
      client.onFeatureFlags(emitted.add);
      final reloaded = await client.reloadFeatureFlagsAsync();

      expect(reloaded, {'cached-flag': true},
          reason: 'cached flags keep serving under quota (matching the '
              'mobile SDKs), so every channel must report the cached state');
      expect(client.getFeatureFlag('cached-flag'), isTrue);
      expect(emitted, [
        {'cached-flag': true},
      ]);
    });
  });

  group('Person properties for flags', () {
    test('default person properties are sent with the /flags/ request',
        () async {
      final client = _DefaultPersonPropertiesFake('k', options: testOptions());
      addTearDown(client.shutdown);

      await client.reloadFeatureFlagsAsync();

      expect(_flagsRequestBody(client)['person_properties'],
          {r'$app_version': '9.9.9', r'$os_name': 'TestOS'});
    });

    test('explicitly set person properties override the defaults', () async {
      final client = _DefaultPersonPropertiesFake('k', options: testOptions());
      addTearDown(client.shutdown);

      client.setPersonPropertiesForFlags({r'$os_name': 'ManualOS'},
          reloadFlags: false);
      await client.reloadFeatureFlagsAsync();

      expect(_flagsRequestBody(client)['person_properties'],
          {r'$app_version': '9.9.9', r'$os_name': 'ManualOS'});
    });

    test('setDefaultPersonProperties: false omits the defaults', () async {
      final client = _DefaultPersonPropertiesFake('k',
          options: testOptions(setDefaultPersonProperties: false));
      addTearDown(client.shutdown);

      await client.reloadFeatureFlagsAsync();

      expect(_flagsRequestBody(client)['person_properties'], isEmpty);
    });

    test('identify user properties feed the next /flags/ request', () async {
      final client = PostHogCoreFake('k', options: testOptions());
      addTearDown(client.shutdown);
      final flagsBody = Completer<Map<String, Object?>>();
      client.fetchHandler = (url, options) {
        if (url.contains('/flags') && !flagsBody.isCompleted) {
          flagsBody.complete(jsonDecode(options.body!) as Map<String, Object?>);
        }
        return _flagsResponse({});
      };

      client.identify('user-1', properties: {
        r'$set': {'plan': 'pro'},
        r'$set_once': {'plan': 'trial', 'signup_source': 'ads'},
      });

      final body = await flagsBody.future;
      expect(body['person_properties'], {'plan': 'pro', 'signup_source': 'ads'},
          reason: r'$set wins over $set_once for the same key');
    });
  });

  group('PostHog feature flag preloading', () {
    test('the constructor requests /flags/ once when preloading is on',
        () async {
      final server = await _FlagsServer.start();
      addTearDown(server.close);
      final posthog = PostHog('k',
          options: _serverOptions(server.url, preloadFeatureFlags: true));
      addTearDown(posthog.shutdown);
      final loaded = Completer<Map<String, PostHogFeatureFlagValue>>();
      posthog.onFeatureFlags(loaded.complete);

      expect(await loaded.future, {'preloaded-flag': true});
      expect(server.flagsRequestCount, 1);
    });

    test('no /flags/ request is made when preloading is off', () async {
      final server = await _FlagsServer.start();
      addTearDown(server.close);
      final posthog = PostHog('k',
          options: _serverOptions(server.url, preloadFeatureFlags: false));
      addTearDown(posthog.shutdown);

      // Real wait: an unwanted preload request needs time to arrive, and
      // staying quiet is the assertion.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(server.flagsRequestCount, 0);
    });
  });
}

Map<String, Object?> _flag(
  String key, {
  bool enabled = true,
  String? payload,
}) =>
    {
      'key': key,
      'enabled': enabled,
      if (payload != null) 'metadata': {'payload': payload},
    };

PostHogFetchResponse _flagsResponse(
  Map<String, Object?> flags, {
  List<String>? quotaLimited,
}) =>
    PostHogFetchResponse(
      status: 200,
      body: jsonEncode({
        'flags': flags,
        if (quotaLimited != null) 'quotaLimited': quotaLimited,
      }),
    );

Map<String, Object?> _flagsRequestBody(PostHogCoreFake client) {
  final call =
      client.fetchCalls.lastWhere((call) => call.url.contains('/flags'));
  return jsonDecode(call.options.body!) as Map<String, Object?>;
}

Map<String, Object?> _storedFlagDetails(PostHogStorage storage) =>
    storage.getProperty<Map<String, Object?>>(
        PostHogPersistedProperty.featureFlagDetails) ??
    {};

PostHogConfig _serverOptions(String host,
        {required bool preloadFeatureFlags}) =>
    PostHogConfig(
      host: host,
      flushAt: 100,
      preloadFeatureFlags: preloadFeatureFlags,
      fetchRetryCount: 0,
      fetchRetryDelay: Duration.zero,
    );

class _DefaultPersonPropertiesFake extends PostHogCoreFake {
  _DefaultPersonPropertiesFake(super.apiKey, {super.options});

  @override
  Map<String, Object?> getDefaultPersonPropertiesForFlags() =>
      {r'$app_version': '9.9.9', r'$os_name': 'TestOS'};
}

class _ThrowingStorage extends InMemoryStorage {
  @override
  T? getProperty<T>(PostHogPersistedProperty key) {
    if (key == PostHogPersistedProperty.distinctId) {
      throw StateError('storage failure');
    }
    return super.getProperty(key);
  }
}

class _FlagsServer {
  _FlagsServer._(this._server);

  final HttpServer _server;
  int flagsRequestCount = 0;

  String get url => 'http://127.0.0.1:${_server.port}';

  static Future<_FlagsServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final flagsServer = _FlagsServer._(server);
    unawaited(flagsServer._serve());
    return flagsServer;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _serve() async {
    await for (final request in _server) {
      await request.drain<void>();
      if (request.method == 'POST' && request.uri.path == '/flags/') {
        flagsRequestCount++;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'flags': {
            'preloaded-flag': {'key': 'preloaded-flag', 'enabled': true},
          },
        }));
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    }
  }
}
