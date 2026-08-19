import 'dart:io';
import 'dart:ui';

import 'package:posthog_dart/posthog_dart.dart' as pd;

import 'posthog_config.dart';
import 'posthog_flutter_version.dart';
import 'util/logging.dart';

/// PostHog client for desktop (Windows/Linux) that attaches the static
/// context collected at setup to every event.
///
/// The context is held per instance and never persisted, so each setup()
/// ships fresh values - an updated $app_version cannot be shadowed by a
/// stale copy from a previous run.
class DesktopPostHog extends pd.PostHog {
  final Map<String, Object?> staticContext;

  DesktopPostHog(
    super.apiKey, {
    required this.staticContext,
    super.options,
    super.storage,
    super.httpClient,
  });

  @override
  Map<String, Object?> getContextProperties() => staticContext;

  /// Default person properties for feature flag evaluation, mirroring the
  /// set the native mobile SDKs send with every /flags request.
  @override
  Map<String, Object?> getDefaultPersonPropertiesForFlags() => {
        for (final key in _flagPersonPropertyKeys)
          if (staticContext.containsKey(key)) key: staticContext[key],
        r'$lib': getLibraryId(),
        r'$lib_version': getLibraryVersion(),
      };

  static const _flagPersonPropertyKeys = [
    r'$app_version',
    r'$app_build',
    r'$app_namespace',
    r'$os_name',
    r'$os_version',
    r'$device_type',
  ];

  /// Clears feature flag evaluation properties for a single group type.
  /// posthog_dart only resets all types at once, so the persisted map is
  /// rewritten without that one entry.
  void resetGroupPropertiesForFlagsOfType(String groupType) {
    wrap(() {
      final existing = getPersistedProperty<Map<String, Object?>>(
          pd.PostHogPersistedProperty.groupProperties);
      if (existing == null || !existing.containsKey(groupType)) return;
      final remaining = {...existing}..remove(groupType);
      setPersistedProperty(pd.PostHogPersistedProperty.groupProperties,
          remaining.isEmpty ? null : remaining);
    });
  }

  // Events report the Flutter SDK identity ($lib/$lib_version), like the
  // mobile platforms where the native SDK is embedded by this plugin.
  @override
  String getLibraryId() => postHogFlutterSdkName;

  @override
  String getLibraryVersion() => postHogFlutterVersion;

  /// PostHog infers the flag evaluation runtime from the request User-Agent:
  /// agents it does not recognize as a client SDK only receive flags whose
  /// runtime is "all", so client-only flags silently vanish from /flags
  /// responses. Present as the Flutter SDK (like the mobile platforms) to be
  /// classified as a client.
  @override
  String? getCustomUserAgent() =>
      '$postHogFlutterSdkName/$postHogFlutterVersion';
}

/// Collects static device/app context for desktop events, using the same
/// property names the native mobile SDKs attach.
///
/// App metadata comes from [PostHogDesktopConfig] - desktop has no manifest
/// the SDK could read it from. Unset values are omitted rather than guessed;
/// only the app name falls back to the executable name.
Map<String, Object?> collectDesktopContext(PostHogDesktopConfig config) {
  return {
    r'$app_name': config.appName ?? _executableName(),
    if (config.appVersion != null) r'$app_version': config.appVersion,
    if (config.appBuild != null) r'$app_build': config.appBuild,
    if (config.appNamespace != null) r'$app_namespace': config.appNamespace,
    r'$os_name': _osName(),
    r'$os_version': extractOsVersion(Platform.operatingSystemVersion),
    r'$locale': _locale(),
    r'$device_type': 'Desktop',
    ..._screenInfo(),
  };
}

/// The executable name without directory or extension ("myapp.exe" ->
/// "myapp") - the only app identity available without configuration.
String _executableName() {
  final name = Platform.resolvedExecutable.split(Platform.pathSeparator).last;
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

/// Proper-cased like the native SDKs report ("Android", "iOS", "macOS").
String _osName() {
  switch (Platform.operatingSystem) {
    case 'windows':
      return 'Windows';
    case 'linux':
      return 'Linux';
    case 'macos':
      return 'macOS';
    default:
      return Platform.operatingSystem;
  }
}

/// Extracts the numeric OS version from a [Platform.operatingSystemVersion]
/// banner ('"Windows 10 Pro" 10.0 (Build 19043)', 'Version 14.5 (Build
/// 23F79)', 'Linux 5.11.0-1018-gcp #20~20.04.1-Ubuntu ...').
///
/// Windows banners fold the build number into the version ('10.0.19043');
/// other banners yield their first dotted number. A banner with nothing that
/// looks like a version is returned unchanged.
String extractOsVersion(String banner) {
  final windows = RegExp(r'(\d+\.\d+)\s+\(Build\s+(\d+)\)').firstMatch(banner);
  if (windows != null) return '${windows[1]}.${windows[2]}';
  return RegExp(r'\d+(\.\d+)+').firstMatch(banner)?[0] ?? banner;
}

/// BCP-47 tag ("en-US") like the Android and web SDKs; the POSIX codeset
/// suffix Linux appends ("en_US.UTF-8") is stripped.
String _locale() {
  return Platform.localeName
      .split('.')
      .first
      .split('@')
      .first
      .replaceAll('_', '-');
}

/// Screen size in logical pixels (the mobile SDKs report dp/points).
///
/// Best effort, read once at setup: when the engine has not reported the
/// implicit view's display yet, the keys are omitted instead of being read
/// lazily, keeping the context immutable for the client's lifetime.
Map<String, Object?> _screenInfo() {
  try {
    final display = PlatformDispatcher.instance.implicitView?.display;
    if (display == null) return {};
    final ratio = display.devicePixelRatio;
    final size = display.size;
    if (ratio <= 0 || size.isEmpty) return {};
    return {
      r'$screen_width': (size.width / ratio).round(),
      r'$screen_height': (size.height / ratio).round(),
      r'$screen_density': ratio,
    };
  } catch (e) {
    // FlutterView.display throws while the view is not attached to one.
    printIfDebug('[PostHog] Could not read display info: $e');
    return {};
  }
}
