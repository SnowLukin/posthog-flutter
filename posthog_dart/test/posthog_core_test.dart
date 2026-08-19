import 'dart:convert';

import 'package:posthog_dart/posthog_dart.dart';
import 'package:test/test.dart';

import 'posthog_core_fake.dart';

void main() {
  group('PostHogCore', () {
    test('rejects an empty api key', () {
      expect(() => PostHogCoreFake('', storage: InMemoryStorage()),
          throwsA(isA<ArgumentError>()));
    });
  });

  group('PostHogCore.capture', () {
    late InMemoryStorage storage;
    late PostHogCoreFake client;

    setUp(() {
      storage = InMemoryStorage();
      client = PostHogCoreFake('k', options: testOptions(), storage: storage);
      addTearDown(client.shutdown);
    });

    test('enqueues the event with its properties and library metadata', () {
      client.capture('test_event', properties: {'key': 'value'});

      expect(getQueue(storage), hasLength(1));
      expect(queuedMessage(storage, 0)['event'], 'test_event');
      final props = queuedProps(storage, 0);
      expect(props['key'], 'value');
      expect(props[r'$lib'], 'posthog-dart-test');
    });
  });

  group('Anonymous and distinct ids', () {
    late InMemoryStorage storage;
    late PostHogCoreFake client;

    setUp(() {
      storage = InMemoryStorage();
      client = PostHogCoreFake('k', options: testOptions(), storage: storage);
      addTearDown(client.shutdown);
    });

    test('generates the anonymous id once and reuses it', () {
      final anonymousId = client.getAnonymousId();

      expect(anonymousId, isNotEmpty);
      expect(client.getAnonymousId(), anonymousId);
    });

    test('falls back to the anonymous id before identify', () {
      expect(client.getDistinctId(), client.getAnonymousId());
    });
  });

  group('PostHogCore.identify', () {
    late InMemoryStorage storage;
    late PostHogCoreFake client;

    setUp(() {
      storage = InMemoryStorage();
      client = PostHogCoreFake('k', options: testOptions(), storage: storage);
      addTearDown(client.shutdown);
    });

    test('switches the distinct id and marks the person identified', () {
      client.identify('user-123');

      expect(client.getDistinctId(), 'user-123');
      expect(storage.getProperty<String>(PostHogPersistedProperty.personMode),
          'identified');
    });

    test('is ignored when personProfiles is never', () {
      final client = PostHogCoreFake('k',
          options: testOptions(personProfiles: PostHogPersonProfiles.never),
          storage: InMemoryStorage());
      addTearDown(client.shutdown);

      client.identify('user-123');

      expect(client.getDistinctId(), isNot('user-123'));
    });

    test(r'keeps null values inside $set as explicit unsets', () {
      client.identify('user-123', properties: {
        r'$set': {'email': null, 'plan': 'pro'},
      });

      final set = queuedProps(storage, 0)[r'$set'] as Map<String, Object?>;
      expect(set, {'email': null, 'plan': 'pro'},
          reason: r'PostHog reads $set: {prop: null} as "unset prop", so '
              'null entries must reach the wire');
    });
  });

  group('PostHogCore.reset', () {
    test('clears identity but keeps the queue', () {
      final storage = InMemoryStorage();
      final client =
          PostHogCoreFake('k', options: testOptions(), storage: storage);
      addTearDown(client.shutdown);
      client.identify('user-123');
      client.capture('test_event');

      client.reset();

      expect(client.getDistinctId(), isNot('user-123'));
      expect(storage.getProperty<String>(PostHogPersistedProperty.personMode),
          isNull);
      expect(getQueue(storage), isNotEmpty,
          reason: 'reset clears identity, not pending events');
    });
  });

  group('PostHogCore.getSessionId', () {
    late PostHogCoreFake client;

    setUp(() {
      client = PostHogCoreFake('k',
          options: testOptions(), storage: InMemoryStorage());
      addTearDown(client.shutdown);
    });

    test('reuses the session id within the expiration window', () {
      final sessionId = client.getSessionId();

      expect(sessionId, isNotEmpty);
      expect(client.getSessionId(), sessionId);
    });

    test('issues a new session id after resetSessionId', () {
      final sessionId = client.getSessionId();

      client.resetSessionId();

      expect(client.getSessionId(), isNot(sessionId));
    });
  });

  group('Super properties', () {
    late InMemoryStorage storage;
    late PostHogCoreFake client;

    setUp(() {
      storage = InMemoryStorage();
      client = PostHogCoreFake('k', options: testOptions(), storage: storage);
      addTearDown(client.shutdown);
    });

    test('registered properties are attached to captured events', () {
      client.register({'app_version': '1.0.0'});

      client.capture('test_event');

      expect(queuedProps(storage, 0)['app_version'], '1.0.0');
    });

    test('unregistered properties stop being attached', () {
      client.register({'app_version': '1.0.0', 'platform': 'web'});

      client.unregister('app_version');
      client.capture('test_event');

      final props = queuedProps(storage, 0);
      expect(props['app_version'], isNull);
      expect(props['platform'], 'web');
    });

    test('reads through to storage without in-core memoization', () {
      client.register({'a': 1});
      client.capture('warmup');

      // An external write to the store must be visible without a restart.
      storage.setProperty(PostHogPersistedProperty.props,
          <String, Object?>{'a': 1, 'external': true});
      client.capture('evt');

      expect(queuedProps(storage, 1)['external'], isTrue);
    });
  });

  group('PostHogCore.setPersonPropertiesForFlags', () {
    test('merges consecutive calls instead of replacing', () {
      final storage = InMemoryStorage();
      final client =
          PostHogCoreFake('k', options: testOptions(), storage: storage);
      addTearDown(client.shutdown);

      client.setPersonPropertiesForFlags({'role': 'admin'}, reloadFlags: false);
      client.setPersonPropertiesForFlags({'plan': 'pro'}, reloadFlags: false);

      expect(
          storage.getProperty<Map<String, Object?>>(
              PostHogPersistedProperty.personProperties),
          {'role': 'admin', 'plan': 'pro'});
    });
  });

  group('PostHogCore.alias', () {
    test(r'captures a $create_alias event carrying the alias', () {
      final storage = InMemoryStorage();
      final client =
          PostHogCoreFake('k', options: testOptions(), storage: storage);
      addTearDown(client.shutdown);

      client.alias('new-alias');

      expect(queuedMessage(storage, 0)['event'], r'$create_alias');
      expect(queuedProps(storage, 0)['alias'], 'new-alias');
    });
  });

  group('PostHogCore.group', () {
    test(r'captures a $groupidentify event with the group properties', () {
      final storage = InMemoryStorage();
      final client =
          PostHogCoreFake('k', options: testOptions(), storage: storage);
      addTearDown(client.shutdown);

      client.group('company', 'company-123', groupProperties: {'name': 'Acme'});

      final groupIdentify = getQueue(storage)
          .map((item) => item['message'] as Map<String, Object?>)
          .singleWhere((message) => message['event'] == r'$groupidentify');
      final props = groupIdentify['properties'] as Map<String, Object?>;
      expect(props[r'$group_type'], 'company');
      expect(props[r'$group_key'], 'company-123');
      expect(props[r'$group_set'], {'name': 'Acme'});
    });
  });

  group('Input tolerance', () {
    // User-supplied maps arrive const, loosely typed, or straight from
    // jsonDecode; none of these shapes may throw or lose the event.
    final cases = <(String, void Function(PostHogCoreFake client))>[
      (
        'identify with a const properties map',
        (client) => client.identify('user-1', properties: const {
              r'$set': {'plan': 'pro'}
            }),
      ),
      (
        r'capture with jsonDecode properties including $groups',
        (client) => client.capture('evt',
            properties: jsonDecode('{"\$groups": {"team": "core"}, "n": 1}')
                as Map<String, Object?>),
      ),
      (
        'setPersonProperties with a nested empty map',
        (client) =>
            client.setPersonProperties(userPropertiesToSet: {'meta': {}}),
      ),
    ];

    for (final (description, act) in cases) {
      test('$description enqueues without throwing', () {
        final storage = InMemoryStorage();
        final client =
            PostHogCoreFake('k', options: testOptions(), storage: storage);
        addTearDown(client.shutdown);

        expect(() => act(client), returnsNormally);
        expect(getQueue(storage), isNotEmpty);
      });
    }
  });
}
