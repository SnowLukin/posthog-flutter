import 'feature_flags.dart';

/// Parses a v2 flags response JSON into a [PostHogFlagsResponse].
PostHogFlagsResponse parseFlagsResponse(
  Map<String, Object?> response, {
  required void Function(String key, Object error) onMalformedFlag,
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
    // Anything but an explicit true keeps full events.
    minimalFlagCalledEvents: response['minimalFlagCalledEvents'] == true,
  );
}

/// Properties a minimal `$feature_flag_called` event keeps. The server asks
/// for minimal events per project, and they are only sent for flags that are
/// verifiably not linked to an experiment. Everything else - super
/// properties, `$feature/<key>`, `$active_feature_flags`, debug properties -
/// is dropped.
const minimalFeatureFlagCalledProperties = <String>{
  r'$feature_flag',
  r'$feature_flag_response',
  r'$feature_flag_has_experiment',
  r'$feature_flag_id',
  r'$feature_flag_version',
  r'$feature_flag_reason',
  r'$feature_flag_request_id',
  r'$feature_flag_evaluated_at',
  r'$feature_flag_error',
  r'$groups',
  r'$process_person_profile',
  r'$geoip_disable',
  r'$session_id',
  r'$window_id',
  r'$lib',
  r'$lib_version',
  r'$device_id',
  r'$os_name',
  r'$os_version',
  r'$app_version',
  // A minimal event can be the first event of a session, which is where the
  // server reads the session's campaign attribution from.
  r'$referring_domain',
  'utm_source',
  'utm_medium',
  'utm_campaign',
  'utm_content',
  'utm_term',
  'gad_source',
  'mc_cid',
  'gclid',
  'gclsrc',
  'dclid',
  'gbraid',
  'wbraid',
  'fbclid',
  'msclkid',
  'twclid',
  'li_fat_id',
  'igshid',
  'ttclid',
  'rdt_cid',
  'epik',
  'qclid',
  'sccid',
  'irclid',
  '_kx',
};

/// Get the value from a [PostHogFeatureFlagDetail].
///
/// Returns the variant string if present, the enabled bool otherwise.
/// Returns null if the detail is null.
PostHogFeatureFlagValue? getFeatureFlagValue(PostHogFeatureFlagDetail? detail) {
  if (detail == null) return null;
  return detail.variant ?? detail.enabled;
}
