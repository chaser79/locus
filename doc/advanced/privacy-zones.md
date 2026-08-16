# Privacy Zones

Privacy zones allow users to define areas where location tracking behavior is modified to protect their privacy. This is useful for home locations, workplaces, or other sensitive areas.

## Creating a Privacy Zone

```dart
final homeZone = PrivacyZone.create(
  identifier: 'home',
  latitude: 37.7749,
  longitude: -122.4194,
  radius: 150, // meters
  action: PrivacyZoneAction.exclude,
);

await Locus.privacy.add(homeZone);
```

## Privacy Actions

Privacy zones support two actions:

| Action | Description |
|--------|-------------|
| `exclude` | Completely exclude locations from this zone |
| `obfuscate` | Randomize location within the zone |

### Exclude Action

No location updates are recorded or transmitted while in the zone:

```dart
PrivacyZone.create(
  identifier: 'home',
  latitude: 37.7749,
  longitude: -122.4194,
  radius: 150,
  action: PrivacyZoneAction.exclude,
)
```

### Obfuscate Action

Locations are randomized within the zone to hide the exact position:

```dart
PrivacyZone.create(
  identifier: 'work',
  latitude: 37.7849,
  longitude: -122.4094,
  radius: 200,
  action: PrivacyZoneAction.obfuscate,
  obfuscationRadius: 100, // Random offset up to 100m
)
```

### Background and headless delivery

Privacy-zone geometry is owned by Dart. While a live UI engine is attached,
native location events pass through Dart so matching points can be excluded or
obfuscated before host listeners receive them. Geofence transitions are kept,
but an excluded nested location is removed and an obfuscated one replaces the
raw coordinates.

When no UI engine is available, Locus fails closed: if any enabled privacy zone
is registered, native location-bearing headless events are suppressed until
Dart restores or explicitly releases the privacy guard. Non-location lifecycle
and error events continue normally. This intentionally favors privacy over
headless location delivery because native code does not have the zone geometry
needed to decide whether a raw point is safe.

## Managing Privacy Zones

```dart
// Get all privacy zones
final zones = await Locus.privacy.getAll();

// Get a single zone
final zone = await Locus.privacy.get('home');

// Remove a zone
await Locus.privacy.remove('home');

// Remove all zones
await Locus.privacy.removeAll();

// Disable or enable a zone
await Locus.privacy.setEnabled('home', false);
```

## Privacy Zone Events

Listen for zone configuration changes:

```dart
Locus.privacy.events.listen((event) {
  print('${event.type.name}: ${event.zone.identifier}');
});
```

## Using the Privacy Zone Service

For more control, use the `PrivacyZoneService` directly:

```dart
final service = PrivacyZoneService();

// Add zones
await service.addZone(homeZone);

// Process a location through privacy filtering
final result = service.processLocation(location);

if (result.wasExcluded) {
  print('Location excluded by privacy zone');
} else if (result.wasObfuscated) {
  print('Location obfuscated by privacy zone');
}

// Use the filtered location
final safeLocation = result.processedLocation;
```

---

**Next:** [Trip Tracking](trips.md)
