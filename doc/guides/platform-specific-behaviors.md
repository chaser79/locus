# Platform-Specific Behaviors

Last updated: July 13, 2026

Key runtime differences that affect tracking, geofencing, background execution, and battery.

## Android
- **Doze/App Standby:** Jobs and alarms defer; run as a foreground service with a persistent notification to maintain updates.
- **Permissions:** Request foreground first, then background. Approximate
  (`ACCESS_COARSE_LOCATION`) is valid for tracking; request precise
  (`ACCESS_FINE_LOCATION`) only when the product requires it. Starting or
  recreating a location foreground service while the app is in the background,
  including reboot recovery, requires background access on Android versions
  that enforce it.
- **Geofence limits:** ~100 per app. Keep identifiers stable; remove stale fences.
- **Foreground service startup:** Call `startForeground` quickly; missing notification can kill the service.
- **Lifecycle:** UI detach, recents swipe, ordinary process death, Android Task
  Manager stop, force-stop, and reboot have different recovery boundaries. See
  the [Android lifecycle matrix](headless-execution.md#android-lifecycle-matrix).
- **OEM optimizations:** Some vendors (Xiaomi, Huawei, Samsung) kill background
  services aggressively. Runtime permission helpers do not manage OEM battery
  policy; the host app must provide rationale and user-controlled settings
  guidance through `DeviceOptimizationService`.
- **Networking:** Metered/roaming policies can block sync; honor `disableAutoSyncOnCellular` when set.

## iOS
- **Background modes:** Enable “Location updates” (and optionally “Background fetch”) in Info.plist.
- **Permission build flags:** Enable `PERMISSION_LOCATION=1` and
  `PERMISSION_SENSORS=1` in the CocoaPods post-install hook before using
  `Locus.requestPermission()`.
- **SLC vs standard:** Significant-change is low power but less frequent; standard updates pause unless background mode is active.
- **Approximate location:** Users may grant reduced accuracy; prompt for precise only when necessary.
- **Geofence limits:** ~20 regions per app; prioritize critical fences.
- **Execution time:** Background tasks must finish fast; incomplete work may be terminated—keep headless work minimal.
- **Recovery:** With Always authorization and `stopOnTerminate: false`, Locus
  persists desired tracking state and registers significant-change monitoring.
  An eligible significant-change or region event can relaunch a process after
  ordinary OS termination; delivery timing is not guaranteed.
- **User force-quit:** Swiping the app away is an explicit stop boundary on iOS.
  Core Location background relaunch is suppressed until the user opens the app
  again. `startOnBoot` is Android-only and cannot bypass this boundary.
- **Acceptance gate:** `isTracking == true` records requested native state. A
  fresh delivered and persisted location is the proof that recovery succeeded.

## Cross-platform recommendations
- If enabled privacy zones previously asserted the native privacy guard, cold
  recovery keeps raw persistence and HTTP sync suppressed until Dart explicitly
  restores or releases that guard. This is intentionally fail-closed across
  process death.
- Keep fences lean; prune old ones and batch updates.
- Provide clear permission rationale, and detect when users downgrade accuracy/background permission.
- Tune `distanceFilter`, `desiredAccuracy`, heartbeat, and activity intervals per platform expectations.
- Handle coarse fixes gracefully; do not drop all approximate locations—flag them instead.
- Log power, connectivity, and permission state to aid support and diagnostics.
