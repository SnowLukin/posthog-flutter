import 'dart:async';
import 'dart:io';

import 'package:posthog_dart/posthog_dart.dart' as pd;

import 'src/feature_flag_result.dart';
import 'src/posthog_config.dart';
import 'src/posthog_desktop_context.dart';
import 'src/posthog_event.dart';
import 'src/posthog_flutter_platform_interface.dart';
import 'src/util/logging.dart';
import 'src/utils/property_normalizer.dart';

/// Desktop (Windows/Linux) implementation on top of the pure-Dart
/// posthog_dart package, bridging the plugin types at method boundaries.
///
/// Every method is wrapped in a guard: analytics never throws into the host
/// app, matching the native implementations where channel exceptions are
/// swallowed per method.
class PosthogFlutterDart extends PosthogFlutterPlatformInterface {
  pd.PostHog? _client;

  /// Keeps [isOptOut] consistent before/without a client.
  bool _optedOut = false;

  void Function()? _featureFlagsUnsubscribe;

  /// Registered as the platform instance via dartPluginClass on desktop.
  static void registerWith() {
    PosthogFlutterPlatformInterface.instance = PosthogFlutterDart();
  }

  Future<void> _guard(String op, FutureOr<void> Function() fn) async {
    try {
      await fn();
    } catch (e) {
      printIfDebug('[PostHog] Exception on $op: $e');
    }
  }

  Future<T> _guardWith<T>(
      String op, T fallback, FutureOr<T> Function() fn) async {
    try {
      return await fn();
    } catch (e) {
      printIfDebug('[PostHog] Exception on $op: $e');
      return fallback;
    }
  }

  @override
  Future<void> setup(PostHogConfig config) => _guard('setup', () async {
        _optedOut = config.optOut;

        // Collected before the client exists so no event captured through
        // this instance goes out without device/app context; the await only
        // reads local platform metadata, so setup stays fast.
        final staticContext = await collectDesktopContext();

        final client = DesktopPostHog(
          config.projectToken,
          staticContext: staticContext,
          options: pd.PostHogConfig(
            host: config.host,
            flushAt: config.flushAt,
            flushInterval: config.flushInterval,
            maxBatchSize: config.maxBatchSize,
            maxQueueSize: config.maxQueueSize,
            debug: config.debug,
            optOut: config.optOut,
            sendFeatureFlagEvents: config.sendFeatureFlagEvents,
            preloadFeatureFlags: config.preloadFeatureFlags,
            personProfiles: _mapPersonProfiles(config.personProfiles),
            beforeSend: _bridgeBeforeSend(config.beforeSend),
          ),
          storage: pd.FileStorage(_resolveStorageDir(config.projectToken)),
        );
        _client = client;

        if (config.onFeatureFlags != null) {
          _featureFlagsUnsubscribe =
              client.onFeatureFlags((_) => config.onFeatureFlags?.call());
        }

        // posthog_dart does not preload flags itself; the guarded reload is
        // used because the raw client future rejects with nobody listening.
        if (config.preloadFeatureFlags) {
          // ignore: unawaited_futures
          reloadFeatureFlags();
        }
      });

  @override
  Future<void> identify({
    required String userId,
    Map<String, Object>? userProperties,
    Map<String, Object>? userPropertiesSetOnce,
  }) =>
      _guard('identify', () {
        _client?.identify(
          userId,
          properties:
              _mergeUserProps(null, userProperties, userPropertiesSetOnce),
        );
      });

  @override
  Future<void> setPersonProperties({
    Map<String, Object>? userPropertiesToSet,
    Map<String, Object>? userPropertiesToSetOnce,
  }) =>
      _guard('setPersonProperties', () {
        _client?.setPersonProperties(
          userPropertiesToSet: _normalize(userPropertiesToSet),
          userPropertiesToSetOnce: _normalize(userPropertiesToSetOnce),
        );
      });

  @override
  Future<void> capture({
    required String eventName,
    Map<String, Object>? properties,
    Map<String, Object>? userProperties,
    Map<String, Object>? userPropertiesSetOnce,
  }) =>
      _guard('capture', () {
        _client?.capture(
          eventName,
          properties: _mergeUserProps(
            properties,
            userProperties,
            userPropertiesSetOnce,
          ),
        );
      });

