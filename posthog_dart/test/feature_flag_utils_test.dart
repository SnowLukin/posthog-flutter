import 'package:posthog_dart/posthog_dart.dart';
import 'package:posthog_dart/src/feature_flag_utils.dart';
import 'package:test/test.dart';

void main() {
  group('parseFlagsResponse', () {
    test('parses v2 flag details and derives their values', () {
      final response = parseFlagsResponse({
        'flags': {
          'bool-flag': {
            'key': 'bool-flag',
            'enabled': true,
          },
          'variant-flag': {
            'key': 'variant-flag',
            'enabled': true,
            'variant': 'control',
            'metadata': {'payload': '"hello"'},
          },
        },
      });

      expect(response.featureFlags, {
        'bool-flag': true,
        'variant-flag': 'control',
      });
      expect(response.flags['bool-flag']?.enabled, isTrue);
      expect(response.flags['variant-flag']?.enabled, isTrue);
      expect(response.flags['variant-flag']?.variant, 'control');
    });

    test('derives payloads only for enabled flags', () {
      final response = parseFlagsResponse({
        'flags': {
          'enabled-flag': {
            'key': 'enabled-flag',
            'enabled': true,
            'metadata': {'payload': '{"key":"value"}'},
          },
          'disabled-flag': {
            'key': 'disabled-flag',
            'enabled': false,
            'metadata': {'payload': '"ignored"'},
          },
        },
      });

      expect(response.featureFlagPayloads, {
        'enabled-flag': {'key': 'value'},
      });
    });
  });

  group('getFeatureFlagValue', () {
    // (description, flag detail, expected value)
    const cases = <(String, PostHogFeatureFlagDetail?, Object?)>[
      (
        'returns the variant for a multivariate flag',
        PostHogFeatureFlagDetail(key: 'f', enabled: true, variant: 'control'),
        'control',
      ),
      (
        'returns true for an enabled boolean flag',
        PostHogFeatureFlagDetail(key: 'f', enabled: true),
        true,
      ),
      (
        'returns false for a disabled boolean flag',
        PostHogFeatureFlagDetail(key: 'f', enabled: false),
        false,
      ),
      ('returns null for a missing flag', null, null),
    ];

    for (final (description, detail, expected) in cases) {
      test(description, () {
        expect(getFeatureFlagValue(detail), expected);
      });
    }
  });

  group('parsePayload', () {
    // (description, raw payload, parsed payload)
    const cases = <(String, Object?, Object?)>[
      ('decodes a JSON object string', '{"key":"value"}', {'key': 'value'}),
      ('decodes a JSON string literal', '"hello"', 'hello'),
      ('passes a non-string value through', 42, 42),
      ('keeps a non-JSON string as-is', 'not-json{', 'not-json{'),
    ];

    for (final (description, raw, expected) in cases) {
      test(description, () {
        expect(parsePayload(raw), expected);
      });
    }
  });
}
