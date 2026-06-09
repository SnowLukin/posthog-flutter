import 'dart:async';
import 'dart:io';

import 'package:posthog_dart/posthog_dart.dart' as pd;

import 'src/feature_flag_result.dart';
import 'src/posthog_config.dart';
import 'src/posthog_event.dart';
import 'src/posthog_flutter_platform_interface.dart';

/// Реализация плагина под desktop (Windows/Linux) поверх pure-Dart posthog_dart.
///
/// На этих платформах нет нативного PostHog SDK, поэтому весь интерфейс
/// делегируется в [pd.PostHog]. Типы posthog_flutter мостятся на типы
/// posthog_dart на границе методов.
class PosthogFlutterDart extends PosthogFlutterPlatformInterface {
  pd.PostHog? _client;

  /// Хранится для случая, когда у pd нет init-флага: opt-out, выставленный после
  /// setup, нужно где-то держать, чтобы [isOptOut] отвечал согласованно.
  bool _optedOut = false;

  /// Отписка от onFeatureFlags, чтобы при [close] не остался висящий listener.
  void Function()? _featureFlagsUnsubscribe;

  /// Регистрирует реализацию как platform instance (dartPluginClass для desktop).
  static void registerWith() {
    PosthogFlutterPlatformInterface.instance = PosthogFlutterDart();
  }

  @override
  Future<void> setup(PostHogConfig config) async {
    _optedOut = config.optOut;

    final client = pd.PostHog(
      config.projectToken,
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
      storage: pd.FileStorage(_resolveStorageDir()),
    );
    _client = client;

    if (config.onFeatureFlags != null) {
      _featureFlagsUnsubscribe =
          client.onFeatureFlags((_) => config.onFeatureFlags?.call());
    }
  }

  @override
  Future<void> identify({
    required String userId,
    Map<String, Object>? userProperties,
    Map<String, Object>? userPropertiesSetOnce,
  }) async {
    final properties = <String, Object?>{
      if (userProperties != null && userProperties.isNotEmpty)
        r'$set': userProperties,
      if (userPropertiesSetOnce != null && userPropertiesSetOnce.isNotEmpty)
        r'$set_once': userPropertiesSetOnce,
    };
    _client?.identify(
      userId,
      properties: properties.isNotEmpty ? properties : null,
    );
  }

  @override
  Future<void> setPersonProperties({
    Map<String, Object>? userPropertiesToSet,
    Map<String, Object>? userPropertiesToSetOnce,
  }) async {
    _client?.setPersonProperties(
      userPropertiesToSet: userPropertiesToSet,
      userPropertiesToSetOnce: userPropertiesToSetOnce,
    );
  }

  @override
  Future<void> capture({
    required String eventName,
    Map<String, Object>? properties,
    Map<String, Object>? userProperties,
    Map<String, Object>? userPropertiesSetOnce,
  }) async {
    _client?.capture(
      eventName,
      properties: _mergeUserProps(
        properties,
        userProperties,
        userPropertiesSetOnce,
      ),
    );
  }

  @override
  Future<void> screen({
    required String screenName,
    Map<String, Object>? properties,
  }) async {
    _client?.capture(
      r'$screen',
      properties: <String, Object?>{
        r'$screen_name': screenName,
        ...?properties,
      },
    );
  }

  @override
  Future<void> alias({required String alias}) async {
    _client?.alias(alias);
  }

  @override
  Future<String> getDistinctId() async {
    return _client?.getDistinctId() ?? '';
  }

  @override
  Future<void> reset() async {
    _client?.reset();
  }

  @override
  Future<void> disable() async {
    _optedOut = true;
    _client?.optOut();
  }

  @override
  Future<void> enable() async {
    _optedOut = false;
    _client?.optIn();
  }

  @override
  Future<bool> isOptOut() async {
    final client = _client;
    if (client == null) return _optedOut;
    return client.optedOut;
  }

  @override
  Future<void> debug(bool enabled) async {
    // Режим debug фиксируется в конфиге при setup; рантайм-переключение
    // намеренно no-op, чтобы поведение совпадало с нативными платформами.
  }

  @override
  Future<void> register(String key, Object value) async {
    _client?.register({key: value});
  }

  @override
  Future<void> unregister(String key) async {
    _client?.unregister(key);
  }

  @override
  Future<bool> isFeatureEnabled(String key) async {
    return _client?.isFeatureEnabled(key) ?? false;
  }

  @override
  Future<void> reloadFeatureFlags() async {
    await _client?.reloadFeatureFlagsAsync();
  }

