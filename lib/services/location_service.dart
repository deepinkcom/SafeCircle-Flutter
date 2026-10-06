import 'package:geocoding/geocoding.dart' as geocoding;
import 'package:geolocator/geolocator.dart';

/// Handles access to the device's GPS location.
class LocationService {
  /// Returns the device's current latitude and longitude.
  Future<({double lat, double lng})> getCurrentLocation() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();

    if (!serviceEnabled) {
      throw Exception(
        'Location services are disabled. Please enable Location on your device.',
      );
    }

    LocationPermission permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();

      if (permission == LocationPermission.denied) {
        throw Exception(
          'Location permission was denied.',
        );
      }
    }

    if (permission == LocationPermission.deniedForever) {
      throw Exception(
        'Location permission is permanently denied. '
        'Please enable it in the device settings.',
      );
    }

    final Position position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );

    return (
      lat: position.latitude,
      lng: position.longitude,
    );
  }

    /// Converts GPS coordinates into a readable address.
  Future<String> getReadableLocation({
    required double lat,
    required double lng,
  }) async {
    final placemarks = await geocoding.Geocoding().placemarkFromCoordinates(
      lat,
      lng,
    );

    if (placemarks.isEmpty) {
      return '$lat, $lng';
    }

    final place = placemarks.first;

    final parts = <String>[
      if (place.street?.trim().isNotEmpty == true) place.street!.trim(),
      if (place.subLocality?.trim().isNotEmpty == true)
        place.subLocality!.trim(),
      if (place.locality?.trim().isNotEmpty == true) place.locality!.trim(),
      if (place.country?.trim().isNotEmpty == true) place.country!.trim(),
    ];

    if (parts.isEmpty) {
      return '$lat, $lng';
    }

    return parts.join(', ');
  }
}
