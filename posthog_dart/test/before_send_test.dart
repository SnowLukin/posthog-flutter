import 'dart:async';

import 'package:posthog_dart/posthog_dart.dart';
import 'package:test/test.dart';

import 'posthog_core_fake.dart';

void main() {
  group('beforeSend hook', () {
    test(r'passes $set user properties through unchanged', () {
      final storage = InMemoryStorage();
      final client = PostHogCoreFake(
        'k',
        options: testOptions(beforeSend: [(event) => event]),
        storage: storage,
      );
      addTearDown(client.shutdown);

      client.setPersonProperties(userPropertiesToSet: {'plan': 'pro'});

      expect(getQueue(storage), hasLength(1));
      expect(queuedProps(storage, 0)[r'$set'], {'plan': 'pro'});
    });

    test(r'a callback can rewrite the $set user properties', () {
      final storage = InMemoryStorage();
      final client = PostHogCoreFake(
        'k',
        options: testOptions(beforeSend: [
          (event) {
            event.userProperties = {'plan': 'enterprise'};
            return event;
          }
        ]),
        storage: storage,
      );
      addTearDown(client.shutdown);

      client.setPersonProperties(userPropertiesToSet: {'plan': 'pro'});

      expect(queuedProps(storage, 0)[r'$set'], {'plan': 'enterprise'});
    });

    test('a synchronous null return drops the event', () {
      final storage = InMemoryStorage();
      final client = PostHogCoreFake(
        'k',
        options: testOptions(beforeSend: [
          (event) => event.event == 'drop_me' ? null : event,
        ]),
        storage: storage,
      );
      addTearDown(client.shutdown);

      client.capture('keep_me');
      client.capture('drop_me');
      client.capture('keep_me_too');

      expect(getQueue(storage), hasLength(2));
      expect(queuedMessage(storage, 0)['event'], 'keep_me');
      expect(queuedMessage(storage, 1)['event'], 'keep_me_too');
    });

    test('an asynchronous null return drops the event', () async {
      final storage = InMemoryStorage();
      final client = PostHogCoreFake(
        'k',
        options: testOptions(beforeSend: [
          (event) async => event.event == 'drop_me' ? null : event,
        ]),
        storage: storage,
      );
      addTearDown(client.shutdown);
      final enqueued = Completer<void>();
      client.on('capture', (_) => enqueued.complete());

      client.capture('drop_me');
      client.capture('keep_me');
      // The hooks resolve in capture order, so once 'keep_me' lands the
      // 'drop_me' decision has already been made.
      await enqueued.future;

      final events = [
        for (var i = 0; i < getQueue(storage).length; i++)
          queuedMessage(storage, i)['event'],
      ];
      expect(events, ['keep_me']);
    });

    test('a throwing callback fails open and the chain continues', () {
      final storage = InMemoryStorage();
      final client = PostHogCoreFake(
        'k',
        options: testOptions(beforeSend: [
          (event) => throw StateError('broken hook'),
          (event) {
            event.properties = {...?event.properties, 'chained': true};
            return event;
          },
        ]),
        storage: storage,
      );
      addTearDown(client.shutdown);

      client.capture('evt', properties: {'origin': 'test'});

      final props = queuedProps(storage, 0);
      expect(props['origin'], 'test',
          reason: 'a broken hook must not drop or truncate the event');
      expect(props['chained'], isTrue);
    });

    test('setting event.properties to null clears the event properties', () {
      final storage = InMemoryStorage();
      final client = PostHogCoreFake(
        'k',
        options: testOptions(beforeSend: [
          (event) {
            event.properties = null;
            return event;
          }
        ]),
        storage: storage,
      );
      addTearDown(client.shutdown);

      client.capture('evt', properties: {'email': 'user@example.com'});

      expect(getQueue(storage), hasLength(1));
      expect(queuedProps(storage, 0), isEmpty,
          reason: 'scrubbing hooks rely on a null property map wiping '
              'everything, including the enriched properties');
    });

    test('a null-valued property survives the pipeline', () {
      final storage = InMemoryStorage();
      final client = PostHogCoreFake(
        'k',
        options: testOptions(beforeSend: [(event) => event]),
        storage: storage,
      );
      addTearDown(client.shutdown);

      client.capture('evt',
          properties: {r'$feature_flag_response': null, 'flag_key': 'promo'});

      final props = queuedProps(storage, 0);
      expect(props, containsPair(r'$feature_flag_response', null),
          reason: 'PostHogEvent cannot represent null values, so the '
              'pipeline must restore them after the hooks run');
      expect(props['flag_key'], 'promo');
    });

    test('an async callback runs exactly once per event', () async {
      var calls = 0;
      final storage = InMemoryStorage();
      final client = PostHogCoreFake(
        'k',
        options: testOptions(beforeSend: [
          (event) async {
            calls++;
            return event;
          }
        ]),
        storage: storage,
      );
      addTearDown(client.shutdown);
      final enqueued = Completer<void>();
      client.on('capture', (_) => enqueued.complete());

      client.capture('evt');
      await enqueued.future;

      expect(calls, 1);
      expect(getQueue(storage), hasLength(1));
    });

    test('mixed sync/async chain runs each callback once, in order', () async {
      final invocations = <String>[];
      PostHogEvent mark(PostHogEvent event, String name) {
        invocations.add(name);
        event.properties = {...?event.properties, name: true};
        return event;
      }

      final storage = InMemoryStorage();
      final client = PostHogCoreFake(
        'k',
        options: testOptions(beforeSend: [
          (event) => mark(event, 'first'),
          (event) async => mark(event, 'second'),
          (event) => mark(event, 'third'),
        ]),
        storage: storage,
      );
      addTearDown(client.shutdown);
      final enqueued = Completer<void>();
      client.on('capture', (_) => enqueued.complete());

      client.capture('evt');
      await enqueued.future;

      expect(invocations, ['first', 'second', 'third']);
      final props = queuedProps(storage, 0);
      expect(props['first'], isTrue);
      expect(props['second'], isTrue);
      expect(props['third'], isTrue);
    });
  });
}
