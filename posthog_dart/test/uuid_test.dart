import 'package:posthog_dart/src/uuid.dart';
import 'package:test/test.dart';

void main() {
  group('generateUuidV7', () {
    test('produces the RFC 9562 version-7 layout', () {
      final uuid = generateUuidV7();

      expect(uuid, hasLength(36));
      expect(
          uuid,
          matches(RegExp(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    });

    test('produces unique values', () {
      final uuids = List.generate(100, (_) => generateUuidV7());

      expect(uuids.toSet(), hasLength(100));
    });

    test('sorts lexicographically across milliseconds', () async {
      final earlier = generateUuidV7();
      // The version-7 prefix is a millisecond timestamp, so ordering only
      // shows up once the clock has actually ticked.
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final later = generateUuidV7();

      expect(later.compareTo(earlier), greaterThan(0));
    });
  });
}