  @override
  Future<void> screen({
    required String screenName,
    Map<String, Object>? properties,
  }) =>
      _guard('screen', () {
        _client?.capture(
          r'$screen',
          properties: <String, Object?>{
            r'$screen_name': screenName,
            ...?_normalize(properties),
          },
        );
      });

  @override
  Future<void> alias({required String alias}) =>
      _guard('alias', () => _client?.alias(alias));

  @override
  Future<String> getDistinctId() =>
      _guardWith('getDistinctId', '', () => _client?.getDistinctId() ?? '');

  @override
  Future<void> reset() => _guard('reset', () => _client?.reset());

  @override
  Future<void> disable() => _guard('disable', () {
        _optedOut = true;
        _client?.optOut();
      });

  @override
  Future<void> enable() => _guard('enable', () {
        _optedOut = false;
        _client?.optIn();
      });

  @override
  Future<bool> isOptOut() => _guardWith('isOptOut', _optedOut, () {
        final client = _client;
        if (client == null) return _optedOut;
        return client.optedOut;
      });

  @override
  Future<void> debug(bool enabled) =>
      _guard('debug', () => _client?.debug(enabled));

  @override
  Future<void> register(String key, Object value) => _guard('register',
      () => _client?.register(PropertyNormalizer.normalize({key: value})));

  @override
  Future<void> unregister(String key) =>
      _guard('unregister', () => _client?.unregister(key));

  @override
  Future<bool> isFeatureEnabled(String key) => _guardWith(
      'isFeatureEnabled', false, () => _client?.isFeatureEnabled(key) ?? false);

  @override
  Future<void> reloadFeatureFlags() => _guard(
      'reloadFeatureFlags', () async => _client?.reloadFeatureFlagsAsync());

  @override
  Future<void> group({
    required String groupType,
    required String groupKey,
    Map<String, Object>? groupProperties,
  }) =>
      _guard('group', () {
        _client?.group(
          groupType,
          groupKey,
          groupProperties: _normalize(groupProperties),
        );
      });

  @override
  Future<Object?> getFeatureFlag({required String key}) =>
      _guardWith<Object?>(
          'getFeatureFlag', null, () => _client?.getFeatureFlag(key));

  @override
  Future<Object?> getFeatureFlagPayload({required String key}) =>
      _guardWith('getFeatureFlagPayload', null, () {
        final result = _client?.getFeatureFlagResult(
          key,
          options: const pd.PostHogFeatureFlagResultOptions(sendEvent: false),
        );
        return result?.payload;
      });

  @override
  Future<PostHogFeatureFlagResult?> getFeatureFlagResult({
    required String key,
    bool sendEvent = true,
  }) =>
      _guardWith('getFeatureFlagResult', null, () {
        final result = _client?.getFeatureFlagResult(
          key,
          options: pd.PostHogFeatureFlagResultOptions(sendEvent: sendEvent),
        );
        if (result == null) return null;
        return PostHogFeatureFlagResult(
          key: key,
          enabled: result.enabled,
          variant: result.variant,
          payload: result.payload,
        );
      });

  @override
  Future<void> flush() => _guard('flush', () async => _client?.flush());

  @override
  Future<void> captureException({
    required Object error,
    StackTrace? stackTrace,
    Map<String, Object>? properties,
  }) =>
      _guard('captureException', () {
        // No structured stack trace parsing on desktop - best effort.
        _client?.capture(
          r'$exception',
          properties: <String, Object?>{
            r'$exception_message': error.toString(),
            if (stackTrace != null)
              r'$exception_stack_trace_raw': stackTrace.toString(),
            ...?_normalize(properties),
          },
        );
      });

  @override
  Future<void> close() => _guard('close', () async {
        _featureFlagsUnsubscribe?.call();
        _featureFlagsUnsubscribe = null;
        final client = _client;
        _client = null;
        await client?.shutdown();
      });

  @override
  Future<String?> getSessionId() => _guardWith('getSessionId', null, () {
        final id = _client?.getSessionId();
        return (id == null || id.isEmpty) ? null : id;
      });

  @override
  Future<void> openUrl(String url) async {
    // Surveys/native UI only - not supported on desktop.
  }

  @override
  Future<void> showSurvey(Map<String, dynamic> survey) async {
    // Surveys are not supported on desktop.
  }

