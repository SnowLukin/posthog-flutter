import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

import 'event_emitter.dart';
import 'feature_flag_utils.dart';
import 'storage.dart';
import 'types.dart';
import 'utils/utils.dart';
import 'uuid.dart';

/// HTTP error during PostHog fetch.
class PostHogFetchHttpError implements Exception {
  final int status;
  final String responseBody;
  final int reqByteLength;

  PostHogFetchHttpError(this.status, this.responseBody, this.reqByteLength);

  @override
  String toString() =>
      'PostHogFetchHttpError: status=$status, reqByteLength=$reqByteLength';
}

/// Network error during PostHog fetch.
class PostHogFetchNetworkError implements Exception {
  final Object? cause;
  PostHogFetchNetworkError(this.cause);

  @override
  String toString() => 'PostHogFetchNetworkError: $cause';
}

/// Network failures and transient HTTP statuses are worth retrying;
/// hard 4xx (invalid token, bad payload) will fail the same way again.
bool _isTransientFetchError(Object err) =>
    err is PostHogFetchNetworkError ||
    (err is PostHogFetchHttpError &&
        (err.status >= 500 || err.status == 429 || err.status == 408));

/// Base stateless PostHog client with queue management and HTTP operations.
///
/// Subclasses must implement [fetch], [getLibraryId], [getLibraryVersion],
/// and [getCustomUserAgent].
abstract class PostHogCoreStateless {
  // options
  final String apiKey;
  final String host;
  @protected
  final int flushAt;
  @protected
  final bool preloadFeatureFlags;
  int _maxBatchSize;
  final int _maxQueueSize;
  final Duration _flushInterval;
  final Duration _requestTimeout;
  final Duration _featureFlagsRequestTimeout;
  final bool _disableGeoip;
  @protected
  final bool disabled;

  final bool _defaultOptIn;
  final int _fetchRetryCount;
  final Duration _fetchRetryDelay;

  // internal
  @protected
  late final SimpleEventEmitter events;
  Timer? _flushTimer;
  Future<void>? _flushFuture;
  bool _shuttingDown = false;
  @protected
  late final PostHogLogger logger;
  void Function()? _removeDebugCallback;

  // Storage
  @protected
  final PostHogStorage storage;

  // Abstract methods — for subclass implementors only.
  @protected
  Future<PostHogFetchResponse> fetch(String url, PostHogFetchOptions options);
  @protected
  String getLibraryId();
  @protected
  String getLibraryVersion();
  @protected
  String? getCustomUserAgent();

  PostHogCoreStateless(
    this.apiKey, {
    PostHogConfig options = const PostHogConfig(),
    PostHogStorage? storage,
  })  : storage = storage ?? InMemoryStorage(),
        host = removeTrailingSlash(options.host),
        flushAt = options.flushAt < 1 ? 1 : options.flushAt,
        _maxBatchSize = options.maxBatchSize > options.flushAt
            ? options.maxBatchSize
            : options.flushAt,
        _maxQueueSize = options.maxQueueSize > options.flushAt
            ? options.maxQueueSize
            : options.flushAt,
        _flushInterval = options.flushInterval,
        preloadFeatureFlags = options.preloadFeatureFlags,
        _defaultOptIn = !options.optOut,
        _fetchRetryCount = options.fetchRetryCount,
        _fetchRetryDelay = options.fetchRetryDelay,
        _requestTimeout = options.requestTimeout,
        _featureFlagsRequestTimeout = options.featureFlagsRequestTimeout,
        _disableGeoip = options.disableGeoip,
        disabled = options.disabled {
    assertNotEmpty(apiKey, "You must pass your PostHog project's api key.");
    logger = PostHogLogger('[PostHog]', _logMsgIfDebug);
    events = SimpleEventEmitter(
        onListenerError: (e) => logger.warn('Error in event listener:', e));
    if (options.debug) {
      debug();
    }
  }

  void _logMsgIfDebug(void Function() fn) {
    if (isDebug) {
      fn();
    }
  }

  /// Wraps a function call, skipping it if the client is disabled.
  @protected
  void wrap(void Function() fn) {
    if (disabled) {
      logger.warn('The client is disabled');
      return;
    }
    fn();
  }

  /// Gets common event properties.
  @protected
  Map<String, Object?> getCommonEventProperties() {
    return {
      r'$lib': getLibraryId(),
      r'$lib_version': getLibraryVersion(),
    };
  }

  // Persisted property access via storage
  @protected
  T? getPersistedProperty<T>(PostHogPersistedProperty key) {
    return storage.getProperty<T>(key);
  }

  @protected
  void setPersistedProperty<T>(PostHogPersistedProperty key, T? value) {
    storage.setProperty<T>(key, value);
  }

