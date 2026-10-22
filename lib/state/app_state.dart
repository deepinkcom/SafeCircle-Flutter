import 'package:flutter/material.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/location_service.dart';
import 'package:intl/intl.dart';

/// Central, observable app state. Screens read from this via
/// `context.watch<AppState>()` / `context.read<AppState>()`.
///
/// User profiles are stored in Cloud Firestore (`users/{uid}`). Contacts,
/// alerts, and location still go through the API and location services.
class AppState extends ChangeNotifier {
  AppState({
    ApiService? apiService,
    LocationService? locationService,
    AuthService? authService,
  })  : _api = apiService ?? ApiService(),
        _location = locationService ?? LocationService(),
        _auth = authService ?? AuthService();

  final ApiService _api;
  final LocationService _location;
  final AuthService _auth;

  UserProfile userProfile = const UserProfile(
      name: '',
      city: '',
      email: '',
      phone: '',
    );

  String currentLocation = '';

  void setName(String name) {
  userProfile = userProfile.copyWith(name: name);
  notifyListeners();
  }

  /// Restores the signed-in profile from Firebase Auth + Firestore.
  /// Returns true when a session was found.
  Future<bool> restoreSession() async {
    try {
      final profile = await _auth.restoreProfile();
      if (profile == null) return false;
      userProfile = profile;
      notifyListeners();
      return true;
    } on AuthFailure catch (error) {
      debugPrint('AUTH: restore failed: $error');
      return false;
    } catch (error) {
      debugPrint('AUTH: restore failed: $error');
      return false;
    }
  }

  Future<String?> signUp({
    required String fullName,
    required String email,
    required String phone,
    required String password,
  }) async {
    try {
      userProfile = await _auth.signUp(
        fullName: fullName,
        email: email,
        phone: phone,
        password: password,
      );
      notifyListeners();
      return null;
    } on AuthFailure catch (error) {
      return error.message;
    } catch (_) {
      return 'Something went wrong. Please try again.';
    }
  }

  Future<String?> logIn({
    required String email,
    required String password,
  }) async {
    try {
      userProfile = await _auth.logIn(email: email, password: password);
      notifyListeners();
      return null;
    } on AuthFailure catch (error) {
      return error.message;
    } catch (_) {
      return 'Something went wrong. Please try again.';
    }
  }


  Future<String?> updateProfile({
    required String name,
    required String phone,
    required String city,
  }) async {
    try {
      final updatedProfile = await _auth.updateProfile(
        userProfile.copyWith(
          name: name.trim(),
          phone: phone.trim(),
          city: city.trim(),
        ),
      );

      userProfile = updatedProfile;
      notifyListeners();

      if (updatedProfile.uid.isEmpty ||
          updatedProfile.name.trim().isEmpty ||
          updatedProfile.email.trim().isEmpty ||
          updatedProfile.phone.trim().isEmpty ||
          updatedProfile.city.trim().isEmpty) {
        return 'Your profile was saved, but some required details are missing.';
      }

      await _api.syncMyProfile(
        name: updatedProfile.name,
        city: updatedProfile.city,
        phone: updatedProfile.phone,
      );

      return null;
    } on AuthFailure catch (error) {
      return error.message;
    } catch (error) {
      debugPrint('PROFILE SYNC ERROR: $error');
      return 'Your profile was saved, but syncing with the server failed. '
          'Please check your connection and try again.';
    }
  }


  Future<void> logOut() async {
    await _auth.logOut();
    userProfile = const UserProfile(name: '', city: '', email: '', phone: '');
    contacts.clear();
    alertHistory.clear();
    isEmergencyActive = false;
    nearbyPerson = null;
    currentLocation = '';
    notifyListeners();
  }

  final List<EmergencyContact> contacts = [];

