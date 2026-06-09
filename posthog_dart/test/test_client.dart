import 'dart:async';

import 'package:posthog_dart/posthog_dart.dart';
import 'package:posthog_dart/src/http.dart';
import 'package:posthog_dart/src/posthog_core.dart';

/// Extracts queued event messages from [storage].
List<Map<String, Object?>> getQueue(PostHogStorage storage) {
  final raw =
      storage.getProperty<List<Object?>>(PostHogPersistedProperty.queue);
  if (raw == null) return [];
  return raw.cast<Map<String, Object?>>();
}

/// PostHog client that records fetch calls instead of making HTTP requests.
class TestClient extends PostHogCore {
  final List<({String url, PostHogFetchOptions options})> fetchCalls = [];
  FutureOr<PostHogFetchResponse> Function(
      String url, PostHogFetchOptions options)? fetchHandler;

  TestClient(super.apiKey, {super.options, super.storage});

  @override
  Future<PostHogFetchResponse> fetch(
      String url, PostHogFetchOptions options) async {
    fetchCalls.add((url: url, options: options));
    if (fetchHandler != null) return fetchHandler!(url, options);
    return const PostHogFetchResponse(status: 200, body: '{"status": "ok"}');
  }

  @override
  String getLibraryId() => 'posthog-dart-test';

  @override
  String getLibraryVersion() => '0.0.1';

  @override
  String? getCustomUserAgent() => 'posthog-dart-test/0.0.1';
}

PostHogConfig testOptions({
  bool optOut = false,
  List<BeforeSendCallback>? beforeSend,
}) =>
    PostHogConfig(
      host: 'https://us.i.posthog.com',
      flushAt: 100,
      preloadFeatureFlags: false,
      optOut: optOut,
      beforeSend: beforeSend,
      fetchRetryCount: 0,
      fetchRetryDelay: Duration.zero,
    );