  /// Whether the user has opted out.
  bool get optedOut {
    final stored =
        getPersistedProperty<bool>(PostHogPersistedProperty.optedOut);
    if (stored != null) return stored;
    // Unknown consent while the store is unreadable: fail closed.
    if (storage.isDegraded) return true;
    return !_defaultOptIn;
  }

  /// Opt in to tracking.
  void optIn() {
    wrap(() {
      setPersistedProperty(PostHogPersistedProperty.optedOut, false);
    });
  }

  /// Opt out of tracking.
  void optOut() {
    wrap(() {
      setPersistedProperty(PostHogPersistedProperty.optedOut, true);
    });
  }

  /// Registers a listener for [event]. Returns an unsubscribe function.
  void Function() on(String event, void Function(Object? payload) listener) {
    return events.on(event, listener);
  }

  /// Registers a listener for every event. Returns an unsubscribe function.
  void Function() onAny(void Function(String event, Object? payload) listener) {
    return events.onAny(listener);
  }

  /// Enables or disables debug mode.
  void debug([bool enabled = true]) {
    _removeDebugCallback?.call();
    _removeDebugCallback = null;

    if (enabled) {
      _removeDebugCallback =
          onAny((event, payload) => logger.info(event, payload));
    }
  }

  bool get isDebug => _removeDebugCallback != null;
  bool get isDisabled => disabled;

  Map<String, Object?> _buildPayload({
    required String distinctId,
    required String event,
    Map<String, Object?>? properties,
  }) {
    return {
      'distinct_id': distinctId,
      'event': event,
      'properties': {
        ...(properties ?? {}),
        ...getCommonEventProperties(),
      },
    };
  }

  @protected
  void identifyStateless(
    String distinctId, {
    Map<String, Object?>? properties,
    PostHogCaptureOptions? options,
  }) {
    wrap(() {
      final payload = _buildPayload(
        distinctId: distinctId,
        event: r'$identify',
        properties: properties,
      );
      enqueue('identify', payload, options: options);
    });
  }

  @protected
  void captureStateless(
    String distinctId,
    String event, {
    Map<String, Object?>? properties,
    PostHogCaptureOptions? options,
  }) {
    wrap(() {
      final payload = _buildPayload(
        distinctId: distinctId,
        event: event,
        properties: properties,
      );
      enqueue('capture', payload, options: options);
    });
  }

  @protected
  void aliasStateless(
    String alias,
    String distinctId, {
    Map<String, Object?>? properties,
    PostHogCaptureOptions? options,
  }) {
    wrap(() {
      final payload = _buildPayload(
        distinctId: distinctId,
        event: r'$create_alias',
        properties: {
          ...(properties ?? {}),
          'distinct_id': distinctId,
          'alias': alias,
        },
      );
      enqueue('alias', payload, options: options);
    });
  }

  @protected
  void groupIdentifyStateless(
    String groupType,
    Object groupKey, {
    Map<String, Object?>? groupProperties,
    PostHogCaptureOptions? options,
    String? distinctId,
    Map<String, Object?>? eventProperties,
  }) {
    wrap(() {
      final payload = _buildPayload(
        distinctId: distinctId ?? '\$${groupType}_$groupKey',
        event: r'$groupidentify',
        properties: {
          r'$group_type': groupType,
          r'$group_key': groupKey,
          r'$group_set': groupProperties ?? {},
          ...(eventProperties ?? {}),
        },
      );
      enqueue('capture', payload, options: options);
    });
  }

  @protected
  Future<GetFlagsResult> getFlags(
    String distinctId, {
    Map<String, Object> groups = const {},
    // The /flags API accepts arbitrary JSON property values (bool/int/...),
    // so the parameters must not force String values.
    Map<String, Object?> personProperties = const {},
    Map<String, Map<String, Object?>> groupProperties = const {},
    Map<String, Object?> extraPayload = const {},
  }) async {
    final url = '$host/flags/?v=2&config=true';

    final requestData = <String, Object?>{
      'token': apiKey,
      'distinct_id': distinctId,
      'groups': groups,
      'person_properties': personProperties,
      'group_properties': groupProperties,
      ...extraPayload,
    };

    logger.info('Flags URL', url);

    try {
      final response = await _fetchWithRetry(
        url,
        PostHogFetchOptions(
          method: 'POST',
          headers: {..._getCustomHeaders(), 'Content-Type': 'application/json'},
          body: jsonEncode(requestData),
        ),
        retryCount: 0,
        timeout: _featureFlagsRequestTimeout,
      );
      final json = jsonDecode(response.body) as Map<String, Object?>;
      return GetFlagsSuccess(parseFlagsResponse(json,
          onMalformedFlag: (key, e) =>
              logger.warn('Skipping malformed feature flag "$key":', e)));
    } catch (e) {
      events.emit('error', e);
      return GetFlagsFailure(_categorizeRequestError(e));
    }
  }