  Future<void> toggleContact(int id) async {
  final idx = contacts.indexWhere((c) => c.id == id);

  if (idx == -1) return;

  final contact = contacts[idx];
  final newEnabled = !contact.enabled;

  final data = await _api.updateContact(
    contactId: id,
    enabled: newEnabled,
  );

  contacts[idx] = contact.copyWith(
    enabled: data['enabled'] as bool? ?? newEnabled,
  );

  notifyListeners();
}

Future<void> editContact(
  int id,
  String name,
  String relationship,
  String phone,
) async {
  final idx = contacts.indexWhere((c) => c.id == id);

  if (idx == -1) return;

  final data = await _api.updateContact(
    contactId: id,
    name: name,
    relationship: relationship,
    phone: phone,
  );

  final contact = contacts[idx];

  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
  var initials = parts.take(2).map((p) => p[0].toUpperCase()).join();
  if (initials.isEmpty) initials = '?';

  contacts[idx] = EmergencyContact(
    id: data['id'] as int,
    name: data['name'] as String,
    relationship: data['relationship'] as String,
    phone: data['phone'] as String,
    initials: initials,
    avatarColor: contact.avatarColor,
    enabled: data['enabled'] as bool? ?? contact.enabled,
  );

  notifyListeners();
}

  Future<void> loadContacts() async {
  final data = await _api.fetchContacts();
  debugPrint('CONTACTS: backend returned ${data.length} contact(s)');

  contacts
    ..clear()
    ..addAll(
      data.map(
        (contact) => EmergencyContact(
          id: contact['id'] as int,
          name: contact['name'] as String,
          relationship: contact['relationship'] as String,
          phone: contact['phone'] as String,
          initials: contact['name']
              .toString()
              .trim()
              .split(RegExp(r'\s+'))
              .take(2)
              .map((part) => part[0].toUpperCase())
              .join(),
          avatarColor: const Color(0xFFCDEFE8),
          enabled: contact['enabled'] as bool? ?? true,
        ),
      ),
    );
    debugPrint('CONTACTS: AppState now contains ${contacts.length} contact(s)');
  notifyListeners();
}

Future<void> loadAlertHistory() async {
  final data = await _api.fetchAlertHistory();

  alertHistory
    ..clear()
    ..addAll(
      data.map(
        (alert) => AlertEvent(
          id: alert['id'] as int,
          kind: switch (alert['kind']?.toString()) {
            'nearby_received' => AlertKind.nearbyReceived,
            'test' => AlertKind.testSent,
            _ => AlertKind.emergencySent,
          },
          title: switch (alert['kind']?.toString()) {
            'nearby_received' => 'Responded to nearby emergency',
            _ => 'Emergency sent',
          },
          timeLabel: DateFormat('d MMM yyyy, HH:mm').format(
            DateTime.parse(alert['created_at'].toString()).toLocal(),
          ),
          locationLabel: alert['location_label']?.toString() ?? '',
          status: switch (alert['status']?.toString()) {
            'resolved' => AlertStatus.resolved,
            'cancelled' => AlertStatus.cancelled,
            'on_my_way' => AlertStatus.acknowledged,
            _ => AlertStatus.active,
          },
        ),
      ),
    );

  notifyListeners();
}

  Future<void> addContact(
      String name,
      String relationship,
      String phone,
    ) async {
      final data = await _api.createContact(
        name: name,
        relationship: relationship,
        phone: phone,
      );

      final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
      var initials = parts.take(2).map((p) => p[0].toUpperCase()).join();
      if (initials.isEmpty) initials = '?';

      contacts.add(
        EmergencyContact(
          id: data['id'] as int,
          name: data['name'] as String,
          relationship: data['relationship'] as String,
          phone: data['phone'] as String,
          initials: initials,
          avatarColor: const Color(0xFFCDEFE8),
          enabled: data['enabled'] as bool? ?? true,
        ),
      );

      notifyListeners();
    }

  final List<AlertEvent> alertHistory = [];

  bool isEmergencyActive = false;
  NearbyPerson? nearbyPerson;

