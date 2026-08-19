import 'dart:async';

import 'package:posthog_dart/posthog_dart.dart';

/// PostHog core with fetch stubbed out, so tests can drive the full client
/// logic without network access.
///
/// Every fetch is recorded in [fetchCalls]; responses come from
/// [fetchHandler], or HTTP 200 when no handler is set.
class PostHogCoreFake extends PostHogCore {
  final List<({String url, PostHogFetchOptions options})> fetchCalls = [];
  FutureOr<PostHogFetchResponse> Function(
      String url, PostHogFetchOptions options)? fetchHandler;

  PostHogCoreFake(super.apiKey, {super.options, super.storage});

  @override
  Future<PostHogFetchResponse> fetch(
      String url, PostHogFetchOptions options) async {
    // A real HTTP request never completes synchronously; without this hop a
    // handler could re-enter the flush loop it was called from.
    await Future<void>.delayed(Duration.zero);
    fetchCalls.add((url: url, options: options));
    final handler = fetchHandler;
    if (handler != null) return handler(url, options);
    return const PostHogFetchResponse(status: 200, body: '{"status": "ok"}');
  }

  @override
  String getLibraryId() => 'posthog-dart-test';

  @override
  String getLibraryVersion() => '0.0.1';

  @override
  String? getCustomUserAgent() => 'posthog-dart-test/0.0.1';
}

/// Config tuned for tests: no preload, no retries, no retry delay, and a
/// flushAt high enough that flushes only happen when a test asks for them.
PostHogConfig testOptions({
  int flushAt = 100,
  int maxBatchSize = 100,
  int maxQueueSize = 1000,
  Duration flushInterval = const Duration(seconds: 30),
  Duration requestTimeout = const Duration(seconds: 10),
  bool optOut = false,
  bool disabled = false,
  bool setDefaultPersonProperties = true,
  PostHogPersonProfiles personProfiles = PostHogPersonProfiles.identifiedOnly,
  int fetchRetryCount = 0,
  List<BeforeSendCallback>? beforeSend,
}) =>
    PostHogConfig(
      host: 'https://us.i.posthog.com',
      flushAt: flushAt,
      maxBatchSize: maxBatchSize,
      maxQueueSize: maxQueueSize,
      flushInterval: flushInterval,
      requestTimeout: requestTimeout,
      preloadFeatureFlags: false,
      optOut: optOut,
      disabled: disabled,
      setDefaultPersonProperties: setDefaultPersonProperties,
      personProfiles: personProfiles,
      fetchRetryCount: fetchRetryCount,
      fetchRetryDelay: Duration.zero,
      beforeSend: beforeSend,
    );

/// Queued items as stored under [PostHogPersistedProperty.queue].
List<Map<String, Object?>> getQueue(PostHogStorage storage) {
  final raw =
      storage.getProperty<List<Object?>>(PostHogPersistedProperty.queue);
  if (raw == null) return [];
  return raw.cast<Map<String, Object?>>();
}

/// The queued event message at [index].
Map<String, Object?> queuedMessage(PostHogStorage storage, int index) {
  return getQueue(storage)[index]['message'] as Map<String, Object?>;
}

/// The properties of the queued event message at [index].
Map<String, Object?> queuedProps(PostHogStorage storage, int index) {
  return queuedMessage(storage, index)['properties'] as Map<String, Object?>;
}