  FeatureFlagRequestError _categorizeRequestError(Object error) {
    if (error is PostHogFetchHttpError) {
      return FeatureFlagRequestError(
          type: FeatureFlagRequestErrorType.apiError, statusCode: error.status);
    }
    if (error is PostHogFetchNetworkError) {
      if (error.cause is TimeoutException) {
        return const FeatureFlagRequestError(
            type: FeatureFlagRequestErrorType.timeout);
      }
      return const FeatureFlagRequestError(
          type: FeatureFlagRequestErrorType.connectionError);
    }
    return const FeatureFlagRequestError(
        type: FeatureFlagRequestErrorType.unknownError);
  }

  // No memoization: storage already caches in memory, and a second cache
  // layer would go stale when the store changes underneath.
  @protected
  Map<String, Object?> get props {
    return getPersistedProperty<Map<String, Object?>>(
            PostHogPersistedProperty.props) ??
        {};
  }

  @protected
  set props(Map<String, Object?>? val) {
    setPersistedProperty(PostHogPersistedProperty.props, val);
  }

  void register(Map<String, Object?> properties) {
    wrap(() {
      setPersistedProperty(
          PostHogPersistedProperty.props, {...props, ...properties});
    });
  }

  void unregister(String property) {
    wrap(() {
      final updated = {...props}..remove(property);
      setPersistedProperty(PostHogPersistedProperty.props, updated);
    });
  }

  /// Hook for subclasses to transform or filter a message before queueing.
  @protected
  FutureOr<Map<String, Object?>?> processBeforeEnqueue(
      Map<String, Object?> message) {
    return message;
  }

  @protected
  void enqueue(String type, Map<String, Object?> message,
      {PostHogCaptureOptions? options}) {
    if (disabled) return;
    if (optedOut) {
      events.emit(type,
          'Library is disabled. Not sending event. To re-enable, call posthog.optIn()');
      return;
    }

    final prepared = _prepareMessage(type, message, options);
    final result = processBeforeEnqueue(prepared);
    if (result is Future<Map<String, Object?>?>) {
      result.then((resolved) {
        if (resolved != null) _enqueueMessage(type, resolved);
      });
    } else {
      if (result != null) _enqueueMessage(type, result);
    }
  }

  void _enqueueMessage(String type, Map<String, Object?> prepared) {
    final queue =
        getPersistedProperty<List<Object?>>(PostHogPersistedProperty.queue) ??
            [];

    final mutableQueue = List<Object?>.from(queue);
    if (mutableQueue.length >= _maxQueueSize) {
      mutableQueue.removeAt(0);
      logger.info('Queue is full, the oldest event is dropped.');
    }

    mutableQueue.add({'message': prepared});
    setPersistedProperty(PostHogPersistedProperty.queue, mutableQueue);

    events.emit(type, prepared);

    if (mutableQueue.length >= flushAt) {
      _flushBackground();
    }

    _scheduleFlush();
  }

  void _scheduleFlush() {
    // A failed flush during shutdown must not re-arm the timer: it would
    // retry forever against a client whose resources are already released.
    if (_shuttingDown) return;
    if (_flushInterval > Duration.zero && _flushTimer == null) {
      _flushTimer = Timer(_flushInterval, _flushBackground);
    }
  }

  Map<String, Object?> _prepareMessage(
    String type,
    Map<String, Object?> message,
    PostHogCaptureOptions? options,
  ) {
    final prepared = <String, Object?>{
      ...message,
      'type': type,
      'library': getLibraryId(),
      'library_version': getLibraryVersion(),
      'timestamp':
          options?.timestamp?.toUtc().toIso8601String() ?? currentISOTime(),
      'uuid': options?.uuid ?? generateUuidV7(),
    };

    final addGeoipDisable = options?.disableGeoip ?? _disableGeoip;
    if (addGeoipDisable) {
      prepared.putIfAbsent('properties', () => <String, Object?>{});
      (prepared['properties'] as Map<String, Object?>)[r'$geoip_disable'] =
          true;
    }

    return prepared;
  }

