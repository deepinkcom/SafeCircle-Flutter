import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:safecircle/services/location_service.dart';

class PermissionPlatform extends GeolocatorPlatform {
  bool enabled = true;
  LocationPermission permission = LocationPermission.denied;
  LocationPermission response = LocationPermission.whileInUse;
  int checks = 0;
  int requests = 0;
  int gpsRequests = 0;
  int appSettings = 0;
  int locationSettings = 0;

  @override
  Future<bool> isLocationServiceEnabled() async => enabled;
  @override
  Future<LocationPermission> checkPermission() async {
    checks++;
    return permission;
  }

  @override
  Future<LocationPermission> requestPermission() async {
    requests++;
    return response;
  }

  @override
  Future<Position> getCurrentPosition(
      {LocationSettings? locationSettings}) async {
    gpsRequests++;
    throw StateError('Permission onboarding must not obtain coordinates.');
  }

  @override
  Future<bool> openAppSettings() async {
    appSettings++;
    return true;
  }

  @override
  Future<bool> openLocationSettings() async {
    locationSettings++;
    return true;
  }
}

void main() {
  late GeolocatorPlatform previous;
  late PermissionPlatform platform;
  final service = LocationService();
  setUp(() {
    previous = GeolocatorPlatform.instance;
    platform = PermissionPlatform();
    GeolocatorPlatform.instance = platform;
  });
  tearDown(() {
    expect(platform.gpsRequests, 0);
    GeolocatorPlatform.instance = previous;
  });

  test('disabled services do not prompt for permission', () async {
    platform.enabled = false;
    expect(await service.requestPermission(), LocationAccess.servicesDisabled);
    expect(platform.checks, 0);
    expect(platform.requests, 0);
  });
  for (final permission in [
    LocationPermission.whileInUse,
    LocationPermission.always
  ]) {
    test('existing $permission needs no prompt or GPS fix', () async {
      platform.permission = permission;
      expect(await service.requestPermission(), LocationAccess.granted);
      expect(platform.requests, 0);
    });
  }
  for (final (response, expected) in [
    (LocationPermission.whileInUse, LocationAccess.granted),
    (LocationPermission.denied, LocationAccess.denied),
    (LocationPermission.deniedForever, LocationAccess.deniedForever),
    (LocationPermission.unableToDetermine, LocationAccess.denied),
  ]) {
    test('denied permission requests once and maps $response safely', () async {
      platform.response = response;
      expect(await service.requestPermission(), expected);
      expect(platform.checks, 1);
      expect(platform.requests, 1);
    });
  }
  test('permanent denial does not repeatedly request permission', () async {
    platform.permission = LocationPermission.deniedForever;
    expect(await service.requestPermission(), LocationAccess.deniedForever);
    expect(platform.requests, 0);
  });
  test('settings recovery delegates to the existing location platform',
      () async {
    expect(await service.openLocationSettings(), isTrue);
    expect(await service.openAppSettings(), isTrue);
    expect((platform.locationSettings, platform.appSettings), (1, 1));
  });
}
