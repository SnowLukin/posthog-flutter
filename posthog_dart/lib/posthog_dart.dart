/// PostHog analytics SDK for Dart.
///
/// Provides product analytics and feature flags functionality.
///
/// ```dart
/// final posthog = PostHog('phc_your_api_key');
/// posthog.capture('event_name', properties: {'key': 'value'});
/// ```
library;

export 'src/config.dart'
    show
        PostHogConfig,
        PostHogCaptureOptions,
        PostHogPersonProfiles,
        BeforeSendCallback,
        PostHogEvent;
export 'src/event_emitter.dart' show SimpleEventEmitter;
export 'src/feature_flags.dart'
    show
        PostHogFeatureFlagValue,
        PostHogFeatureFlagDetail,
        PostHogFeatureFlagMetadata,
        PostHogEvaluationReason,
        PostHogFeatureFlagResult,
        PostHogFeatureFlagResultOptions,
        PostHogFlagsResponse,
        FeatureFlagRequestError,
        FeatureFlagRequestErrorType,
        GetFlagsResult,
        GetFlagsSuccess,
        GetFlagsFailure;
export 'src/file_storage.dart' show FileStorage;
export 'src/http.dart' show PostHogFetchOptions, PostHogFetchResponse;
export 'src/logger.dart' show PostHogLogger;
export 'src/persistence.dart' show PostHogPersistedProperty;
export 'src/posthog_client.dart' show PostHog;
export 'src/posthog_core.dart' show PostHogCore;
export 'src/posthog_core_stateless.dart'
    show PostHogCoreStateless, PostHogFetchHttpError, PostHogFetchNetworkError;
export 'src/storage.dart' show PostHogStorage, InMemoryStorage;
export 'src/types.dart' show QuotaLimitedFeature;
