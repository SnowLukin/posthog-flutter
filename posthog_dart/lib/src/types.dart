// Barrel file — re-exports all type definitions for internal use.
export 'config.dart';
export 'feature_flags.dart';
export 'http.dart';
export 'logger.dart';
export 'persistence.dart';

/// Group properties map — values must be non-null primitives.
typedef PostHogGroupProperties = Map<String, Object>;

/// Quota limited feature constants (internal).
class QuotaLimitedFeature {
  static const String featureFlags = 'feature_flags';
}
