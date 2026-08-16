#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
#
# Single source of truth: read the version straight out of pubspec.yaml so
# the pod never drifts from the published package version.
require 'yaml'
pubspec = YAML.load_file(File.expand_path('../pubspec.yaml', __dir__))

Pod::Spec.new do |s|
  s.name             = 'locus'
  s.version          = pubspec['version']
  s.summary          = 'Background geolocation SDK for Flutter.'
  s.description      = <<-DESC
    Background geolocation SDK for Flutter. Native tracking, geofencing, 
    activity recognition, and HTTP sync for Android and iOS.
                       DESC
  s.homepage         = 'https://github.com/weorbis/locus'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'WeOrbis' => 'info@weorbis.com' }
  s.source           = { :path => '.' }
  s.source_files = 'locus/Sources/locus/LocusPlugin.{h,m}',
                   'locus/Sources/locus/SwiftLocusPlugin*.swift',
                   'locus/Sources/locus/Core/**/*',
                   'locus/Sources/locus/Geofence/**/*',
                   'locus/Sources/locus/Motion/**/*',
                   'locus/Sources/locus/Storage/**/*',
                   'locus/Sources/locus/Utilities/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '14.0'
  s.frameworks = 'CoreLocation', 'CoreMotion', 'CryptoKit', 'Security'
  s.library = 'sqlite3'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.9'

  # XCTest unit tests under `Tests/`. The tests support both this lowercase
  # CocoaPods module and the top-level `Locus` SwiftPM helper module. CI runs
  # the suite against both names, then builds the complete CocoaPods plugin in
  # the example app with Flutter's real engine framework.
  s.test_spec 'Tests' do |test_spec|
    test_spec.source_files = 'Tests/**/*.swift'
    test_spec.test_type = :unit
  end
end
