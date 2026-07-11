# locus

## Project Status

<!-- Set manually. Drives refactor aggressiveness; `unknown` => the agent asks first. -->
- isDeployed: yes
- isThereData: no

## Tech Stack

- **Framework**: Flutter
- **Language**: Dart
- **Package Manager**: flutter pub

## Commands

```bash
# Get dependencies
flutter pub get

# Build
flutter build

# Test
flutter test

# Run
flutter run

# Analyze
flutter analyze
```

## Project Structure

Locus is a **Flutter plugin** (not an app) — a background geolocation SDK with native Android/iOS implementations and a thin Dart facade.

```
locus/
├── lib/
│   ├── locus.dart            # Single public entry — barrel re-exports only
│   └── src/
│       ├── core/             # LocusInterface, MethodChannelLocus, channels, lifecycle, headless, event_mapper
│       ├── config/           # Config, presets, validators, enums, constants
│       ├── features/         # Feature-first modules, each with models/ + services/
│       │   ├── location/     # tracking, quality analysis, spoof/anomaly detection, significant-change
│       │   ├── geofencing/   # circular + polygon geofences, workflow engine
│       │   ├── battery/      # adaptive tracking, runway estimation, power state, sync policy
│       │   ├── privacy/      # privacy zones
│       │   ├── trips/        # trip detection, route recording, trip store
│       │   ├── sync/         # HTTP queue, batch sync, connectivity handling
│       │   ├── tracking/     # tracking profiles + rule-based switching
│       │   └── diagnostics/  # logging, debug overlay widget, error recovery
│       ├── observability/    # reliability events + metrics surface for hosts
│       ├── services/         # v2 service interfaces + default impls (location/geofence/privacy/trip/sync/battery/diagnostics)
│       ├── shared/           # cross-cutting models (Coords, Activity, Battery, events). Zero behavior
│       └── testing/          # MockLocus for host-app tests
├── android/src/main/kotlin/dev/locus/  # core/, location/, activity/, geofence/, receiver/, service/, storage/
├── ios/Classes/              # Swift (SwiftLocusPlugin + extensions) + ObjC shim
├── bin/                      # Pure-Dart CLI executables: locus, setup, doctor, migrate
├── doc/ · test/ · example/   # docs, unit/integration/benchmark tests, example app
```

Host apps import **only** `package:locus/locus.dart`; everything under `lib/src/` is private. The `Locus` singleton (`lib/src/locus.dart`) is the facade. `bin/` tools are declared as `executables:` in `pubspec.yaml` and run via `dart run locus:<tool>`.

## Code Style & Conventions

- Follow Dart style guide and effective Dart
- Use `dart format` for code formatting
- Prefer Riverpod for state management (if applicable)
- Use freezed for immutable models (if applicable)
- Separate presentation, domain, and data layers

## Key Dependencies

**Runtime** (`pubspec.yaml`):

- `permission_handler` — runtime prompts for location (fine/coarse/background), notifications, activity recognition.
- `logging` — structured `Logger` tree surfaced via diagnostics and the debug overlay.
- `args` — argument parsing for the CLI executables in `bin/`. CLI-only; reachable from `bin/` so it is tree-shaken from host bundles.

**Dev**: `flutter_test`, `flutter_lints` (baseline lints via `analysis_options.yaml`).

**Native** (relevant only when editing platform code): Android `play-services-location`, `kotlinx-coroutines-android`, `androidx.security:security-crypto` (`android/build.gradle.kts`); iOS `CoreLocation`, `CoreMotion` (`ios/locus.podspec`).

The Dart dependency surface is deliberately **minimal** — no Riverpod, freezed, or code-gen; all models are hand-written immutable classes. Do not add runtime Dart deps without explicit approval — each becomes transitive for every consumer.

## Architecture

**Feature-first plugin** with a thin Dart facade over native code. Dependencies point inward; outer layers never leak into inner ones.

