import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:posthog_flutter/src/posthog_desktop_context.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('collects app, os and locale context', () async {
    PackageInfo.setMockInitialValues(
      appName: 'TestApp',
      packageName: 'com.test.app',
      version: '1.2.3',
      buildNumber: '42',
      buildSignature: '',
      installerStore: null,
    );

    final context = await collectDesktopContext();

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
}
