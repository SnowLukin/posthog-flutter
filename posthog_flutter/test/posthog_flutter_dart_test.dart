import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:posthog_flutter/posthog_flutter_dart.dart';
import 'package:posthog_flutter/src/posthog_config.dart';
import 'package:posthog_flutter/src/posthog_flutter_platform_interface.dart';
import 'package:posthog_flutter/src/posthog_flutter_version.dart';

import 'posthog_flutter_platform_interface_fake.dart';

// No TestWidgetsFlutterBinding here: the test binding replaces dart:io's
// HttpClient with a stub that answers 400 to everything, and these tests
// exercise the real HTTP path against a local server.
void main() {
  Future<_PostHogServer> startServer() async {
    final server = await _PostHogServer.start();
    addTearDown(server.close);
    return server;
  }

  Directory createStorageDir() {
    final dir = Directory.systemTemp.createTempSync('posthog_flutter_dart');
    addTearDown(() => dir.deleteSync(recursive: true));
    return dir;
  }

  PostHogConfig configFor(
    _PostHogServer server,
    Directory storageDir, {
    String projectToken = 'test_project_token',
  }) {
    return PostHogConfig(projectToken)
      ..host = server.url
      ..flushAt = 1
      ..desktopConfig.storageDirectory = storageDir.path;
  }

  Future<PosthogFlutterDart> setUpPlatform(PostHogConfig config) async {
    final platform = PosthogFlutterDart();
    addTearDown(platform.close);
    await platform.setup(config);
    return platform;
  }

  group('PosthogFlutterDart.registerWith', () {
    test('installs PosthogFlutterDart as the platform instance', () {
      // Seed a known instance first: reading the uninitialized default would
      // construct the method-channel implementation, which needs a Flutter
      // binding these network tests never initialize.
      final previous = PosthogFlutterPlatformFake();
      PosthogFlutterPlatformInterface.instance = previous;
      addTearDown(() => PosthogFlutterPlatformInterface.instance = previous);

      PosthogFlutterDart.registerWith();

      expect(
        PosthogFlutterPlatformInterface.instance,
        isA<PosthogFlutterDart>(),
      );
    });
  });

  group('PosthogFlutterDart before setup', () {
    late PosthogFlutterDart platform;

    setUp(() {
      platform = PosthogFlutterDart();
    });

    final callsByName = <String, Future<void> Function(PosthogFlutterDart)>{
      'capture': (platform) => platform.capture(eventName: 'event'),
      'screen': (platform) => platform.screen(screenName: 'Home'),
      'identify': (platform) => platform.identify(userId: 'user-1'),
      'group': (platform) =>
          platform.group(groupType: 'company', groupKey: 'acme'),
      'alias': (platform) => platform.alias(alias: 'other-user'),
      'flush': (platform) => platform.flush(),
      'reset': (platform) => platform.reset(),
      'close': (platform) => platform.close(),
    };

    for (final entry in callsByName.entries) {
      test('${entry.key} completes without a client', () async {
        await expectLater(entry.value(platform), completes);
      });
    }

    final nullReadsByName =
        <String, Future<Object?> Function(PosthogFlutterDart)>{
      'getFeatureFlag': (platform) => platform.getFeatureFlag(key: 'flag'),
      'getFeatureFlagPayload': (platform) =>
          platform.getFeatureFlagPayload(key: 'flag'),
      'getFeatureFlagResult': (platform) =>
          platform.getFeatureFlagResult(key: 'flag'),
      'getSessionId': (platform) => platform.getSessionId(),
    };

    for (final entry in nullReadsByName.entries) {
      test('${entry.key} returns null', () async {
        expect(await entry.value(platform), isNull);
      });
    }

    test('getDistinctId returns an empty string', () async {
      expect(await platform.getDistinctId(), '');
    });

    test('isFeatureEnabled returns false', () async {
      expect(await platform.isFeatureEnabled('flag'), isFalse);
    });

    test('isOptOut reports the config default', () async {
      expect(await platform.isOptOut(), isFalse);
    });
  });

  group('PosthogFlutterDart.capture', () {
    test('delivers the event with properties and person properties', () async {
      final server = await startServer();
      final platform =
          await setUpPlatform(configFor(server, createStorageDir()));

      await platform.capture(
        eventName: 'purchase completed',
        properties: {'plan': 'pro'},
        userProperties: {'name': 'Max'},
        userPropertiesSetOnce: {'signup_channel': 'organic'},
      );

      final event = await server.waitForEvent('purchase completed');
      final properties = _propertiesOf(event);
      expect(properties['plan'], 'pro');
      expect(properties[r'$set'], {'name': 'Max'});
      expect(properties[r'$set_once'], {'signup_channel': 'organic'});
    });

    test(r'merges a legacy $set in properties, explicit keys winning',
        () async {
      final server = await startServer();
      final platform =
          await setUpPlatform(configFor(server, createStorageDir()));

      await platform.capture(
        eventName: 'legacy merge',
        properties: {
          r'$set': {'plan': 'legacy', 'team': 'core'},
        },
        userProperties: {'plan': 'pro'},
      );

      final event = await server.waitForEvent('legacy merge');
      expect(_propertiesOf(event)[r'$set'], {'plan': 'pro', 'team': 'core'});
    });
  });

  group('PosthogFlutterDart.screen', () {
    test(r'delivers $screen with the screen name property', () async {
      final server = await startServer();
      final platform =
          await setUpPlatform(configFor(server, createStorageDir()));

      await platform.screen(
        screenName: 'Home Screen',
        properties: {'tab': 'primary'},
      );

      final event = await server.waitForEvent(r'$screen');
      final properties = _propertiesOf(event);
      expect(properties[r'$screen_name'], 'Home Screen');
      expect(properties['tab'], 'primary');
    });

    test('keeps the screen name when a callback rebuilds the properties',
        () async {
      final server = await startServer();
      final config = configFor(server, createStorageDir())
        ..beforeSend = [
          (event) {
            event.properties = {'scrubbed': true};
            return event;
          },
        ];
      final platform = await setUpPlatform(config);

      await platform.screen(screenName: 'Home Screen');

      final event = await server.waitForEvent(r'$screen');
      final properties = _propertiesOf(event);
      expect(properties[r'$screen_name'], 'Home Screen',
          reason: 'the io path re-sends the screen name out of band, so a '
              'callback dropping the key must not lose it');
      expect(properties['scrubbed'], isTrue);
    });
  });

  group('beforeSend hook', () {
    test('dropping an event keeps it off the wire', () async {
      final server = await startServer();
      final config = configFor(server, createStorageDir())
        ..beforeSend = [
          (event) => event.event == 'dropped event' ? null : event,
        ];
      final platform = await setUpPlatform(config);

      await platform.capture(eventName: 'dropped event');
      await platform.capture(eventName: 'sentinel event');

      // Events are delivered in capture order, so once the sentinel arrived
      // the dropped event can no longer be in flight.
      await server.waitForEvent('sentinel event');
      expect(server.eventNames, isNot(contains('dropped event')));
    });

    test('modifications made by a callback are delivered', () async {
      final server = await startServer();
      final config = configFor(server, createStorageDir())
        ..beforeSend = [
          (event) {
            event.event = 'renamed event';
            event.properties = {...?event.properties, 'amended': true};
            return event;
          },
        ];
      final platform = await setUpPlatform(config);

      await platform.capture(
        eventName: 'original event',
        properties: {'plan': 'pro'},
      );

      final event = await server.waitForEvent('renamed event');
      final properties = _propertiesOf(event);
      expect(properties['plan'], 'pro');
      expect(properties['amended'], isTrue);
      expect(server.eventNames, isNot(contains('original event')));
    });

    test('a throwing callback is skipped and the chain continues', () async {
      final server = await startServer();
      final config = configFor(server, createStorageDir())
        ..beforeSend = [
          (event) => throw StateError('broken callback'),
          (event) {
            event.properties = {...?event.properties, 'second_ran': true};
            return event;
          },
        ];
      final platform = await setUpPlatform(config);

      await platform.capture(eventName: 'resilient event');

      final event = await server.waitForEvent('resilient event');
      expect(_propertiesOf(event)['second_ran'], isTrue);
    });

    test('callbacks see user-provided properties only', () async {
      final server = await startServer();
      Map<String, Object>? seenProperties;
      final config = configFor(server, createStorageDir())
        ..beforeSend = [
          (event) {
            seenProperties = event.properties;
            return event;
          },
        ];
      final platform = await setUpPlatform(config);

      await platform.capture(
        eventName: 'context event',
        properties: {'plan': 'pro'},
      );

      final event = await server.waitForEvent('context event');
      // The whole map: no $session_id, $lib or other SDK enrichment is
      // visible to the hook...
      expect(seenProperties, {'plan': 'pro'});
      // ...while the delivered event is still enriched after the hook ran.
      final properties = _propertiesOf(event);
      expect(properties, containsPair(r'$lib', 'posthog-flutter'));
      expect(properties.keys, contains(r'$session_id'));
    });

    test('SDK-internal events bypass the callbacks', () async {
      final server = await startServer();
      server.flagsResponse = _variantFlagResponse();
      final flagsLoaded = Completer<void>();
      final seenEventNames = <String>[];
      final config = configFor(server, createStorageDir())
        ..onFeatureFlags = () {
          if (!flagsLoaded.isCompleted) flagsLoaded.complete();
        }
        ..beforeSend = [
          (event) {
            seenEventNames.add(event.event);
            return event;
          },
        ];
      final platform = await setUpPlatform(config);
      await flagsLoaded.future;

      await platform.getFeatureFlagResult(key: 'variant-flag');
      await platform.capture(eventName: 'user event');

      await server.waitForEvent(r'$feature_flag_called');
      await server.waitForEvent('user event');
      // Both events reached the wire, but only the user-initiated capture
      // passed through the hook.
      expect(seenEventNames, ['user event']);
    });
  });

  group('PosthogFlutterDart.captureException', () {
    test(r'delivers $exception with a processed exception list', () async {
      final server = await startServer();
      final platform =
          await setUpPlatform(configFor(server, createStorageDir()));

      late Object error;
      late StackTrace stackTrace;
      try {
        throw StateError('desktop failure');
      } catch (e, s) {
        error = e;
        stackTrace = s;
      }
      await platform.captureException(error: error, stackTrace: stackTrace);

      final event = await server.waitForEvent(r'$exception');
      final properties = _propertiesOf(event);
      expect(properties[r'$exception_level'], 'error');

      final exceptionList = properties[r'$exception_list']! as List;
      final exception = Map<String, Object?>.from(exceptionList.first as Map);
      expect(exception['type'], 'StateError');
      expect(exception['value'], 'Bad state: desktop failure');

      final stacktrace =
          Map<String, Object?>.from(exception['stacktrace']! as Map);
      expect(stacktrace['frames'], isNotEmpty);
    });
  });

  group('Storage scoping', () {
    test('setups with different tokens use distinct state directories',
        () async {
      final server = await startServer();
      final storageDir = createStorageDir();

      Future<void> runWithToken(String projectToken) async {
        final platform = PosthogFlutterDart();
        await platform.setup(
          configFor(server, storageDir, projectToken: projectToken),
        );
        // The first read persists the generated anonymous id, creating the
        // state file for this token's scope.
        await platform.getDistinctId();
        await platform.close();
      }

      await runWithToken('token_one');
      await runWithToken('token_two');

      final sep = Platform.pathSeparator;
      expect(
        File('${storageDir.path}${sep}token_one${sep}posthog_data.json')
            .existsSync(),
        isTrue,
      );
      expect(
        File('${storageDir.path}${sep}token_two${sep}posthog_data.json')
            .existsSync(),
        isTrue,
      );
    });

    test('appNamespace scopes the default state directory per app', () async {
      final server = await startServer();
      final sep = Platform.pathSeparator;
      final root = '${_defaultStorageRoot()}${sep}posthog';
      final namespacePrefix = 'posthog_flutter_dart_test_$pid';
      addTearDown(() {
        final rootDir = Directory(root);
        if (!rootDir.existsSync()) return;
        for (final entry in rootDir.listSync()) {
          if (entry.path.split(sep).last.startsWith(namespacePrefix)) {
            entry.deleteSync(recursive: true);
          }
        }
      });

      Future<void> runWithNamespace(String namespace) async {
        final config = PostHogConfig('test_project_token')
          ..host = server.url
          ..preloadFeatureFlags = false
          ..desktopConfig.appNamespace = namespace;
        final platform = PosthogFlutterDart();
        await platform.setup(config);
        await platform.getDistinctId();
        await platform.close();
      }

      await runWithNamespace('${namespacePrefix}_one');
      await runWithNamespace('${namespacePrefix}_two');

      // The default root comes from the process environment, which a test
      // cannot redirect, so the assert goes against the real application
      // data root; the unique namespace keeps this run isolated and the
      // teardown removes it.
      String stateFile(String namespace) =>
          '$root$sep$namespace${sep}test_project_token${sep}posthog_data.json';
      expect(File(stateFile('${namespacePrefix}_one')).existsSync(), isTrue);
      expect(File(stateFile('${namespacePrefix}_two')).existsSync(), isTrue);
    });
  });

  group('PosthogFlutterDart.setup', () {
    test('a repeated setup drains the previous client exactly once', () async {
      final server = await startServer();
      final storageDir = createStorageDir();
      final platform = PosthogFlutterDart();
      addTearDown(platform.close);

      final firstConfig = configFor(server, storageDir)
        ..flushAt = 20
        ..flushInterval = const Duration(milliseconds: 300);
      await platform.setup(firstConfig);
      await platform.capture(eventName: 'first client event');

      // The second setup shuts the first client down, which flushes the
      // still-queued event.
      await platform.setup(configFor(server, storageDir));
      await server.waitForEvent('first client event');

      await platform.capture(eventName: 'second client event');
      await server.waitForEvent('second client event');

      final settledRequestCount = server.batchRequestCount;
      // Twice the first client's flush interval: a flush timer leaked past
      // the second setup would have fired within this window and posted the
      // first client's copy of the queue again.
      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(server.batchRequestCount, settledRequestCount);
      expect(
        server.eventNames.where((name) => name == 'first client event'),
        hasLength(1),
      );
    });
  });

  group('Feature flag evaluation', () {
    test('flags requests carry default person properties', () async {
      final server = await startServer();
      final platform =
          await setUpPlatform(configFor(server, createStorageDir()));

      final preload = await server.waitForFlagsRequest(0);
      final personProperties =
          Map<String, Object?>.from(preload['person_properties']! as Map);
      expect(personProperties[r'$device_type'], 'Desktop');
      expect(personProperties[r'$os_name'], isNotNull);
      expect(personProperties[r'$lib'], 'posthog-flutter');
      expect(personProperties[r'$lib_version'], postHogFlutterVersion);

      await platform.setPersonPropertiesForFlags({r'$os_name': 'Custom OS'});
      await platform.reloadFeatureFlags();

      final reload = await server.waitForFlagsRequest(1);
      final overridden =
          Map<String, Object?>.from(reload['person_properties']! as Map);
      expect(overridden[r'$os_name'], 'Custom OS');
      expect(overridden[r'$device_type'], 'Desktop');
    });

    test(r'getFeatureFlagPayload does not capture $feature_flag_called',
        () async {
      final server = await startServer();
      server.flagsResponse = _variantFlagResponse();
      final flagsLoaded = Completer<void>();
      final config = configFor(server, createStorageDir())
        ..onFeatureFlags = () {
          if (!flagsLoaded.isCompleted) flagsLoaded.complete();
        };
      final platform = await setUpPlatform(config);
      await flagsLoaded.future;

      final payload = await platform.getFeatureFlagPayload(
        key: 'variant-flag',
      );
      expect(payload, {'color': 'blue'});

      await platform.capture(eventName: 'sentinel event');
      await server.waitForEvent('sentinel event');
      expect(server.eventNames, isNot(contains(r'$feature_flag_called')));

      // The default evaluation path still reports the call.
      final result = await platform.getFeatureFlagResult(key: 'variant-flag');
      expect(result?.variant, 'test-variant');
      final called = await server.waitForEvent(r'$feature_flag_called');
      expect(_propertiesOf(called)[r'$feature_flag'], 'variant-flag');
    });
  });
}

