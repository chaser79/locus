# Platform Configuration

Background location tracking requires specific permissions and configurations for each platform.

## Android Requirements

### 1. Permissions

Locus requires the following in your `AndroidManifest.xml` (automated by `dart run locus:setup`):

```xml
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION" />
```

### 2. Foreground Service

To track while the app is in the background, Locus runs a Foreground Service. You must provide a `NotificationConfig` in your `Config`.

## iOS Requirements

### 1. Capabilities

Enable the following **Background Modes** in Xcode:

- Location updates
- Background fetch
- Background processing (optional, for sync)

### 2. Info.plist

Add descriptions for the following keys (automated by `dart run locus:setup`):

```xml
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>We need your location to track your trips even in the background.</string>
<key>NSLocationWhenInUseUsageDescription</key>
<string>We need your location to track your trips.</string>
<!-- Required when activity recognition is enabled (the default). -->
<key>NSMotionUsageDescription</key>
<string>We use motion data to detect activity and optimize tracking.</string>
<key>UIBackgroundModes</key>
<array>
  <string>location</string>
  <string>fetch</string>
  <string>processing</string>
</array>
```

`NSMotionUsageDescription` is required when activity recognition is enabled.
Omit it only when setup and validation both use `--no-activity` and the host app
does not call a combined permission flow that requests motion access.

### 3. CocoaPods permission handlers

`permission_handler` compiles unused Apple permission strategies out by default.
`Locus.requestPermission()` therefore requires these definitions in the host
`ios/Podfile` (the setup command adds them automatically):

```ruby
post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
    # locus:permission-handler-macros:start
    target.build_configurations.each do |config|
      definitions = config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= ['$(inherited)']
      definitions.delete_if { |definition| definition.to_s.start_with?('PERMISSION_LOCATION=') }
      definitions << 'PERMISSION_LOCATION=1'
      definitions.delete_if { |definition| definition.to_s.start_with?('PERMISSION_SENSORS=') }
      definitions << 'PERMISSION_SENSORS=1'
    end
    # locus:permission-handler-macros:end
  end
end
```

Omit `PERMISSION_SENSORS=1` only when motion recognition is disabled. In that
configuration, do not call `Locus.requestPermission()`,
`PermissionService.requestAll()`, `PermissionService.requestActivity()`, or the
`PermissionAssistant`; those combined flows intentionally require motion.
Request location with `PermissionService.requestWhenInUse()` followed by
`PermissionService.requestAlways()` instead.

The `locus:` comments delimit setup-owned lines. Keep custom Podfile logic
outside that block; `locus:setup` refuses to rewrite ambiguous Ruby control flow.

## Permission Assistant

Locus includes a `PermissionAssistant` to guide users through the complex multi-step permission flow:

```dart
final status = await PermissionAssistant.requestBackgroundWorkflow(
  config: myConfig,
  delegate: MyPermissionDelegate(),
);
```

## Precise Location Checks

`Locus.requestPermission()` tells you whether the required permission flow completed, but Android and iOS can still grant reduced accuracy. If your product requires high-accuracy tracking, check precise access before starting:

```dart
final precise = await Locus.hasPreciseLocationPermission();
if (!precise) {
  // Show app-specific guidance: enable Precise Location / exact location.
}
```

On Android this checks `ACCESS_FINE_LOCATION`. On iOS it checks `accuracyAuthorization == fullAccuracy`.

---

**Next:** [Testing Guide](../testing/unit-testing.md)