- **Layers**: host app → public API (`lib/locus.dart` barrel + `Locus` singleton) → feature modules (`lib/src/features/<name>/` with `models/` + `services/`) → `core/` (platform boundary) → `shared/` (pure data). Native (`android/`, `ios/`) owns the long-lived process.
- **Platform Interface pattern**: `LocusInterface` (abstract) + `MethodChannelLocus` (default, raw `MethodChannel` over `locus/methods`, `locus/events`, `locus/headless`). `MockLocus` swaps in via `Locus.setMockInstance(...)` for host tests.
- **Event-sourced state**: native is the source of truth; Dart maps native events through `core/event_mapper.dart` and does not cache tracking state (`Locus.isTracking()` calls the platform).
- **Headless execution**: callbacks registered via `Locus.registerHeadlessTask` run in a second engine after the UI is killed; entry points need `@pragma('vm:entry-point')`.
- **Boundaries**: features must not import each other — route via `shared/` or event streams; `bin/` CLI is pure Dart (no `package:flutter/*`).

Reference: [`doc/core/architecture.md`](doc/core/architecture.md).

## Stack-Specific Rules

# Flutter Best Practices (2026)

## Platform & Language

- Target **Flutter 3.35+** with **Dart 3.9+**.
- Sound null safety enforced — no `// ignore: null` workarounds.
- Use Dart 3 features: sealed classes for union types, pattern matching with `switch` expressions, records for lightweight grouping.

## State Management

- **Riverpod 3** is the preferred state management solution.
- BLoC is acceptable for event-driven architectures with complex state machines.
- Never use `setState` for anything beyond trivial, widget-local UI state (e.g., toggling a disclosure indicator).

```dart
// GOOD — Riverpod provider with select for granular rebuilds
final orderProvider = AsyncNotifierProvider<OrderNotifier, List<Order>>(OrderNotifier.new);

class OrderListScreen extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orderCount = ref.watch(orderProvider.select((s) => s.valueOrNull?.length ?? 0));
    return Text('Orders: $orderCount');
  }
}

// BAD — setState for complex state
class _OrderListState extends State<OrderList> {
  List<Order> _orders = [];
  void _loadOrders() async {
    final data = await api.fetchOrders();
    setState(() => _orders = data); // scales poorly, no separation of concerns
  }
}
```

## Navigation

- **go_router** with type-safe routes and declarative navigation.
- Define routes as constants or enums — no magic path strings scattered across the codebase.
- Use `StatefulShellRoute` for bottom navigation with preserved state.

```dart
GoRouter(
  routes: [
    GoRoute(
      path: '/orders/:id',
      builder: (context, state) => OrderDetailScreen(
        orderId: state.pathParameters['id']!,
      ),
    ),
  ],
);
```

## Models & Data Classes

- **freezed** for immutable data classes with `copyWith`, equality, and serialization.
- **json_serializable** for JSON encoding/decoding — never hand-write `fromJson`/`toJson`.
- Use **sealed classes** for union types and exhaustive pattern matching.

```dart
@freezed
class Order with _$Order {
  const factory Order({
    required String id,
    required String customerName,
    required List<OrderItem> items,
    required OrderStatus status,
  }) = _Order;

  factory Order.fromJson(Map<String, dynamic> json) => _$OrderFromJson(json);
}

sealed class OrderStatus {
  const OrderStatus();
}
class Pending extends OrderStatus { const Pending(); }
class Shipped extends OrderStatus { final String trackingId; const Shipped(this.trackingId); }
class Delivered extends OrderStatus { const Delivered(); }
```

## Widget Composition

- Small, focused widgets. Extract early — if `build()` exceeds ~40 lines, it probably needs splitting.
- Use `const` constructors **everywhere** possible — this enables the framework to skip rebuilds.
- Prefer composition over inheritance. Never extend `StatelessWidget` to "add" behavior.

## Keys

- **Always** provide keys for list items: `ValueKey(item.id)` or `ObjectKey(item)`.
- Use `GlobalKey` sparingly — it has a performance cost and breaks encapsulation.
- Keys on `AnimatedSwitcher` children to trigger animations correctly.

## Platform Channels

- **Pigeon** for type-safe native interop in new code. Generates Dart, Kotlin/Java, and Swift/ObjC bindings.
- Never use raw `MethodChannel` for new features — it is stringly-typed and error-prone.