Map<String, Object?> _propertiesOf(Map<String, Object?> event) =>
    Map<String, Object?>.from(event['properties']! as Map);

/// A /flags/ v2 response with one multivariate flag carrying a payload.
Map<String, Object?> _variantFlagResponse() => {
      'flags': {
        'variant-flag': {
          'key': 'variant-flag',
          'enabled': true,
          'variant': 'test-variant',
          'metadata': {
            'id': 1,
            'version': 2,
            'payload': '{"color":"blue"}',
          },
        },
      },
    };

/// The application data root the desktop implementation resolves when no
/// storageDirectory override is set: %APPDATA% on Windows, $XDG_DATA_HOME or
/// ~/.local/share elsewhere, the system temp directory as a last resort.
String _defaultStorageRoot() {
  final env = Platform.environment;
  if (Platform.isWindows) {
    return env['APPDATA'] ?? env['LOCALAPPDATA'] ?? Directory.systemTemp.path;
  }
  final xdgDataHome = env['XDG_DATA_HOME'];
  if (xdgDataHome != null && xdgDataHome.isNotEmpty) return xdgDataHome;
  final home = env['HOME'];
  if (home != null && home.isNotEmpty) return '$home/.local/share';
  return Directory.systemTemp.path;
}

/// Local stand-in for the PostHog ingestion API: answers /flags/ with a
/// canned response and records every decoded /flags/ body and /batch/ event.
class _PostHogServer {
  _PostHogServer._(this._server);

