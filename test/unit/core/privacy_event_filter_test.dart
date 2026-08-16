import 'package:flutter_test/flutter_test.dart';
import 'package:locus/src/core/privacy_event_filter.dart';
import 'package:locus/src/features/geofencing/models/geofence.dart';
import 'package:locus/src/features/geofencing/models/geofence_event.dart';
import 'package:locus/src/features/location/models/location.dart';
import 'package:locus/src/features/privacy/models/privacy_zone.dart';
import 'package:locus/src/features/privacy/services/privacy_zone_service.dart';
import 'package:locus/src/shared/event_type.dart';
import 'package:locus/src/shared/geolocation_event.dart';
import 'package:locus/src/shared/models/coords.dart';
import 'package:locus/src/shared/models/enums.dart';

void main() {
  final timestamp = DateTime.utc(2026, 7, 15);
  final rawLocation = Location(
    uuid: 'raw-location',
    timestamp: timestamp,
    coords: const Coords(latitude: 52.2215, longitude: 6.8937, accuracy: 5),
  );
  final transition = GeolocationEvent<GeofenceEvent>(
    type: EventType.geofence,
    data: GeofenceEvent(
      geofence: const Geofence(
        identifier: 'work',
        latitude: 52.22,
        longitude: 6.89,
        radius: 100,
      ),
      action: GeofenceAction.enter,
      location: rawLocation,
    ),
  );

  test(
    'excluded geofence location is removed without dropping transition',
    () async {
      final service = PrivacyZoneService();
      await service.addZone(
        PrivacyZone(
          identifier: 'private',
          latitude: 52.2215,
          longitude: 6.8937,
          radius: 100,
          action: PrivacyZoneAction.exclude,
          createdAt: timestamp,
        ),
      );

      final filtered = applyPrivacyToGeofenceEvent(transition, service);

      expect(filtered.type, EventType.geofence);
      expect((filtered.data as GeofenceEvent).action, GeofenceAction.enter);
      expect((filtered.data as GeofenceEvent).location, isNull);
    },
  );

  test('obfuscated geofence location replaces raw coordinates', () async {
    final service = PrivacyZoneService(seed: 42);
    await service.addZone(
      PrivacyZone(
        identifier: 'private',
        latitude: 52.2215,
        longitude: 6.8937,
        radius: 100,
        action: PrivacyZoneAction.obfuscate,
        obfuscationRadius: 250,
        createdAt: timestamp,
      ),
    );

    final filtered = applyPrivacyToGeofenceEvent(transition, service);
    final location = (filtered.data as GeofenceEvent).location!;

    expect(location.coords.latitude, isNot(rawLocation.coords.latitude));
    expect(location.coords.longitude, isNot(rawLocation.coords.longitude));
  });

  test('geofence event is unchanged without enabled privacy zones', () {
    expect(
      applyPrivacyToGeofenceEvent(transition, PrivacyZoneService()),
      same(transition),
    );
  });
}
