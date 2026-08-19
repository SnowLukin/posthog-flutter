import 'dart:async';
import 'dart:io';

import 'package:posthog_dart/posthog_dart.dart' as pd;

import 'src/error_tracking/dart_exception_processor.dart';
import 'src/feature_flag_result.dart';
import 'src/logs/posthog_log_severity.dart';
import 'src/posthog_config.dart';
import 'src/posthog_constants.dart';
import 'src/posthog_desktop_context.dart';
import 'src/posthog_event.dart';
import 'src/posthog_flutter_platform_interface.dart';
import 'src/util/logging.dart';
import 'src/utils/before_send.dart';
import 'src/utils/capture_utils.dart';
import 'src/utils/property_normalizer.dart';

/// Desktop (Windows/Linux) implementation on top of the pure-Dart
/// posthog_dart package, bridging the plugin types at method boundaries.
///
/// Every method is wrapped in a guard: analytics never throws into the host
/// app, matching the native implementations where channel exceptions are
/// swallowed per method.
class PosthogFlutterDart extends PosthogFlutterPlatformInterface {
  DesktopPostHog? _client;

  /// Keeps [isOptOut] consistent before/without a client.
  bool _optedOut = false;

  /// Stored at setup for exception processing and the beforeSend pipeline.
  PostHogConfig? _config;

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
        // A repeated setup() replaces the client: release the previous one
        // first (the same teardown close() performs) so its flush timer and
        // flags subscription cannot outlive it.
        _featureFlagsUnsubscribe?.call();
        _featureFlagsUnsubscribe = null;
        final previous = _client;
        _client = null;
        await previous?.shutdown();

        _config = config;
        _optedOut = config.optOut;

