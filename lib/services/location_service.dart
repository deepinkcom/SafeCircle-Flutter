/// Wraps device GPS (see stack: "Maps and geolocation - Google Maps Flutter
/// package and device location services").
///
/// To activate: uncomment `geolocator` in pubspec.yaml, add the location
/// permission strings to Info.plist / AndroidManifest.xml, and replace
/// [getCurrentLocation] with a real `Geolocator.getCurrentPosition()` call
/// (after requesting permission via `Geolocator.requestPermission()`).
class LocationService {
  /// Returns (latitude, longitude). Currently returns a fixed mock
  /// coordinate (Sandton, Johannesburg) matching the design mockups.
  Future<({double lat, double lng})> getCurrentLocation() async {
    // TODO: replace with Geolocator.getCurrentPosition()
    await Future<void>.delayed(const Duration(milliseconds: 150));
    return (lat: -26.1076, lng: 28.0567);
  }
}
