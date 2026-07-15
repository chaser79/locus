import 'package:flutter_test/flutter_test.dart';
import 'package:locus/src/cli/ios_permission_macros.dart';

void main() {
  const standardPodfile = '''
post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
  end
end
''';

  test('adds location and sensor definitions idempotently', () {
    final configured = addIosPermissionMacros(
      standardPodfile,
      includeSensors: true,
    );

    expect(configured, isNotNull);
    expect(configured, contains('PERMISSION_LOCATION=1'));
    expect(configured, contains('PERMISSION_SENSORS=1'));
    expect(
      addIosPermissionMacros(configured!, includeSensors: true),
      configured,
    );
  });

  test('activity opt-out adds location only', () {
    final configured = addIosPermissionMacros(
      standardPodfile,
      includeSensors: false,
    )!;

    expect(configured, contains('PERMISSION_LOCATION=1'));
    expect(configured, isNot(contains('PERMISSION_SENSORS=1')));
  });

  test('adds a post-install block when absent', () {
    final configured = addIosPermissionMacros(
      "platform :ios, '14.0'\n",
      includeSensors: true,
    )!;

    expect(configured, contains('post_install do |installer|'));
    expect(
        configured, contains('flutter_additional_ios_build_settings(target)'));
    expect(hasIosPermissionMacros(configured, includeSensors: true), isTrue);
  });

  test('comments and wrong target scope require manual review', () {
    const misleading = '''
# PERMISSION_LOCATION=1
target 'Runner' do
  value = 'PERMISSION_SENSORS=1'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
  end
end
''';

    expect(
      hasIosPermissionMacros(misleading, includeSensors: true),
      isFalse,
    );
    expect(
      addIosPermissionMacros(misleading, includeSensors: true),
      isNull,
    );
  });

  test('normalizes conflicting disabled definitions', () {
    const conflicting = '''
post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
    target.build_configurations.each do |config|
      definitions = config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= []
      definitions << 'PERMISSION_LOCATION=1'
      definitions << 'PERMISSION_LOCATION=0'
      definitions << 'PERMISSION_SENSORS=0'
    end
  end
end
''';

    expect(hasIosPermissionMacros(conflicting, includeSensors: true), isFalse);
    final configured = addIosPermissionMacros(
      conflicting,
      includeSensors: true,
    )!;
    expect(configured, isNot(contains('PERMISSION_LOCATION=0')));
    expect(configured, isNot(contains('PERMISSION_SENSORS=0')));
    expect(hasIosPermissionMacros(configured, includeSensors: true), isTrue);
  });

  test('does not confuse unrelated Ruby block endings with target scope', () {
    const conditionalPodfile = '''
post_install do |installer|
  if ENV['CI']
    puts 'CI build'
  end
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
    target.build_configurations.each do |config|
      definitions = config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= []
      definitions << 'PERMISSION_LOCATION=1'
      definitions << 'PERMISSION_SENSORS=1'
    end
  end
end
''';

    expect(
      hasIosPermissionMacros(conditionalPodfile, includeSensors: true),
      isTrue,
    );
    expect(
      addIosPermissionMacros(conditionalPodfile, includeSensors: true),
      conditionalPodfile,
    );
  });

  test('managed block follows an explicit activity opt-out', () {
    final withActivity = addIosPermissionMacros(
      standardPodfile,
      includeSensors: true,
    )!;
    final withoutActivity = addIosPermissionMacros(
      withActivity,
      includeSensors: false,
    )!;

    expect(withoutActivity, contains('locus:permission-handler-macros:start'));
    expect(withoutActivity, isNot(contains('PERMISSION_SENSORS=1')));
    expect(
      hasIosPermissionMacros(withoutActivity, includeSensors: false),
      isTrue,
    );
    expect(
      hasIosPermissionMacros(withoutActivity, includeSensors: true),
      isFalse,
    );
  });

  test('direct legacy block follows an explicit activity opt-out', () {
    const legacy = '''
post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
    target.build_configurations.each do |config|
      definitions = config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= []
      definitions << 'PERMISSION_LOCATION=1' unless definitions.include?('PERMISSION_LOCATION=1')
      definitions << 'PERMISSION_SENSORS=1' unless definitions.include?('PERMISSION_SENSORS=1')
    end
  end
end
''';

    expect(hasIosPermissionMacros(legacy, includeSensors: false), isFalse);
    final configured = addIosPermissionMacros(
      legacy,
      includeSensors: false,
    )!;

    expect(configured, contains('PERMISSION_LOCATION=1'));
    expect(configured, isNot(contains('PERMISSION_SENSORS=')));
    expect(hasIosPermissionMacros(configured, includeSensors: false), isTrue);
  });

  test('refuses an unless condition that can suppress the macro', () {
    const conditionalAppend = '''
post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
    target.build_configurations.each do |config|
      definitions = config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= []
      definitions << 'PERMISSION_LOCATION=1' unless true
      definitions << 'PERMISSION_SENSORS=1' unless true
    end
  end
end
''';

    expect(
      hasIosPermissionMacros(conditionalAppend, includeSensors: true),
      isFalse,
    );
    expect(
      addIosPermissionMacros(conditionalAppend, includeSensors: true),
      isNull,
    );
  });

  test('refuses a macro block nested in conditional control flow', () {
    const conditionallyScoped = '''
post_install do |installer|
  installer.pods_project.targets.each do |target|
    if ENV['ENABLE_PERMISSIONS']
      target.build_configurations.each do |config|
        definitions = config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= []
        definitions << 'PERMISSION_LOCATION=1'
        definitions << 'PERMISSION_SENSORS=1'
      end
    end
  end
end
''';

    expect(
      hasIosPermissionMacros(conditionallyScoped, includeSensors: true),
      isFalse,
    );
    expect(
      addIosPermissionMacros(conditionallyScoped, includeSensors: true),
      isNull,
    );
  });

  test('refuses conditional macro mutations it cannot safely normalize', () {
    const custom = '''
post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
    target.build_configurations.each do |config|
      definitions = config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= []
      if ENV['DISABLE_LOCATION']
        definitions << 'PERMISSION_LOCATION=0'
      end
    end
  end
end
''';

    expect(hasIosPermissionMacros(custom, includeSensors: false), isFalse);
    expect(addIosPermissionMacros(custom, includeSensors: false), isNull);
  });

  test('managed block does not hide later conflicting macro mutations', () {
    final managed = addIosPermissionMacros(
      standardPodfile,
      includeSensors: true,
    )!;
    final conflicting = '''$managed
definitions << 'PERMISSION_LOCATION=0'
''';

    expect(hasIosPermissionMacros(conflicting, includeSensors: true), isFalse);
    expect(addIosPermissionMacros(conflicting, includeSensors: true), isNull);
  });

  test('refuses to guess inside a non-standard post-install block', () {
    const custom = '''
post_install do |installer|
  custom_setup(installer)
end
''';

    expect(
      addIosPermissionMacros(custom, includeSensors: true),
      isNull,
    );
  });
}