        // Collected before the client exists so no event captured through
        // this instance goes out without device/app context.
        final staticContext = collectDesktopContext(config.desktopConfig);

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
          ),
          storage: pd.FileStorage(_resolveStorageDir(config)),
        );
        _client = client;

        if (config.onFeatureFlags != null) {
          _featureFlagsUnsubscribe =
              client.onFeatureFlags((_) => config.onFeatureFlags?.call());
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
      _guard('capture', () async {
        final client = _client;
        if (client == null) return;

        final processed = await _runBeforeSend(
          eventName,
          properties,
          userProperties: userProperties,
          userPropertiesSetOnce: userPropertiesSetOnce,
        );
        if (processed == null) {
          printIfDebug('[PostHog] Event dropped by beforeSend: $eventName');
          return;
        }

        client.capture(
          processed.event,
          properties: _mergeUserProps(
            processed.properties,
            processed.userProperties,
            processed.userPropertiesSetOnce,
          ),
        );
      });

  @override
  Future<void> screen({
    required String screenName,
    Map<String, Object>? properties,
  }) =>
      _guard('screen', () async {
        final client = _client;
        if (client == null) return;

        final processed = await _runBeforeSend(
          PostHogEventName.screen,
          <String, Object>{
            PostHogPropertyName.screenName: screenName,
            ...?properties,
          },
        );
        if (processed == null) {
          printIfDebug(
              '[PostHog] Screen event dropped by beforeSend: $screenName');
          return;
        }

        // A renamed event is no longer a screen view - capture it as a
        // regular event, like the method-channel implementation does.
        if (processed.event != PostHogEventName.screen) {
          await capture(
            eventName: processed.event,
            properties: processed.properties,
          );
          return;
        }

        // Like the io path, the screen name is re-added out of band so a
        // beforeSend that rebuilds the property map cannot lose it.
        final finalScreenName =
            processed.properties?[PostHogPropertyName.screenName] as String? ??
                screenName;
        client.capture(
          PostHogEventName.screen,
          properties: <String, Object?>{
            ...?_normalize(processed.properties),
            PostHogPropertyName.screenName: finalScreenName,
          },
        );
      });

  /// Structured logs are not supported on the desktop implementation.
  @override
  Future<void> captureLog({
    required String body,
    PostHogLogSeverity level = PostHogLogSeverity.info,
    Map<String, Object>? attributes,
    String? traceId,
    String? spanId,
    int? traceFlags,
  }) async {}

  @override
  Future<void> registerPushNotificationToken(
    String deviceToken, {
    String? appId,
  }) async {
    // Push notifications are not supported on desktop.
  }

  @override
  Future<void> unregisterPushNotificationToken() async {
    // Push notifications are not supported on desktop.
  }

  @override
  Future<void> capturePushNotificationOpened({
    String? title,
    String? subtitle,
    String? body,
    Map<String, Object?>? payload,
    String? action,
  }) async {
    // Push notifications are not supported on desktop.
  }

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
  Future<void> setPersonPropertiesForFlags(
    Map<String, Object> userProperties,
  ) =>
      _guard('setPersonPropertiesForFlags', () {
        // The facade issues the flags reload itself, as on the other
        // platforms - reloading here as well would double the request.
        _client?.setPersonPropertiesForFlags(
          _normalize(userProperties) ?? const {},
          reloadFlags: false,
        );
      });

  @override
  Future<void> resetPersonPropertiesForFlags() => _guard(
      'resetPersonPropertiesForFlags',
      () => _client?.resetPersonPropertiesForFlags());

  @override
  Future<void> setGroupPropertiesForFlags(
    String groupType,
    Map<String, Object> groupProperties,
  ) =>
      _guard('setGroupPropertiesForFlags', () {
        final normalized = _normalize(groupProperties) ?? const {};
        _client?.setGroupPropertiesForFlags({groupType: normalized});
      });

  @override
  Future<void> resetGroupPropertiesForFlags({String? groupType}) =>
      _guard('resetGroupPropertiesForFlags', () {
        if (groupType != null) {
          _client?.resetGroupPropertiesForFlagsOfType(groupType);
        } else {
          _client?.resetGroupPropertiesForFlags();
        }
      });

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
  Future<Object?> getFeatureFlag({required String key}) => _guardWith<Object?>(
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
      _guard('captureException', () async {
        final client = _client;
        if (client == null) return;

        final exceptionProps = DartExceptionProcessor.processException(
          error: error,
          stackTrace: stackTrace,
          properties: properties,
          inAppIncludes: _config?.errorTrackingConfig.inAppIncludes,
          inAppExcludes: _config?.errorTrackingConfig.inAppExcludes,
          inAppByDefault: _config?.errorTrackingConfig.inAppByDefault ?? true,
        );

        final processed = await _runBeforeSend(
          PostHogEventName.exception,
          exceptionProps.cast<String, Object>(),
        );
        if (processed == null) {
          printIfDebug(
            '[PostHog] Exception event dropped by beforeSend: ${error.runtimeType}',
          );
          return;
        }

        // A renamed event is no longer an exception - capture it as a
        // regular event, like the method-channel implementation does.
        if (processed.event != PostHogEventName.exception) {
          await capture(
            eventName: processed.event,
            properties: processed.properties,
          );
          return;
        }

        client.capture(
          PostHogEventName.exception,
          properties: _normalize(processed.properties),
        );
      });

  /// Exception steps are not supported on the desktop implementation.
  @override
  Future<void> addExceptionStep(
    String message, {
    Map<String, Object>? properties,
  }) async {}

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

  /// Applies the beforeSend callbacks to an event in order, mirroring the
  /// method-channel platforms: running them here rather than inside
  /// posthog_dart keeps SDK-internal events ($identify, $feature_flag_called,
  /// ...) and SDK-enriched properties out of the callbacks' sight.
  ///
  /// Returns the possibly modified event, or null if any callback drops it.
  Future<PostHogEvent?> _runBeforeSend(
    String eventName,
    Map<String, Object>? properties, {
    Map<String, Object>? userProperties,
    Map<String, Object>? userPropertiesSetOnce,
  }) async {
    var event = PostHogEvent(
      event: eventName,
      properties: properties,
      userProperties: userProperties,
      userPropertiesSetOnce: userPropertiesSetOnce,
    );

    final callbacks = _config?.beforeSend ?? const <BeforeSendCallback>[];
    for (final callback in callbacks) {
      try {
        final result = await runBeforeSend<PostHogEvent>(callback, event);
        if (result == null) return null;
        event = result;
      } catch (e) {
        // Skip a throwing callback; continue with the pre-callback event.
        printIfDebug('[PostHog] beforeSend callback threw exception: $e');
      }
    }
    return event;
  }

  Map<String, Object?>? _mergeUserProps(
    Map<String, Object>? properties,
    Map<String, Object>? userProperties,
    Map<String, Object>? userPropertiesSetOnce,
  ) {
    // Inline $set/$set_once in properties are legacy but still honored on
    // the channel platforms; merge them the same way here, with the explicit
    // parameters winning per key.
    final extracted = CaptureUtils.extractUserProperties(
      properties: properties,
      userProperties: userProperties,
      userPropertiesSetOnce: userPropertiesSetOnce,
    );

    final set = _normalize(extracted.userProperties);
    final setOnce = _normalize(extracted.userPropertiesSetOnce);
    final merged = <String, Object?>{
      ...?_normalize(extracted.properties),
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

  /// Storage directory without path_provider: APPDATA (Windows),
  /// XDG_DATA_HOME / ~/.local/share (Linux), systemTemp as a last resort.
  ///
  /// Scoped per app and per project token - a shared directory would mix
  /// distinct_id, consent and queued events between apps and projects.
  String _resolveStorageDir(PostHogConfig config) {
    final sep = Platform.pathSeparator;
    final tokenScope = _directoryScope(config.projectToken);

    final override = config.desktopConfig.storageDirectory;
    if (override != null && override.isNotEmpty) {
      return '$override$sep$tokenScope';
    }

    final appScope = _directoryScope(config.desktopConfig.appNamespace ??
        Platform.resolvedExecutable.split(sep).last);

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
    if (base == null || base.isEmpty) {
      // FileStorage creates the directory itself; the fallback must stay
      // scoped or it reopens the shared cross-project store.
      base = Directory.systemTemp.path;
      printIfDebug(
          '[PostHog] No application data directory found; persisting events '
          'under $base, which the OS may clear at any time.');
    }
    return '$base${sep}posthog$sep$appScope$sep$tokenScope';
  }

  String _directoryScope(String value) {
    final scope = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (scope.isEmpty || scope == '.' || scope == '..') return 'default';
    return scope;
  }
}