  @override
  Future<void> group({
    required String groupType,
    required String groupKey,
    Map<String, Object>? groupProperties,
  }) async {
    _client?.group(
      groupType,
      groupKey,
      groupProperties: groupProperties,
    );
  }

  @override
  Future<Object?> getFeatureFlag({required String key}) async {
    return _client?.getFeatureFlag(key);
  }

  @override
  Future<Object?> getFeatureFlagPayload({required String key}) async {
    final result = _client?.getFeatureFlagResult(
      key,
      options: const pd.PostHogFeatureFlagResultOptions(sendEvent: false),
    );
    return result?.payload;
  }

  @override
  Future<PostHogFeatureFlagResult?> getFeatureFlagResult({
    required String key,
    bool sendEvent = true,
  }) async {
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
  }

  @override
  Future<void> flush() async {
    await _client?.flush();
  }

  @override
  Future<void> captureException({
    required Object error,
    StackTrace? stackTrace,
    Map<String, Object>? properties,
  }) async {
    // Desktop не делает структурный разбор стектрейса (как нативный error
    // tracking) — отправляем best-effort событие с тем, что есть.
    _client?.capture(
      r'$exception',
      properties: <String, Object?>{
        r'$exception_message': error.toString(),
        if (stackTrace != null) r'$exception_stack_trace_raw': stackTrace.toString(),
        ...?properties,
      },
    );
  }

  @override
  Future<void> close() async {
    _featureFlagsUnsubscribe?.call();
    _featureFlagsUnsubscribe = null;
    final client = _client;
    _client = null;
    await client?.shutdown();
  }

  @override
  Future<String?> getSessionId() async {
    final id = _client?.getSessionId();
    return (id == null || id.isEmpty) ? null : id;
  }

  @override
  Future<void> openUrl(String url) async {
    // Открытие URL — задача surveys/native UI, на desktop не поддерживается.
  }

  @override
  Future<void> showSurvey(Map<String, dynamic> survey) async {
    // Surveys на desktop не поддерживаются.
  }

  @override
  Future<void> startSessionRecording({bool resumeCurrent = true}) async {
    // Session replay на desktop не поддерживается.
  }

  @override
  Future<void> stopSessionRecording() async {
    // Session replay на desktop не поддерживается.
  }

  @override
  Future<bool> isSessionReplayActive() async => false;

  Map<String, Object?>? _mergeUserProps(
    Map<String, Object>? properties,
    Map<String, Object>? userProperties,
    Map<String, Object>? userPropertiesSetOnce,
  ) {
    final merged = <String, Object?>{
      ...?properties,
      if (userProperties != null && userProperties.isNotEmpty)
        r'$set': userProperties,
      if (userPropertiesSetOnce != null && userPropertiesSetOnce.isNotEmpty)
        r'$set_once': userPropertiesSetOnce,
    };
    return merged.isNotEmpty ? merged : null;
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

  /// Мостит beforeSend-колбэки posthog_flutter в формат posthog_dart.
  ///
  /// Типы [PostHogEvent] в двух пакетах разные, поэтому событие конвертируется
  /// в flutter-форму, прогоняется через пользовательские колбэки и копируется
  /// обратно в исходный pd-event (сохраняя uuid/timestamp, которых нет во
  /// flutter-форме).
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
          final result = callback(flutterEvent);
          final resolved =
              result is Future<PostHogEvent?> ? await result : result;
          if (resolved == null) return null;
          flutterEvent = resolved;
        }

        pdEvent
          ..event = flutterEvent.event
          ..properties = flutterEvent.properties
          ..userProperties = flutterEvent.userProperties
          ..userPropertiesSetOnce = flutterEvent.userPropertiesSetOnce;
        return pdEvent;
      },
    ];
  }

  /// Каталог для FileStorage без path_provider — на уровне библиотеки путь
  /// резолвится из env. Windows: APPDATA (fallback LOCALAPPDATA);
  /// Linux: XDG_DATA_HOME (fallback ~/.local/share). При неудаче — systemTemp.
  String _resolveStorageDir() {
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

    final root = (base != null && base.isNotEmpty)
        ? Directory('$base${Platform.pathSeparator}posthog')
        : Directory('${Directory.systemTemp.path}'
            '${Platform.pathSeparator}posthog');

    try {
      if (!root.existsSync()) {
        root.createSync(recursive: true);
      }
      return root.path;
    } catch (_) {
      return Directory.systemTemp.path;
    }
  }
}