  Future<void> loadCurrentLocation() async {
  debugPrint('LOCATION: loadCurrentLocation() started');

  final coords = await _location.getCurrentLocation();

  debugPrint(
    'LOCATION: GPS = ${coords.lat}, ${coords.lng}',
  );

  currentLocation = await _location.getReadableLocation(
    lat: coords.lat,
    lng: coords.lng,
  );

  debugPrint(
    'LOCATION: readable = $currentLocation',
  );

  notifyListeners();
}


Future<void> startEmergency() async {
  try {
    final coords = await _location.getCurrentLocation();

    currentLocation = await _location.getReadableLocation(
      lat: coords.lat,
      lng: coords.lng,
    );

    final backendAlertId = await _api.sendPanicAlert(
      latitude: coords.lat,
      longitude: coords.lng,
    );

    isEmergencyActive = true;

    alertHistory.insert(
      0,
      AlertEvent(
        id: backendAlertId,
        kind: AlertKind.emergencySent,
        title: 'Emergency sent',
        timeLabel: 'Just now',
        locationLabel: currentLocation,
        status: AlertStatus.active,
      ),
    );

    notifyListeners();
  } catch (e, stackTrace) {
    debugPrint('EMERGENCY: failed to start: $e');
    debugPrintStack(stackTrace: stackTrace);
    rethrow;
  }
}



  Future<void> resolveEmergency() async {
    final idx = alertHistory.indexWhere((e) => e.status == AlertStatus.active);

    if (idx != -1) {
      final resolvedId = alertHistory[idx].id;

      // Resolve the alert on the backend first.
      // If this fails, keep the local emergency state active.
      await _api.resolveAlert(resolvedId);

      alertHistory[idx] = alertHistory[idx].copyWith(
        status: AlertStatus.resolved,
      );
    }

    isEmergencyActive = false;
    notifyListeners();
  }


  Future<void> resolveAlertById(int alertId) async {
  final idx = alertHistory.indexWhere((e) => e.id == alertId);

  if (idx != -1) {
    alertHistory[idx] = alertHistory[idx].copyWith(status: AlertStatus.resolved);
  }

  await _api.resolveAlert(alertId);

  notifyListeners();
}

  Future<List<Map<String, dynamic>>> fetchNearbyAlerts() async {
  final coords = await _location.getCurrentLocation();

  return _api.fetchNearbyAlerts(
    latitude: coords.lat,
    longitude: coords.lng,
  );
}

  Future<void> loadNearbyAlert() async {
  debugPrint('NEARBY: loadNearbyAlert() started');

  try {
    final alerts = await fetchNearbyAlerts();

    debugPrint('NEARBY: received ${alerts.length} alert(s)');

    if (alerts.isEmpty) {
      nearbyPerson = null;
      notifyListeners();
      return;
    }

    final alert = alerts.first;

    debugPrint('NEARBY: first alert = $alert');

    nearbyPerson = NearbyPerson(
      id: alert['id'] as int,
      name: 'Emergency nearby',
      distanceLabel: '${alert['distance_km']} km away',
      locationLabel: alert['location_label']?.toString() ?? '',
      status: alert['status']?.toString() ?? 'active',
      createdAt: DateTime.parse(alert['created_at'].toString()),
    );

    notifyListeners();
  } catch (error, stackTrace) {
    debugPrint('NEARBY ERROR: $error');
    debugPrint('$stackTrace');
  }
}

Future<void> acknowledgeNearbyAlert() async {
  final person = nearbyPerson;

  if (person == null) return;

  final acknowledgement = await _api.acknowledgeAlert(person.id);

  alertHistory.insert(
    0,
    AlertEvent(
      id: acknowledgement['id'] as int,
      kind: AlertKind.nearbyReceived,
      title: 'Responded to nearby emergency',
      timeLabel: 'Just now',
      locationLabel: person.locationLabel.isNotEmpty
          ? person.locationLabel
          : person.distanceLabel,
      status: AlertStatus.acknowledged,
    ),
  );

  notifyListeners();
}
}