## Performance

- Watch specific provider fields with `.select()` to avoid unnecessary rebuilds.
- Wrap expensive subtrees in `RepaintBoundary`.
- `ListView.builder` (or `SliverList`) for long/dynamic lists. Never `Column` + `SingleChildScrollView` for unbounded lists.
- Use `const` widgets to prevent unnecessary rebuilds during parent rebuilds.
- Profile with DevTools — fix jank before shipping.

## Architecture

- **Feature-first** directory structure:
  ```
  lib/
    features/
      orders/
        presentation/   # widgets, screens
        domain/          # models, repository interfaces
        data/            # repository implementations, data sources
      auth/
        ...
    core/                # shared utilities, themes, routing
  ```
- Each feature exposes its public API through a barrel file. Internal implementation stays private.

## Testing

- **Widget tests** with `tester.pumpWidget()` for interaction and rendering verification.
- **Golden tests** for visual regression — commit reference images to the repo.
- **Unit tests** for providers, notifiers, and pure logic.
- Mock dependencies with `mocktail` or Riverpod overrides.

## Accessibility

- `Semantics` widget on all custom widgets that convey meaning.
- `ExcludeSemantics` only for purely decorative content (dividers, background images).
- Test with TalkBack (Android) and VoiceOver (iOS) on real devices before release.

## Architecture

Locus is a **feature-first plugin** with a thin Dart facade over native implementations. Dependencies point inward: outer layers may depend on inner layers, never the reverse.

**Layers** (outer → inner):

1. **Host app** — consumes `package:locus/locus.dart` only. Never imports `lib/src/*`.
2. **Public API** (`lib/locus.dart`) — barrel exposing the `Locus` singleton, configs, models, events, and services.
3. **Feature modules** (`lib/src/features/<name>/`) — self-contained; each ships `models/` (pure data) and `services/` (behavior). Features depend on `shared/` and `core/`, **never on each other**.
4. **Core** (`lib/src/core/`) — the platform boundary:
   - `LocusInterface` — abstract contract.
   - `MethodChannelLocus` — default platform-channel implementation.
   - `locus_streams.dart` — typed event streams.
   - `locus_channels.dart` — channel names (single source of truth).
   - `locus_lifecycle.dart`, `locus_headless.dart` — lifecycle + headless entry points.
5. **Shared** (`lib/src/shared/`) — cross-cutting data types (`Coords`, `Activity`, `Battery`, event types). Zero behavior.
6. **Native** (`android/`, `ios/`) — owns the long-lived process: Android `ForegroundService` + `HeadlessService`, iOS background location delegates, persistent queue, geofence registration, activity recognition. Native emits typed events; Dart translates via `lib/src/core/event_mapper.dart`.

**Patterns**:

- **Platform Interface pattern** — `LocusInterface` + `MethodChannelLocus` lets `MockLocus` (`lib/src/testing/`) be swapped in via `Locus.setInstance(...)` for host-app tests.
- **Barrel exports per feature** — each feature exposes its public surface through `<feature>.dart`; everything else is package-private.
- **Event-sourced state** — native is the source of truth. `Locus.isTracking()` calls the platform; Dart never caches tracking state.
- **Headless execution** — Dart callbacks registered via `Locus.registerHeadlessTask` run in a second engine after the UI is killed. All headless entry points require `@pragma('vm:entry-point')`. See `doc/guides/headless-execution.md`.
- **CLI isolation** — `bin/` programs are pure Dart; they must not import `package:flutter/*`.

**Non-negotiables**:

- A feature must **never** import another feature's `models/` or `services/` — route through `shared/` or an event stream.
- `lib/src/` must **never** use `dart:io` for platform detection — go through `LocusInterface`.
- Native code must survive `onDetachedFromEngine` — the Flutter engine detaches whenever the UI is swiped away, and the background service must keep running.
- `stopOnTerminate: false` + `enableHeadless: true` + `foregroundService: true` is the canonical "always-on tracking" configuration; any change in lifecycle handling must be validated against it (see issue #34).

Reference: [`doc/core/architecture.md`](doc/core/architecture.md).

