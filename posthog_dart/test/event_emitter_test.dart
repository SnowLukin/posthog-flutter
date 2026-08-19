import 'package:posthog_dart/posthog_dart.dart';
import 'package:test/test.dart';

void main() {
  group('SimpleEventEmitter', () {
    test('delivers the payload to listeners of the event', () {
      final emitter = SimpleEventEmitter();
      final received = <Object?>[];
      emitter.on('connected', received.add);

      emitter.emit('connected', 'payload');
      emitter.emit('unrelated', 'ignored');

      expect(received, ['payload']);
    });

    test('stops delivering after unsubscribe', () {
      final emitter = SimpleEventEmitter();
      var calls = 0;
      final unsubscribe = emitter.on('tick', (_) => calls++);

      emitter.emit('tick');
      unsubscribe();
      emitter.emit('tick');

      expect(calls, 1);
    });

    test('notifies catch-all listeners with the event name and payload', () {
      final emitter = SimpleEventEmitter();
      final received = <(String, Object?)>[];
      emitter.onAny((event, payload) => received.add((event, payload)));

      emitter.emit('first', 1);
      emitter.emit('second');

      expect(received, [('first', 1), ('second', null)]);
    });

    test('stops notifying a catch-all listener after unsubscribe', () {
      final emitter = SimpleEventEmitter();
      var calls = 0;
      final unsubscribe = emitter.onAny((_, __) => calls++);

      emitter.emit('tick');
      unsubscribe();
      emitter.emit('tick');

      expect(calls, 1);
    });

    test('a throwing listener is reported and does not stop the others', () {
      final errors = <Object>[];
      final emitter = SimpleEventEmitter(onListenerError: errors.add);
      final received = <Object?>[];
      final anyReceived = <String>[];
      emitter.on('boom', (_) => throw StateError('listener failure'));
      emitter.on('boom', received.add);
      emitter.onAny((event, _) => anyReceived.add(event));

      expect(() => emitter.emit('boom', 'payload'), returnsNormally);

      expect(received, ['payload'],
          reason: 'one broken listener must not starve the rest');
      expect(anyReceived, ['boom']);
      expect(errors, [isA<StateError>()]);
    });
  });
}