  void _clearFlushTimer() {
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  void _flushBackground() {
    flush().catchError((e) {
      logger.error('Error while flushing PostHog', e);
    });
  }

  /// Flushes the queue of pending events.
  /// If a flush is already in progress, returns the existing future to avoid
  /// concurrent flushes sending duplicate events.
  Future<void> flush() {
    if (_flushFuture != null) return _flushFuture!;
    _flushFuture = _doFlush().whenComplete(() => _flushFuture = null);
    return _flushFuture!;
  }

  Future<void> _doFlush() async {
    _clearFlushTimer();

    final sentMessages = <Object?>[];

    while (true) {
      // Re-read from storage each iteration so we see a consistent snapshot
      // that includes any events enqueued during the previous await.
      final queue = List<Object?>.from(
          getPersistedProperty<List<Object?>>(PostHogPersistedProperty.queue) ??
              []);

      if (queue.isEmpty) break;

      final batchItems = queue.take(_maxBatchSize).toList();
      final batchMessages =
          batchItems.map((item) => (item as Map)['message']).toList();

      final data = <String, Object?>{
        'api_key': apiKey,
        'batch': batchMessages,
        'sent_at': currentISOTime(),
      };

      final payload = jsonEncode(data);
      final url = '$host/batch/';

      try {
        await _fetchWithRetry(
          url,
          PostHogFetchOptions(
            method: 'POST',
            headers: {
              ..._getCustomHeaders(),
              'Content-Type': 'application/json',
            },
            body: payload,
          ),
        );
      } catch (e) {
        if (e is PostHogFetchHttpError &&
            e.status == 413 &&
            batchMessages.length > 1) {
          _maxBatchSize = (batchMessages.length ~/ 2).clamp(1, _maxBatchSize);
          logger.warn('Received 413, reducing batch size to $_maxBatchSize');
          continue; // retry with smaller batch
        }

        // Keep the batch queued on transient failures (network, 5xx, 429,
        // 408); drop it only on hard 4xx that would fail again.
        if (!_isTransientFetchError(e)) {
          _removeBatchFromQueue(batchItems);
        }
        // Re-arm the periodic flush: otherwise queued events sit until the
        // next capture (forever in an idle app after an offline failure).
        _scheduleFlush();
        events.emit('error', e);
        rethrow;
      }

      // Successfully sent — remove the batch from the queue
      _removeBatchFromQueue(batchItems);
      sentMessages.addAll(batchMessages);
    }

    if (sentMessages.isNotEmpty) {
      events.emit('flush', sentMessages);
    }
  }

  /// Removes the sent [batchItems] from the persisted queue by message uuid:
  /// the head may shift while a batch is in flight (overflow drop), so
  /// positional removal could drop unsent events and resend sent ones.
  void _removeBatchFromQueue(List<Object?> batchItems) {
    Object? uuidOf(Object? item) {
      if (item is! Map) return null;
      final message = item['message'];
      return message is Map ? message['uuid'] : null;
    }

    final queue = List<Object?>.from(
        getPersistedProperty<List<Object?>>(PostHogPersistedProperty.queue) ??
            []);
    final sent = batchItems.map(uuidOf).whereType<Object>().toSet();

    if (sent.isEmpty) {
      // The batch carries no uuids (foreign queue shape): fall back to
      // positional removal so the flush loop keeps making progress.
      if (queue.isNotEmpty) {
        final removeCount = batchItems.length.clamp(0, queue.length);
        setPersistedProperty(
            PostHogPersistedProperty.queue, queue.sublist(removeCount));
      }
      return;
    }

    final remaining = queue.where((item) {
      final uuid = uuidOf(item);
      return uuid == null || !sent.contains(uuid);
    }).toList();

    // Nothing matched: the batch was already evicted by queue overflow while
    // in flight, and the queue now holds only newer, unsent events.
    if (remaining.length == queue.length) return;

    setPersistedProperty(PostHogPersistedProperty.queue, remaining);
  }

  Map<String, String> _getCustomHeaders() {
    final userAgent = getCustomUserAgent();
    if (userAgent != null && userAgent.isNotEmpty) {
      return {'User-Agent': userAgent};
    }
    return {};
  }

  Future<PostHogFetchResponse> _fetchWithRetry(
    String url,
    PostHogFetchOptions options, {
    int? retryCount,
    Duration? timeout,
  }) async {
    return retriable(
      () async {
        PostHogFetchResponse response;
        try {
          response =
              await fetch(url, options).timeout(timeout ?? _requestTimeout);
        } catch (e) {
          throw PostHogFetchNetworkError(e);
        }

        if (response.status < 200 || response.status >= 400) {
          throw PostHogFetchHttpError(
            response.status,
            response.body,
            options.body?.length ?? 0,
          );
        }
        return response;
      },
      retryCount: retryCount ?? _fetchRetryCount,
      retryDelay: _fetchRetryDelay,
      retryCheck: _isTransientFetchError,
    );
  }

  /// Shuts down the PostHog instance and ensures all events are sent.
  Future<void> shutdown(
      {Duration timeout = const Duration(seconds: 30)}) async {
    _shuttingDown = true;
    _clearFlushTimer();

    try {
      await flush().timeout(
        timeout,
        onTimeout: () {
          logger.error('Timed out while shutting down PostHog');
        },
      );
    } catch (e) {
      // Best-effort: events stay queued and callers still release resources.
      logger.error('Failed to flush while shutting down PostHog', e);
    } finally {
      _clearFlushTimer();
    }
  }
}
