import 'dart:io';
import 'dart:ui';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:posthog_dart/posthog_dart.dart' as pd;

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
}

/// Collects static device/app context for desktop events, using the same
/// property names the native mobile SDKs attach.
Future<Map<String, Object?>> collectDesktopContext() async {
  final context = <String, Object?>{
    r'$os_name': _osName(),
    r'$os_version': Platform.operatingSystemVersion,
    r'$locale': _locale(),
    r'$device_type': 'Desktop',
    ..._screenInfo(),
  };

  try {
    final info = await PackageInfo.fromPlatform();
    context.addAll({
      r'$app_name': info.appName,
      r'$app_version': info.version,
      r'$app_build': info.buildNumber,
      r'$app_namespace': info.packageName,
    });
  } catch (e) {
    // Reads local platform metadata only; a failure must not lose the rest
    // of the context or break setup.
    printIfDebug('[PostHog] Could not read package info: $e');
  }

  return context;
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

/// BCP-47 tag ("en-US") like the Android and web SDKs; the POSIX codeset
/// suffix Linux appends ("en_US.UTF-8") is stripped.
String _locale() {
  return Platform.localeName.split('.').first.split('@').first.replaceAll('_', '-');
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
