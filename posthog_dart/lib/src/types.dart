// Barrel file — re-exports all type definitions for internal use.
export 'config.dart';
export 'feature_flags.dart';
export 'http.dart';
export 'logger.dart';
export 'persistence.dart';

/// Feature identifiers the server reports in
/// [PostHogFlagsResponse.quotaLimited].
class QuotaLimitedFeature {
  static const String featureFlags = 'feature_flags';
}
