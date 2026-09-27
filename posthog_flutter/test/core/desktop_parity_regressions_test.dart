import 'package:flutter_test/flutter_test.dart';
import 'package:posthog_flutter/src/core/file_storage.dart';

import '../posthog_api_fake.dart';
import 'test_client.dart';

void main() {
  late LocalPostHogServer server;

  setUp(() async {
    server = await LocalPostHogServer.start();
  });

  for (final invalidGroups in <Object>[
    'legacy',
    42,
    ['legacy'],
  ]) {
    test('некорректные groups $invalidGroups не блокируют capture и flags',
        () async {
      final directory = tempDirectory();
      final first = testClient(server, storage: FileStorage(directory.path));
      first.register({r'$groups': invalidGroups, 'plan': 'pro'});
      first.close();
      final client = testClient(server, storage: FileStorage(directory.path));

      client.capture('purchase');
      await client.reloadFeatureFlagsAsync();
      await client.flush();

      final properties = server.events.single['properties']! as Map;
      expect(properties['plan'], 'pro');
      expect(properties[r'$process_person_profile'], isFalse);
      expect(server.flagsRequests.last.body['groups'], isEmpty);

      client.group('company', 'acme');
      await client.reloadFeatureFlagsAsync();
      expect(server.flagsRequests.last.body['groups'], {'company': 'acme'});
    });
  }

  test('валидные memberships старого store переживают плохой соседний ключ',
      () async {
    final directory = tempDirectory();
    final first = testClient(server, storage: FileStorage(directory.path));
    first.register({
      r'$groups': {'company': 'acme', 'broken': 42},
    });
    first.close();
    final storage = FileStorage(directory.path);
    final client = testClient(server, storage: storage);

    client.capture('purchase');
    await client.reloadFeatureFlagsAsync();

    expect(queuedProps(storage, 0)[r'$process_person_profile'], isTrue);
    expect(server.flagsRequests.last.body['groups'], {'company': 'acme'});
  });

  test('caller session ID относится только к своему событию', () {
    final storage = tempStorage();
    final client = testClient(server, storage: storage);
    final internalSession = client.getSessionId();

    client
        .capture('external', properties: {r'$session_id': 'external-session'});
    client.capture('internal');

    expect(queuedProps(storage, 0)[r'$session_id'], 'external-session');
    expect(queuedProps(storage, 1)[r'$session_id'], internalSession);
    expect(client.getSessionId(), internalSession);
  });

  for (final invalidSession in <Object>['', 42]) {
    test('некорректный session ID $invalidSession заменяется текущим', () {
      final storage = tempStorage();
      final client = testClient(server, storage: storage);
      client.capture('purchase', properties: {r'$session_id': invalidSession});
      expect(queuedProps(storage, 0)[r'$session_id'], client.getSessionId());
    });
  }

  for (final property in [r'$set', r'$set_once']) {
    test('прямой $property меняет marker последнего person update', () async {
      final client = testClient(server);
      void setPlan(String plan) {
        if (property == r'$set') {
          client.setPersonProperties(userPropertiesToSet: {'plan': plan});
        } else {
          client.setPersonProperties(userPropertiesToSetOnce: {'plan': plan});
        }
      }

      setPlan('A');
      client.capture(r'$set', properties: {
        property: {'plan': 'B'},
      });
      setPlan('A');
      await client.flush();

      expect(
        [
          for (final event in server.events)
            ((event['properties']! as Map)[property] as Map)['plan'],
        ],
        ['A', 'B', 'A'],
      );
    });
  }

  test('прямой set с теми же свойствами подавляет последующий дубликат', () {
    final storage = tempStorage();
    final client = testClient(server, storage: storage);
    client.capture(r'$set', properties: {
      r'$set': {'plan': 'A'},
    });
    client.setPersonProperties(userPropertiesToSet: {'plan': 'A'});
    expect(queuedEvents(storage), [r'$set']);
  });

  test('opt-out не меняет marker последнего person update', () {
    final storage = tempStorage();
    final client = testClient(server, storage: storage);
    client.setPersonProperties(userPropertiesToSet: {'plan': 'A'});
    client.optOut();
    client.capture(r'$set', properties: {
      r'$set': {'plan': 'B'},
    });
    client.optIn();
    client.setPersonProperties(userPropertiesToSet: {'plan': 'A'});
    expect(queuedEvents(storage), [r'$set']);
  });

  test('null в person properties не ломает подавление дубликатов', () {
    final storage = tempStorage();
    final client = testClient(server, storage: storage);
    client.setPersonProperties(userPropertiesToSet: {'plan': 'A', 'old': null});
    client.setPersonProperties(userPropertiesToSet: {'plan': 'A', 'old': null});
    expect(queuedEvents(storage), [r'$set']);
  });

  test('свойства события сохраняют приоритет над registered', () {
    final storage = tempStorage();
    final client = testClient(server, storage: storage);
    client.register({'plan': 'pro'});
    client.capture('purchase', properties: {'plan': 'free'});
    expect(queuedProps(storage, 0)['plan'], 'free');
  });

  test('session свойства сохраняют приоритет под caller и над registered', () {
    final storage = tempStorage();
    final client = testClient(server, storage: storage);
    client.register({'plan': 'registered', 'screen': 'registered'});
    client.registerForSession({'plan': 'session', 'screen': 'Checkout'});
    client.capture('purchase', properties: {'plan': 'event'});
    expect(queuedProps(storage, 0)['plan'], 'event');
    expect(queuedProps(storage, 0)['screen'], 'Checkout');
  });
}
