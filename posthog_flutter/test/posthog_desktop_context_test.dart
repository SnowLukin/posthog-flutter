import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:posthog_flutter/src/posthog_config.dart';
import 'package:posthog_flutter/src/posthog_desktop_context.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('collectDesktopContext', () {
    test('collects app, os and locale context', () {
      final desktopConfig = PostHogDesktopConfig()
        ..appName = 'TestApp'
        ..appVersion = '1.2.3'
        ..appBuild = '42'
        ..appNamespace = 'com.test.app';

      final context = collectDesktopContext(desktopConfig);

      expect(context[r'$app_name'], 'TestApp');
      expect(context[r'$app_version'], '1.2.3');
      expect(context[r'$app_build'], '42');
      expect(context[r'$app_namespace'], 'com.test.app');
      expect(context[r'$device_type'], 'Desktop');
      // Host-dependent values: only their shape is stable across runners.
      expect(context[r'$os_name'], isA<String>());
      expect(context[r'$os_name'], isNot(equals('')));
      expect(context[r'$os_version'], isA<String>());

      final locale = context[r'$locale']! as String;
      expect(locale, isNot(contains('_')));
      expect(locale, isNot(contains('.')));
      expect(locale, isNot(contains('@')));
    });

    test('falls back to the executable name when no app name is set', () {
      final context = collectDesktopContext(PostHogDesktopConfig());

      final executable =
          Platform.resolvedExecutable.split(Platform.pathSeparator).last;
      final dot = executable.lastIndexOf('.');
      final expectedName = dot > 0 ? executable.substring(0, dot) : executable;
      expect(context[r'$app_name'], expectedName);
    });

    test('omits unset app metadata instead of guessing', () {
      final context = collectDesktopContext(PostHogDesktopConfig());

      expect(context.containsKey(r'$app_version'), isFalse);
      expect(context.containsKey(r'$app_build'), isFalse);
      expect(context.containsKey(r'$app_namespace'), isFalse);
    });

    test('reports a proper-cased operating system name', () {
      final context = collectDesktopContext(PostHogDesktopConfig());

      // Test hosts are limited to the desktop platforms CI runs on.
      expect(context[r'$os_name'], anyOf('Windows', 'Linux', 'macOS'));
    });
  });

  group('extractOsVersion', () {
    const versionByBanner = <String, String>{
      '"Windows 10 Pro" 10.0 (Build 19043)': '10.0.19043',
      'Version 14.5 (Build 23F79)': '14.5',
      'Linux 5.11.0-1018-gcp #20~20.04.1-Ubuntu SMP Fri Sep 3 01:01:37 '
          'UTC 2021': '5.11.0',
    };

    versionByBanner.forEach((banner, version) {
      test('extracts $version from $banner', () {
        expect(extractOsVersion(banner), version);
      });
    });

    test('returns a banner with no recognizable version unchanged', () {
      expect(extractOsVersion('unknown os'), 'unknown os');
    });
  });
}
