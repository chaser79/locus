import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'doctor activity opt-out matches setup activity opt-out',
    () async {
      final project =
          await Directory.systemTemp.createTemp('locus_doctor_test_');
      addTearDown(() => project.delete(recursive: true));

      final manifest = File(
        '${project.path}/android/app/src/main/AndroidManifest.xml',
      );
      await manifest.parent.create(recursive: true);
      await manifest.writeAsString('''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
  <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
  <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
  <uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION" />
  <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
  <uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION" />
</manifest>
''');
      final gradle = File('${project.path}/android/app/build.gradle');
      await gradle.writeAsString('android { defaultConfig { minSdk = 26 } }');

      final plist = File('${project.path}/ios/Runner/Info.plist');
      await plist.parent.create(recursive: true);
      await plist.writeAsString('''
<plist version="1.0">
<dict>
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>Location</string>
  <key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
  <string>Background location</string>
  <key>UIBackgroundModes</key>
  <array><string>location</string></array>
</dict>
</plist>
''');
      await File('${project.path}/ios/Podfile').writeAsString('''
platform :ios, '14.0'
post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
    target.build_configurations.each do |config|
      definitions = config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= []
      definitions << 'PERMISSION_LOCATION=1'
    end
  end
end
''');
      await File('${project.path}/pubspec.yaml').writeAsString('''
name: host_app
dependencies:
  locus: any
''');

      // The parent `flutter test` process owns Flutter's startup lock. Doctor
      // only needs a version string here, so keep the subprocess deterministic
      // and avoid recursively starting the real Flutter tool.
      final fakeBin = Directory('${project.path}/test-bin');
      await fakeBin.create();
      if (Platform.isWindows) {
        await File('${fakeBin.path}/flutter.bat').writeAsString(
          '@echo Flutter 3.44.1 • channel stable\r\n',
        );
      } else {
        final fakeFlutter = File('${fakeBin.path}/flutter');
        await fakeFlutter.writeAsString(
          '#!/bin/sh\nprintf "Flutter 3.44.1 • channel stable\\n"\n',
        );
        final chmod = await Process.run('chmod', ['+x', fakeFlutter.path]);
        expect(chmod.exitCode, 0, reason: chmod.stderr.toString());
      }
      final childEnvironment = <String, String>{
        'PATH': [
          fakeBin.path,
          Platform.environment['PATH'] ?? '',
        ].join(Platform.isWindows ? ';' : ':'),
      };

      final script = '${Directory.current.path}/bin/doctor.dart';
      final dart = _dartExecutableWithoutFlutterToolLock();
      final optedOut = await Process.run(
        dart,
        [script, '--no-activity'],
        workingDirectory: project.path,
        environment: childEnvironment,
      );
      final defaultCheck = await Process.run(
        dart,
        [script],
        workingDirectory: project.path,
        environment: childEnvironment,
      );

      expect(optedOut.exitCode, 0, reason: optedOut.stdout.toString());
      expect(
        optedOut.stdout,
        isNot(contains('ACTIVITY_RECOGNITION permission')),
      );
      expect(optedOut.stdout, isNot(contains('NSMotionUsageDescription')));
      expect(defaultCheck.exitCode, 1);
      expect(defaultCheck.stdout, contains('ACTIVITY_RECOGNITION permission'));
      expect(defaultCheck.stdout, contains('NSMotionUsageDescription'));
    },
  );
}

String _dartExecutableWithoutFlutterToolLock() {
  final resolved = File(Platform.resolvedExecutable);
  final executableName = Platform.isWindows ? 'dart.exe' : 'dart';
  if (resolved.uri.pathSegments.last == executableName) {
    return resolved.path;
  }

  // Under `flutter test`, resolvedExecutable is `flutter_tester`. Calling the
  // Flutter SDK's bin/dart wrapper from that process would wait on the startup
  // lock held by the parent test, so invoke the cached Dart binary directly.
  var directory = resolved.parent;
  while (directory.parent.path != directory.path) {
    final candidate = File(
      '${directory.path}/dart-sdk/bin/$executableName',
    );
    if (candidate.existsSync()) return candidate.path;
    directory = directory.parent;
  }
  throw StateError('Unable to locate the Dart SDK executable');
}
