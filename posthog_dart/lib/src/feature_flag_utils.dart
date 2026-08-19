import 'dart:convert';

import 'feature_flags.dart';

/// Parses a v2 flags response JSON into a [PostHogFlagsResponse].
PostHogFlagsResponse parseFlagsResponse(
  Map<String, Object?> response, {
  void Function(String key, Object error)? onMalformedFlag,
}) {
  final flagsRaw = response['flags'] as Map<String, Object?>? ?? {};

  return PostHogFlagsResponse(
    flags: PostHogFeatureFlagDetail.parseAll(flagsRaw,
        onMalformed: onMalformedFlag),
    errorsWhileComputingFlags:
        response['errorsWhileComputingFlags'] as bool? ?? false,
    quotaLimited: (response['quotaLimited'] as List<Object?>?)
        ?.map((e) => e as String)
        .toList(),
    requestId: response['requestId'] as String?,
    evaluatedAt: response['evaluatedAt'] as int?,
  );
}

/// Get the value from a [PostHogFeatureFlagDetail].
///
/// Returns the variant string if present, the enabled bool otherwise.
/// Returns null if the detail is null.
PostHogFeatureFlagValue? getFeatureFlagValue(PostHogFeatureFlagDetail? detail) {
  if (detail == null) return null;
  return detail.variant ?? detail.enabled;
}

/// Parse a payload value, attempting JSON decode if it's a string.
Object? parsePayload(Object? response) {
  if (response is! String) return response;
  try {
    return jsonDecode(response);
  } catch (_) {
    return response;
  }
}
