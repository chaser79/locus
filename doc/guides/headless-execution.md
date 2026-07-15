# Headless Execution Guide

Last updated: July 13, 2026

Run Locus logic for OS-eligible native events while the Flutter UI engine is
absent or the app is backgrounded. Explicit platform stop states are excluded.

## Lifecycle overview
- Platform wakes a background isolate on eligible events (location, geofence, heartbeat, sync).
- Your registered top-level callback executes; no UI is available.
- Process may be killed at any time; keep work short and resilient.

## Requirements
- Register a **top-level or static** function (no closures/instance methods).
- Add `@pragma('vm:entry-point')` to prevent tree shaking.
- Do not access Widgets or BuildContext; use pure Dart code and lightweight I/O.

## Setup

```dart
// main.dart
@pragma('vm:entry-point')
Future<void> locusHeadlessCallback(HeadlessEvent event) async {
  try {
    switch (event.type) {
      case HeadlessEventType.location:
        final loc = event.location;
        // e.g., enqueue for later sync
        break;
      case HeadlessEventType.geofence:
        // e.g., persist geofence transition
        break;
      case HeadlessEventType.sync:
        // inspect sync result, adjust policy if needed
        break;
      case HeadlessEventType.heartbeat:
        // optional lightweight health signal
        break;
    }
  } catch (e, st) {
    // Log defensively; avoid throws
    // e.g., await HeadlessLogger.log('$e\n$st');
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Locus.registerHeadlessTask(locusHeadlessCallback);
  runApp(const MyApp());
}
```

## Best practices
- Keep callbacks under a few hundred milliseconds; offload heavy work to queued tasks.
- Guard every branch with try/catch; never let exceptions escape.
- Avoid network calls when offline; enqueue instead.
- Respect user consent: skip work if permissions or policy are revoked.
- Test on real devices; emulators may suspend differently.

## Validation checklist

- Test UI detach, recents swipe, ordinary process death, Task Manager stop,
  force-stop, and reboot separately; Android gives them different semantics.
- For recovery tests, record the process ID before and after termination and
  require a newly persisted location. A notification alone does not prove that
  location updates resumed.
- Confirm no crashes in headless logs and that queued data appears on the next
  foreground launch.
- On Android, ensure the foreground-service notification is configured before
  testing background behavior.

## Android lifecycle matrix

The canonical always-on configuration is `stopOnTerminate: false`,
`enableHeadless: true`, and `foregroundService: true`. Add `startOnBoot: true`
only when tracking should be eligible to recover after a reboot.

Android does not have one generic "app killed" state:

| Event | Locus behavior | Recovery boundary |
|---|---|---|
| Flutter UI engine detaches while the process remains alive | Engine-scoped channels are removed. The process-scoped native container and its active location subscription continue. Eligible events fall back to the registered headless dispatcher when no UI event sink exists. | A later engine attaches to the same container. There is no manager-ownership transfer or listener-rebinding step. |
| User swipes the task from recents with `stopOnTerminate: false` | `onTaskRemoved` keeps the foreground service and durable tracking intent active. | Tracking normally continues. An OEM may still terminate the process; treat that as ordinary OS process death below. |
| User swipes the task from recents with `stopOnTerminate: true` | Locus clears the durable tracking intent and stops native tracking and the foreground service. | Tracking remains stopped until the host app starts it again. Persistence and runtime shutdown are ordered operations, not one atomic transaction. |
| Android reclaims the process without a user-requested stop | In-memory subscriptions disappear. The active tracking intent and last valid configuration remain persisted. | Android may recreate the sticky foreground service. The recreated service reconciles persisted state and permission before registering location again. If Android does not restart it immediately, the next eligible Flutter-engine attach performs the same reconciliation. OEM and OS policies mean restart timing is not guaranteed. |
| User taps **Stop** in Android 13+ Task Manager | Android stops the process and foreground service but does not force-stop the package, so a later job or broadcast can launch a new process. On that launch, Locus consumes the explicit-stop exit record, clears durable tracking intent, and suppresses headless startup. | Tracking remains off until the host explicitly calls `Locus.start()` again. A process launch alone must not recover it. |
| User selects **Force stop** in system settings | Android terminates the process and places the package in the stopped state. Services, jobs, and boot receivers cannot run while that state remains. On API 30+, the next user-eligible launch lets Locus consume a recognized explicit-stop record and clear durable tracking intent. | User interaction, normally launching the app, first releases Android's stopped state; on API 30+ the host must then explicitly call `Locus.start()` to resume. Android 8-10 expose no exit history, so the host must account for legacy persisted-intent reconciliation after that manual open. |
| App relaunches while the service process is still alive | A new engine adapter attaches to the existing process-scoped container and binds its own channels. | `Locus.isTracking()` reflects the native container; no Dart-side restart is needed. |
| Device reboots | If boot prerequisites are satisfied, the boot receiver starts the registered headless dispatcher. Plugin attachment then reconciles previously active tracking from persisted state. | Requires `startOnBoot: true`, `enableHeadless: true`, a successfully registered top-level `Locus.registerHeadlessTask` callback, declared boot/location/foreground-service permissions, and location permission that remains valid for background use. `stopOnTerminate: false` is required if recents removal must not clear the durable tracking intent before reboot. |

