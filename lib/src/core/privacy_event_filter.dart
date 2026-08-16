import 'package:locus/src/features/geofencing/models/geofence_event.dart';
import 'package:locus/src/features/privacy/services/privacy_zone_service.dart';
import 'package:locus/src/shared/event_type.dart';
import 'package:locus/src/shared/geolocation_event.dart';

/// Applies privacy-zone rules to the nested location carried by a geofence
/// transition while preserving the transition itself.
///
/// Native code must send raw locations to a live UI engine because the zone
/// geometry is Dart-owned. Excluded locations are removed from the event;
/// obfuscated locations replace the raw coordinates.
GeolocationEvent<dynamic> applyPrivacyToGeofenceEvent(
  GeolocationEvent<dynamic> event,
  PrivacyZoneService? privacyZoneService,
) {
  if (event.type != EventType.geofence ||
      event.data is! GeofenceEvent ||
      privacyZoneService == null ||
      privacyZoneService.enabledZones.isEmpty) {
    return event;
  }

  final geofenceEvent = event.data as GeofenceEvent;
  final location = geofenceEvent.location;
  if (location == null) return event;

  final result = privacyZoneService.processLocation(location);
  final processedLocation = result.wasExcluded
      ? null
      : result.processedLocation ?? geofenceEvent.location;
  if (identical(processedLocation, location)) return event;

  return GeolocationEvent<GeofenceEvent>(
    type: event.type,
    data: GeofenceEvent(
      geofence: geofenceEvent.geofence,
      action: geofenceEvent.action,
      location: processedLocation,
    ),
  );
}