  @override
  Future<void> startSessionRecording({bool resumeCurrent = true}) async {
    // Session replay is not supported on desktop.
  }

  @override
  Future<void> stopSessionRecording() async {
    // Session replay is not supported on desktop.
  }

  @override
  Future<bool> isSessionReplayActive() async => false;

  Map<String, Object?>? _mergeUserProps(
    Map<String, Object>? properties,
    Map<String, Object>? userProperties,
    Map<String, Object>? userPropertiesSetOnce,
  ) {
    final set = _normalize(userProperties);
    final setOnce = _normalize(userPropertiesSetOnce);
    final merged = <String, Object?>{
      ...?_normalize(properties),
      if (set != null && set.isNotEmpty) r'$set': set,
      if (setOnce != null && setOnce.isNotEmpty) r'$set_once': setOnce,
    };
    return merged.isNotEmpty ? merged : null;
  }

  /// Same normalization the native path applies before the method channel;
  /// here it protects jsonEncode in storage and /batch/ payloads.
  Map<String, Object>? _normalize(Map<String, Object>? properties) {
    if (properties == null || properties.isEmpty) return properties;
    return Map<String, Object>.from(PropertyNormalizer.normalize(properties));
  }

  pd.PostHogPersonProfiles _mapPersonProfiles(PostHogPersonProfiles value) {
    switch (value) {
      case PostHogPersonProfiles.never:
        return pd.PostHogPersonProfiles.never;
      case PostHogPersonProfiles.always:
        return pd.PostHogPersonProfiles.always;
      case PostHogPersonProfiles.identifiedOnly:
        return pd.PostHogPersonProfiles.identifiedOnly;
    }
  }

  /// Bridges beforeSend callbacks: the event is converted to the flutter
  /// shape, run through the user callbacks and copied back into the pd event
  /// (preserving uuid/timestamp, absent from the flutter shape).
  List<pd.BeforeSendCallback>? _bridgeBeforeSend(
    List<BeforeSendCallback> callbacks,
  ) {
    if (callbacks.isEmpty) return null;

    return [
      (pd.PostHogEvent pdEvent) async {
        var flutterEvent = PostHogEvent(
          event: pdEvent.event,
          properties: pdEvent.properties,
          userProperties: pdEvent.userProperties,
          userPropertiesSetOnce: pdEvent.userPropertiesSetOnce,
        );

        for (final callback in callbacks) {
          try {
            final result = callback(flutterEvent);
            final resolved =
                result is Future<PostHogEvent?> ? await result : result;
            if (resolved == null) return null;
            flutterEvent = resolved;
          } catch (e) {
            // Contract: a throwing callback is skipped, the chain continues.
            printIfDebug('[PostHog] beforeSend callback threw exception: $e');
          }
        }

        pdEvent
          ..event = flutterEvent.event
          ..properties = _normalize(flutterEvent.properties)
          ..userProperties = _normalize(flutterEvent.userProperties)
          ..userPropertiesSetOnce =
              _normalize(flutterEvent.userPropertiesSetOnce);
        return pdEvent;
      },
    ];
  }

  /// Storage directory without path_provider: APPDATA (Windows),
  /// XDG_DATA_HOME / ~/.local/share (Linux), systemTemp as a last resort.
  ///
  /// Scoped per project token - a shared directory would mix distinct_id,
  /// consent and queued events between apps and projects.
  String _resolveStorageDir(String projectToken) {
    final env = Platform.environment;
    String? base;
    if (Platform.isWindows) {
      base = env['APPDATA'] ?? env['LOCALAPPDATA'];
    } else {
      base = env['XDG_DATA_HOME'];
      if (base == null || base.isEmpty) {
        final home = env['HOME'];
        if (home != null && home.isNotEmpty) {
          base = '$home/.local/share';
        }
      }
    }

    final sep = Platform.pathSeparator;
    var scope = projectToken.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (scope.isEmpty || scope == '.' || scope == '..') {
      scope = 'default';
    }
    // FileStorage creates the directory itself; every fallback must stay
    // scoped or it reopens the shared cross-project store.
    final base0 = (base != null && base.isNotEmpty)
        ? base
        : Directory.systemTemp.path;
    return '$base0${sep}posthog$sep$scope';
  }
}