  final HttpServer _server;

  /// Every event posted to /batch/, in arrival order.
  final events = <Map<String, Object?>>[];

  /// Decoded /flags/ request bodies, in arrival order.
  final flagsRequests = <Map<String, Object?>>[];

  int batchRequestCount = 0;

  /// Response body served to /flags/ requests (v2 format).
  Map<String, Object?> flagsResponse = {'flags': <String, Object?>{}};

  final _waiters = <({bool Function() isReady, Completer<void> done})>[];

  String get url => 'http://127.0.0.1:${_server.port}';

  List<String> get eventNames =>
      [for (final event in events) event['event']! as String];

  static Future<_PostHogServer> start() async {
    final server = _PostHogServer._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    unawaited(server._serve());
    return server;
  }

  Future<void> close() => _server.close(force: true);

  /// Completes once an event named [name] has arrived on /batch/.
  Future<Map<String, Object?>> waitForEvent(String name) async {
    await _waitUntil(() => events.any((event) => event['event'] == name));
    return events.firstWhere((event) => event['event'] == name);
  }

  /// Completes once the /flags/ request at [index] has arrived.
  Future<Map<String, Object?>> waitForFlagsRequest(int index) async {
    await _waitUntil(() => flagsRequests.length > index);
    return flagsRequests[index];
  }

  Future<void> _waitUntil(bool Function() isReady) {
    if (isReady()) return Future.value();
    final done = Completer<void>();
    _waiters.add((isReady: isReady, done: done));
    return done.future;
  }

  void _notifyWaiters() {
    _waiters.removeWhere((waiter) {
      if (!waiter.isReady()) return false;
      waiter.done.complete();
      return true;
    });
  }

  Future<void> _serve() async {
    await for (final request in _server) {
      final bytes = await request.fold<List<int>>(
        [],
        (all, chunk) => all..addAll(chunk),
      );
      // posthog_dart gzips every POST body.
      final body = request.headers.value('content-encoding') == 'gzip'
          ? utf8.decode(gzip.decode(bytes))
          : utf8.decode(bytes);

      if (request.uri.path == '/batch/') {
        batchRequestCount++;
        final decoded = jsonDecode(body) as Map<String, Object?>;
        final batch = decoded['batch']! as List;
        events.addAll(
          batch.map((event) => Map<String, Object?>.from(event as Map)),
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"status": 1}');
      } else if (request.uri.path == '/flags/') {
        flagsRequests.add(
          Map<String, Object?>.from(jsonDecode(body) as Map),
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(flagsResponse));
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
      _notifyWaiters();
    }
  }
}
