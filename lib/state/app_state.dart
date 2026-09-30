import 'package:flutter/material.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../services/location_service.dart';

/// Central, observable app state. Screens read from this via
/// `context.watch<AppState>()` / `context.read<AppState>()`.
///
/// This currently holds everything in memory so the app is fully usable
/// with zero backend setup. Each mutating method already calls through the
/// relevant service stub (see lib/services/) so wiring up the real FastAPI
/// backend / PostGIS-backed queries later is a matter of filling in those
/// stubs - this class's public API shouldn't need to change.
class AppState extends ChangeNotifier {
  AppState({ApiService? apiService, LocationService? locationService})
      : _api = apiService ?? ApiService(),
        _location = locationService ?? LocationService();

  final ApiService _api;
  final LocationService _location;

  UserProfile userProfile = const UserProfile(
    name: 'Dumisani Mvelase',
    city: 'Johannesburg',
    email: 'dumisani@example.com',
    phone: '+27 82 555 0134',
  );

  String currentLocation = 'Sandton, Johannesburg';

  final List<EmergencyContact> contacts = [
    const EmergencyContact(
      id: 1,
      name: 'Maria Thandiwe',
      relationship: 'Mother',
      phone: '+27 82 123 4567',
      initials: 'MT',
      avatarColor: Color(0xFFCDEFE8),
    ),
    const EmergencyContact(
      id: 2,
      name: 'Luvo Ndlovu',
      relationship: 'Brother',
      phone: '+27 71 987 6543',
      initials: 'LN',
      avatarColor: Color(0xFFD3E6FB),
    ),
    const EmergencyContact(
      id: 3,
      name: 'Zara Sibiya',
      relationship: 'Best Friend',
      phone: '+27 64 321 0987',
      initials: 'ZS',
      avatarColor: Color(0xFFE6DEF8),
    ),
  ];

  void toggleContact(int id) {
    final idx = contacts.indexWhere((c) => c.id == id);
    if (idx != -1) {
      contacts[idx] = contacts[idx].copyWith(enabled: !contacts[idx].enabled);
      notifyListeners();
    }
  }

  void addContact(String name, String relationship, String phone) {
    final nextId = contacts.isEmpty
        ? 1
        : contacts.map((c) => c.id).reduce((a, b) => a > b ? a : b) + 1;
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    var initials = parts.take(2).map((p) => p[0].toUpperCase()).join();
    if (initials.isEmpty) initials = '?';
    const palette = [
      Color(0xFFCDEFE8),
      Color(0xFFD3E6FB),
      Color(0xFFE6DEF8),
      Color(0xFFFBE3D0),
    ];
    contacts.add(
      EmergencyContact(
        id: nextId,
        name: name,
        relationship: relationship,
        phone: phone,
        initials: initials,
        avatarColor: palette[contacts.length % palette.length],
      ),
    );
    notifyListeners();
  }

  final List<AlertEvent> alertHistory = [
    const AlertEvent(
      id: 6,
      kind: AlertKind.emergencySent,
      title: 'Emergency sent',
      timeLabel: 'Today, 6:45 PM',
      locationLabel: 'Sandton, Johannesburg',
      status: AlertStatus.active,
    ),
    const AlertEvent(
      id: 5,
      kind: AlertKind.nearbyReceived,
      title: 'Nearby alert received',
      timeLabel: 'Today, 5:32 PM',
      locationLabel: '0.3 km away from you',
      status: AlertStatus.resolved,
    ),
    const AlertEvent(
      id: 4,
      kind: AlertKind.testSent,
      title: 'Test alert sent',
      timeLabel: 'Yesterday, 8:15 PM',
      locationLabel: 'Sandton, Johannesburg',
      status: AlertStatus.cancelled,
    ),
    const AlertEvent(
      id: 3,
      kind: AlertKind.nearbyReceived,
      title: 'Nearby alert received',
      timeLabel: 'Yesterday, 3:47 PM',
      locationLabel: '1.2 km away from you',
      status: AlertStatus.resolved,
    ),
    const AlertEvent(
      id: 2,
      kind: AlertKind.emergencySent,
      title: 'Emergency sent',
      timeLabel: '10 May 2025, 9:10 PM',
      locationLabel: 'Sandton, Johannesburg',
      status: AlertStatus.resolved,
    ),
    const AlertEvent(
      id: 1,
      kind: AlertKind.testSent,
      title: 'Test alert sent',
      timeLabel: '09 May 2025, 11:05 AM',
      locationLabel: 'Sandton, Johannesburg',
      status: AlertStatus.cancelled,
    ),
  ];

  bool isEmergencyActive = false;
  final nearbyPerson = const NearbyPerson(name: 'Ayanda', distanceLabel: '420 m away');

  Future<void> startEmergency() async {
    isEmergencyActive = true;
    final coords = await _location.getCurrentLocation();
    // Fire-and-forget: the panic alert is sent to the backend in the
    // background while the UI moves straight to the "Emergency Active" screen.
    _api.sendPanicAlert(latitude: coords.lat, longitude: coords.lng);

    final nextId = alertHistory.isEmpty
        ? 1
        : alertHistory.map((e) => e.id).reduce((a, b) => a > b ? a : b) + 1;
    alertHistory.insert(
      0,
      AlertEvent(
        id: nextId,
        kind: AlertKind.emergencySent,
        title: 'Emergency sent',
        timeLabel: 'Just now',
        locationLabel: currentLocation,
        status: AlertStatus.active,
      ),
    );
    notifyListeners();
  }

  Future<void> resolveEmergency() async {
    isEmergencyActive = false;
    final idx = alertHistory.indexWhere((e) => e.status == AlertStatus.active);
    if (idx != -1) {
      final resolvedId = alertHistory[idx].id;
      alertHistory[idx] = alertHistory[idx].copyWith(status: AlertStatus.resolved);
      _api.resolveAlert(resolvedId);
    }
    notifyListeners();
  }

  void setName(String name) {
    if (name.trim().isEmpty) return;
    userProfile = userProfile.copyWith(name: name);
    notifyListeners();
  }
}
