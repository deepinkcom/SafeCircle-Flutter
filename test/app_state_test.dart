import 'package:flutter_test/flutter_test.dart';
import 'package:safecircle/models/models.dart';
import 'package:safecircle/services/api_service.dart';
import 'package:safecircle/services/auth_service.dart';
import 'package:safecircle/services/location_service.dart';
import 'package:safecircle/state/app_state.dart';

class FakeLocationService extends LocationService {
  bool shouldFail = false;
  int locationCalls = 0;
  int readableLocationCalls = 0;

  @override
  Future<({double lat, double lng})> getCurrentLocation() async {
    locationCalls++;

    if (shouldFail) {
      throw Exception('Simulated location failure');
    }

    return (lat: -33.9, lng: 18.4);
  }

  @override
  Future<String> getReadableLocation({
    required double lat,
    required double lng,
  }) async {
    readableLocationCalls++;
    return 'Test location';
  }
}

class FakeApiService extends ApiService {
  bool shouldFail = false;
  bool shouldFailResolve = false;
  int panicCalls = 0;
  int resolveCalls = 0;
  int? resolvedAlertId;
  double? sentLatitude;
  double? sentLongitude;

  FakeApiService() : super(baseUrl: 'http://127.0.0.1:1');

  @override
  Future<int> sendPanicAlert({
    required double latitude,
    required double longitude,
  }) async {
    panicCalls++;
    sentLatitude = latitude;
    sentLongitude = longitude;

    if (shouldFail) {
      throw Exception('Simulated API failure');
    }

    return 123;
  }

  @override
  Future<void> resolveAlert(int alertId) async {
    resolveCalls++;
    resolvedAlertId = alertId;

    if (shouldFailResolve) {
      throw Exception('Simulated resolve failure');
    }
  }
}

class FakeAuthService extends AuthService {}

void main() {
  late FakeLocationService location;
  late FakeApiService api;
  late AppState state;

  setUp(() {
    location = FakeLocationService();
    api = FakeApiService();

    state = AppState(
      locationService: location,
      apiService: api,
      authService: FakeAuthService(),
    );
  });

  tearDown(() {
    state.dispose();
  });

  test('starts emergency after location and API succeed', () async {
    await state.startEmergency();

    expect(location.locationCalls, 1);
    expect(location.readableLocationCalls, 1);
    expect(api.panicCalls, 1);
    expect(api.sentLatitude, -33.9);
    expect(api.sentLongitude, 18.4);

    expect(state.isEmergencyActive, isTrue);
    expect(state.currentLocation, 'Test location');
    expect(state.alertHistory, hasLength(1));
    expect(state.alertHistory.first.id, 123);
    expect(state.alertHistory.first.kind, AlertKind.emergencySent);
    expect(state.alertHistory.first.status, AlertStatus.active);
  });

  test('does not send API request if location retrieval fails', () async {
    location.shouldFail = true;

    await expectLater(
      state.startEmergency(),
      throwsA(isA<Exception>()),
    );

    expect(location.locationCalls, 1);
    expect(location.readableLocationCalls, 0);
    expect(api.panicCalls, 0);
    expect(state.isEmergencyActive, isFalse);
    expect(state.alertHistory, isEmpty);
  });

  test('does not activate emergency if API request fails', () async {
    api.shouldFail = true;

    await expectLater(
      state.startEmergency(),
      throwsA(isA<Exception>()),
    );

    expect(location.locationCalls, 1);
    expect(location.readableLocationCalls, 1);
    expect(api.panicCalls, 1);
    expect(state.isEmergencyActive, isFalse);
    expect(state.alertHistory, isEmpty);
  });

  test('keeps emergency active if backend resolution fails', () async {
    // Arrange: create an active emergency using fake services.
    await state.startEmergency();
    api.shouldFailResolve = true;

    // Act: simulate the backend failing to resolve the alert.
    await expectLater(
      state.resolveEmergency(),
      throwsA(isA<Exception>()),
    );

    // Assert: local state should still reflect the active emergency.
    expect(api.resolveCalls, 1);
    expect(api.resolvedAlertId, 123);
    expect(state.isEmergencyActive, isTrue);
    expect(state.alertHistory, hasLength(1));
    expect(state.alertHistory.first.status, AlertStatus.active);
  });

  test('resolves emergency after backend succeeds', () async {
    // Arrange: create an active emergency using fake services.
    await state.startEmergency();

    // Act: simulate successful backend resolution.
    await state.resolveEmergency();

    // Assert: local state reflects successful resolution.
    expect(api.resolveCalls, 1);
    expect(api.resolvedAlertId, 123);
    expect(state.isEmergencyActive, isFalse);
    expect(state.alertHistory, hasLength(1));
    expect(
      state.alertHistory.first.status,
      AlertStatus.resolved,
    );
  });
}