On Android 11+, Locus distinguishes known platform force-stop descriptions from
a recents removal before recovery; this also covers Android 13+ Task Manager
Stop. Android 8-10 do not expose process-exit history to apps. Unknown OEM
descriptions remain non-terminal to preserve the documented
`stopOnTerminate: false` swipe behavior, so Samsung, Xiaomi, and other OEM stop
surfaces still need physical-device acceptance testing.

Recovery is successful only after a new location is delivered. A restored
notification or `isTracking == true` is useful state evidence, but neither alone
proves that the platform location subscription resumed.

## iOS lifecycle matrix

The iOS always-on posture is `stopOnTerminate: false` with Always location
authorization and the Location updates background mode. `startOnBoot` is
Android-only.

| Event | Locus behavior | Recovery boundary |
|---|---|---|
| Flutter UI engine detaches while the process remains alive | The engine binding releases its channels. Process-owned Core Location, storage, and sync managers remain active. | A replacement engine attaches a new binding to the same runtime. |
| App moves to background | Standard location updates continue while iOS grants background execution. With `stopOnTerminate: false`, significant-change monitoring is also registered. | iOS may throttle delivery based on motion, accuracy, power, and policy. |
| iOS reclaims the process | Valid desired tracking intent and encrypted configuration remain durable. | An eligible significant-change or region event may relaunch the app; Locus requires Always authorization and re-registers standard updates. Timing is not guaranteed. |
| User force-quits the app | iOS treats this as an explicit stop boundary and suppresses Core Location background relaunch. | The user must open the app again. Locus does not attempt to bypass this OS policy. |
| Permission is downgraded/revoked or Location Services is disabled | Locus stops native managers, clears stale desired state, and emits disabled/provider/error state. | The host must regain the required authorization and explicitly start again. |
| `stopOnTerminate: true` at the next cold launch | Persisted active intent is cleared rather than recovered. | Tracking remains stopped until an explicit start. |

As on Android, `isTracking == true` proves the runtime requested updates, not
that Core Location delivered one. A fresh persisted location is the recovery
acceptance gate.

### Android location permissions

- Foreground tracking accepts approximate (`ACCESS_COARSE_LOCATION`) or precise
  (`ACCESS_FINE_LOCATION`) access. Request precise access only when the product
  genuinely requires its accuracy.
- A location foreground service started while the app is visible can continue
  after the UI moves to the background. Starting or recreating that service from
  the background, including eligible process-death and reboot recovery, requires
  background location access on Android versions that enforce it.
- Permission can be downgraded or revoked at any time. Recovery validates the
  current grant and stops instead of retrying silently when location access is
  unavailable.
- Notification and activity-recognition permissions are separate capabilities;
  request them when the configured feature uses them.

See [Platform Configuration](../setup/platform-configuration.md) for the host
manifest and runtime permission flow.

### OEM caveats

Aggressive task killers on Samsung One UI, Xiaomi MIUI, and Huawei EMUI may still
reap the foreground service outside the standard Android lifecycle.
`PermissionAssistant.requestBackgroundWorkflow` requests runtime permissions;
it does not grant a battery-optimization exemption. The host app owns the user
rationale and settings navigation. Use
`DeviceOptimizationService.isIgnoringBatteryOptimizations()` to inspect the
current state and `DeviceOptimizationService.getManufacturerInstructionsUrl()`
for manufacturer-specific guidance. Exemptions are user-controlled and must
never be presented as guaranteed recovery.

See [Platform-Specific Setup](../setup/platform-specific.md#6-battery-optimization)
and [Battery Optimization](../advanced/battery-optimization.md).
