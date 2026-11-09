import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/location_service.dart';
import 'contact_links_state.dart';
import 'notifications_state.dart';
import '../services/api_failure.dart';
import '../models/backend_profile_status.dart';
import '../models/profile_photo.dart';
import '../services/profile_photo_service.dart';
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
    ProfilePhotoService? profilePhotoService,
  })  : _api = apiService ?? ApiService(),
        _location = locationService ?? LocationService(),
        _auth = authService ?? AuthService(),
        _photos = profilePhotoService ?? ProfilePhotoService() {
    _photos.onSessionInvalidated = _onPhotoSessionInvalidated;
    contactLinks = ContactLinksState(apiService: _api);
    contactLinks.addListener(_onContactLinksChanged);
    notifications = NotificationsState(apiService: _api);
    notifications.addListener(_onContactLinksChanged);
  }

  final ApiService _api;
  final LocationService _location;
  final AuthService _auth;
  final ProfilePhotoService _photos;
  late final ContactLinksState contactLinks;
  late final NotificationsState notifications;
  bool _disposed = false;
  int _authGeneration = 0;
  int _profileCheckVersion = 0;
  BackendProfileStatus? _backendProfile;
  ApiFailure? _backendProfileError;
  bool _checkingBackendProfile = false;
  bool _savingProfile = false;
  bool get savingProfile => _savingProfile;

  Uint8List? _photoBytes;
  bool _photoBusy = false;
  bool _photoLoading = false;
  bool _photoNeedsRefresh = false;
  double? _photoProgress;
  String? _photoError;
  int _photoVersion = 0;
  int _photoSessionGeneration = 0;
  Uint8List? get profilePhotoBytes =>
      _photos.isCurrentOwner(userProfile.uid) ? _photoBytes : null;
  bool get photoBusy => _photoBusy;
  bool get photoLoading => _photoLoading;
  bool get photoNeedsRefresh => _photoNeedsRefresh;
  bool get photoCameraSupported => _photos.cameraSupported;
  double? get photoProgress => _photoProgress;
  String? get photoError => _photoError;
  int get photoSessionVersion => _photoSessionGeneration;

  void _onPhotoSessionInvalidated() {
    if (_disposed) return;
    _photoVersion++;
    _photoSessionGeneration++;
    _discardPhotoBytes();
    _photoBusy = false;
    _photoLoading = false;
    _photoProgress = null;
    _photoNeedsRefresh = true;
    _photoError = 'The photo session changed. Close the editor and refresh after signing in.';
    notifyListeners();
  }

  void _discardPhotoBytes() {
    final bytes = _photoBytes;
    _photoBytes = null;
    if (bytes != null) {
      unawaited(MemoryImage(bytes).evict().catchError((Object _) => false));
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  void _resetProfilePhoto(String? uid) {
    _photoVersion++;
    _photoSessionGeneration++;
    _photos.setSession(uid);
    _discardPhotoBytes();
    _photoBusy = false;
    _photoLoading = false;
    _photoNeedsRefresh = false;
    _photoProgress = null;
    _photoError = null;
  }

  Future<bool> refreshProfilePhoto() async {
    if (_disposed || !userProfile.isSignedIn || _photoBusy) return false;
    final uid = userProfile.uid;
    final generation = _authGeneration;
    final version = ++_photoVersion;
    bool current() => _currentAuthentication(generation) &&
        uid == userProfile.uid && version == _photoVersion;
    _photoLoading = true;
    _photoError = null;
    notifyListeners();
    try {
      final result = await _photos.load(uid: uid, isCurrent: current);
      if (!current()) {
        final staleBytes = result.bytes;
        if (staleBytes != null) staleBytes.fillRange(0, staleBytes.length, 0);
        return false;
      }
      if (result.bytes != null || result.path != userProfile.photoStoragePath) {
        _discardPhotoBytes();
        _photoBytes = result.bytes;
      }
      _userProfile = userProfile.copyWith(photoStoragePath: result.path, clearPhoto: result.path == null);
      _photoNeedsRefresh = false; // Metadata was read from the server.
      _photoError = result.warning;
      return true;
    } catch (error) {
      if (current()) {
        _photoError = error is ProfilePhotoFailure
            ? error.message : 'Your picture could not be loaded. Please retry.';
      }
      return false;
    } finally {
      if (current()) {
        _photoLoading = false;
        notifyListeners();
      }
    }
  }

  Future<ProfilePhotoDraft?> selectProfilePhoto(ProfilePhotoSource source) async {
    if (_disposed || !userProfile.isSignedIn || _photoBusy || _savingProfile) return null;
    final uid = userProfile.uid;
    final generation = _authGeneration;
    bool current() => _currentAuthentication(generation) && uid == userProfile.uid;
    _photoBusy = true;
    _photoError = null;
    notifyListeners();
    try {
      final draft = await _photos.pick(uid: uid, source: source, isCurrent: current);
      if (!current()) {
        draft?.dispose();
        return null;
      }
      return draft;
    } catch (error) {
      if (current()) _photoError = error is ProfilePhotoFailure
          ? error.message : 'Picture selection failed. Check access and try again.';
      return null;
    } finally {
      if (current()) {
        _photoBusy = false;
        notifyListeners();
      }
    }
  }

  Future<bool> saveProfilePhoto(ProfilePhotoDraft draft) => _changeProfilePhoto(draft);
  Future<bool> removeProfilePhoto() => _changeProfilePhoto(null);

  Future<bool> _changeProfilePhoto(ProfilePhotoDraft? draft) async {
    if (_disposed || !userProfile.isSignedIn || _photoBusy || _savingProfile || _photoNeedsRefresh) {
      return false;
    }
    if (draft == null && userProfile.photoStoragePath == null) return false;
    final uid = userProfile.uid;
    final generation = _authGeneration;
    final version = ++_photoVersion;
    bool current() => _currentAuthentication(generation) &&
        uid == userProfile.uid && version == _photoVersion;
    _photoBusy = true;
    _photoLoading = false;
    _photoError = null;
    _photoProgress = null;
    notifyListeners();
    try {
      final result = await _photos.save(uid: uid, expectedPath: userProfile.photoStoragePath,
        draft: draft, isCurrent: current, onProgress: (progress) {
          if (current()) {
            _photoProgress = progress;
            notifyListeners();
          }
        });
      if (!current()) {
        final staleBytes = result.bytes;
        if (staleBytes != null) staleBytes.fillRange(0, staleBytes.length, 0);
        return false;
      }
      _discardPhotoBytes();
      _photoBytes = result.bytes;
      _userProfile = userProfile.copyWith(photoStoragePath: result.path, clearPhoto: result.path == null);
      _photoError = result.warning;
      return true;
    } catch (error) {
      if (current()) {
        _photoError = error is ProfilePhotoFailure
            ? error.message : 'Your picture could not be updated. Refresh before trying again.';
        _photoNeedsRefresh = error is! ProfilePhotoFailure || error.requiresRefresh;
      }
      return false;
    } finally {
      if (current()) {
        _photoBusy = false;
        _photoProgress = null;
        notifyListeners();
      }
    }
  }

  BackendProfileStatus? get backendProfile => _backendProfile;
  ApiFailure? get backendProfileError => _backendProfileError;
  bool get checkingBackendProfile => _checkingBackendProfile;

  void _resetBackendProfile() {
    _profileCheckVersion++;
    _backendProfile = null;
    _backendProfileError = null;
    _checkingBackendProfile = false;
    _savingProfile = false;
  }

  Future<bool> checkBackendProfile() async {
    if (_disposed || !userProfile.isSignedIn) return false;
    final generation = _authGeneration;
    final owner = userProfile.uid;
    final version = ++_profileCheckVersion;
    bool current() =>
        _currentAuthentication(generation) &&
        owner == userProfile.uid &&
        version == _profileCheckVersion;
    _checkingBackendProfile = true;
    _backendProfileError = null;
    notifyListeners();
    if (!current()) return false;
    try {
      final status = await _api.fetchMyProfileStatus();
      if (!current()) return false;
      _backendProfile = status;
      if (status.profileReady && current()) {
        if (contactLinks.needsBackendProfile) {
          await contactLinks.retryAccess();
        }
        if (current() && notifications.needsBackendProfile) {
          await notifications.retryAccess();
        }
      }
      if (!current()) return false;
      return status.profileReady;
    } catch (error) {
      if (!current()) return false;
      _backendProfileError = error is ApiFailure
          ? error
          : const ApiFailure(ApiFailureKind.unexpected);
      return false;
    } finally {
      if (current()) {
        _checkingBackendProfile = false;
        notifyListeners();
      }
    }
  }

  UserProfile _userProfile = const UserProfile(
    name: '',
    city: '',
    email: '',
    phone: '',
  );

  UserProfile get userProfile => _userProfile;

  set userProfile(UserProfile profile) {
    if (_disposed) return;
    final photoChanged = profile.uid != _userProfile.uid ||
        profile.photoStoragePath != _userProfile.photoStoragePath ||
        !_photos.sessionMatches(profile.uid);
    if (profile.uid != _userProfile.uid) {
      _authGeneration++;
      _resetBackendProfile();
    }
    _userProfile = profile;
    if (photoChanged) {
      _resetProfilePhoto(profile.uid);
    }
    contactLinks.setSession(profile.uid);
    notifications.setSession(_userProfile.uid);
    if (photoChanged && profile.isSignedIn && profile.photoStoragePath != null) {
      unawaited(refreshProfilePhoto());
    }
  }

  void _onContactLinksChanged() {
    if (!_disposed) notifyListeners();
  }

  int _beginAuthentication() {
    final generation = ++_authGeneration;
    _resetBackendProfile();
    _resetProfilePhoto(null);
    contactLinks.setSession(null);
    if (_authGeneration == generation) notifications.setSession(null);
    return generation;
  }

  bool _currentAuthentication(int generation) =>
      !_disposed && generation == _authGeneration;

  String currentLocation = '';

  void setName(String name) {
    userProfile = userProfile.copyWith(name: name);
    notifyListeners();
  }

  /// Restores the signed-in profile from Firebase Auth + Firestore.
  /// Returns true when a session was found.
  Future<bool> restoreSession() async {
    if (_disposed) return false;
    final generation = _beginAuthentication();
    if (!_currentAuthentication(generation)) return false;
    try {
      final profile = await _auth.restoreProfile();
      if (!_currentAuthentication(generation)) return false;
      if (profile == null) {
        return false;
      }
      userProfile = profile;
      final boundGeneration = _authGeneration;
      notifyListeners();
      if (!_currentAuthentication(boundGeneration)) return false;
      await checkBackendProfile();
      return _currentAuthentication(boundGeneration) &&
          userProfile.uid == profile.uid;
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
    if (_disposed) return 'This sign-in attempt is no longer active.';
    final generation = _beginAuthentication();
    if (!_currentAuthentication(generation)) {
      return 'This sign-in attempt is no longer active.';
    }
    try {
      final profile = await _auth.signUp(
        fullName: fullName,
        email: email,
        phone: phone,
        password: password,
      );
      if (!_currentAuthentication(generation)) {
        return 'This sign-in attempt is no longer active.';
      }
      userProfile = profile;
      final boundGeneration = _authGeneration;
      notifyListeners();
      if (!_currentAuthentication(boundGeneration)) {
        return 'This sign-in attempt is no longer active.';
      }
      await checkBackendProfile();
      if (!_currentAuthentication(boundGeneration) ||
          userProfile.uid != profile.uid) {
        return 'This sign-in attempt is no longer active.';
      }
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
    if (_disposed) return 'This sign-in attempt is no longer active.';
    final generation = _beginAuthentication();
    if (!_currentAuthentication(generation)) {
      return 'This sign-in attempt is no longer active.';
    }
    try {
      final profile = await _auth.logIn(email: email, password: password);
      if (!_currentAuthentication(generation)) {
        return 'This sign-in attempt is no longer active.';
      }
      userProfile = profile;
      final boundGeneration = _authGeneration;
      notifyListeners();
      if (!_currentAuthentication(boundGeneration)) {
        return 'This sign-in attempt is no longer active.';
      }
      await checkBackendProfile();
      if (!_currentAuthentication(boundGeneration) ||
          userProfile.uid != profile.uid) {
        return 'This sign-in attempt is no longer active.';
      }
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
    if (_disposed) return 'This profile update is no longer active.';
    if (_savingProfile || _photoBusy) {
      return 'Your details are already being saved. Please wait.';
    }
    if (!userProfile.isSignedIn) {
      return 'Please sign in before updating your details.';
    }
    if (name.trim().isEmpty || phone.trim().isEmpty || city.trim().isEmpty) {
      return 'Enter your name, phone and city to complete your SafeCircle profile.';
    }
    if (name.trim().length > 255 ||
        phone.trim().length > 50 ||
        city.trim().length > 100) {
      return 'Your name, phone or city is too long. Please shorten it.';
    }
    final generation = _authGeneration;
    final owner = userProfile.uid;
    _savingProfile = true;
    try {
      final updatedProfile = await _auth.updateProfile(
        userProfile.copyWith(
          name: name.trim(),
          phone: phone.trim(),
          city: city.trim(),
        ),
      );

      if (!_currentAuthentication(generation)) {
        return 'This profile update is no longer active.';
      }
      if (updatedProfile.uid != owner) {
        return 'The account changed. Please sign in again.';
      }
      // The text-only repository update must not roll back a concurrent photo read.
      userProfile = updatedProfile.copyWith(
        photoStoragePath: userProfile.photoStoragePath,
        clearPhoto: userProfile.photoStoragePath == null,
      );
      notifyListeners();

      if (updatedProfile.uid.isEmpty ||
          updatedProfile.name.trim().isEmpty ||
          updatedProfile.email.trim().isEmpty ||
          updatedProfile.phone.trim().isEmpty ||
          updatedProfile.city.trim().isEmpty) {
        return 'Your profile was saved, but some required details are missing.';
      }

      if (!_currentAuthentication(generation)) {
        return 'This profile update is no longer active.';
      }
      await _api.syncMyProfile(
        name: updatedProfile.name,
        city: updatedProfile.city,
        phone: updatedProfile.phone,
      );

      if (!_currentAuthentication(generation)) {
        return 'This profile update is no longer active.';
      }
      final ready = await checkBackendProfile();
      if (!_currentAuthentication(generation)) {
        return 'This profile update is no longer active.';
      }
      if (!ready) {
        return 'Your details were saved. Retry the account check to confirm server synchronization.';
      }
      return null;
    } on AuthFailure catch (error) {
      return error.message;
    } catch (error) {
      return 'Your profile was saved, but syncing with the server failed. '
          'Please check your connection and try again.';
    } finally {
      if (_currentAuthentication(generation)) _savingProfile = false;
    }
  }

  Future<void> logOut() async {
    if (_disposed) return;
    final generation = _beginAuthentication();
    if (!_currentAuthentication(generation)) return;
    await _auth.logOut();
    if (!_currentAuthentication(generation)) return;
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
    final generation = _authGeneration;
    final data = await _api.fetchAlertHistory();
    if (!_currentAuthentication(generation)) return;
    _setAlertHistory(data);
  }

  void _setAlertHistory(List<Map<String, dynamic>> data) {
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

  /// Resolve only a source returned by the caller's real authorized history.
  Future<bool> loadNotificationAlertHistory(int alertId) async {
    final generation = _authGeneration;
    final data = await _api.fetchAlertHistory();
    if (!_currentAuthentication(generation)) return false;
    final accessible = data.any((row) =>
        (row['kind'] == 'nearby_received' ? row['alert_id'] : row['id']) ==
        alertId);
    if (accessible) _setAlertHistory(data);
    return _currentAuthentication(generation) && accessible;
  }

  /// Match the notification ID exactly; never substitute the nearest alert.
  Future<NearbyPerson?> findNotificationNearbyAlert(int alertId) async {
    final generation = _authGeneration;
    final position = await _location.getCurrentLocation();
    if (!_currentAuthentication(generation)) return null;
    final data = await _api.fetchNearbyAlerts(
        latitude: position.lat, longitude: position.lng);
    if (!_currentAuthentication(generation)) return null;
    final row = data
        .where((row) => row['id'] == alertId && row['status'] == 'active')
        .firstOrNull;
    if (row == null) return null;
    final distance = row['distance_km'];
    final lat = row['latitude'];
    final lng = row['longitude'];
    if (distance is! num ||
        !distance.isFinite ||
        distance < 0 ||
        lat is! num ||
        lng is! num) {
      throw const ApiFailure(ApiFailureKind.invalidResponse);
    }
    final person = NearbyPerson(
        id: alertId,
        name: 'Emergency nearby',
        distanceLabel: '$distance km away',
        locationLabel: row['location_label']?.toString() ?? '',
        status: 'active',
        createdAt: DateTime.parse(row['created_at'].toString()),
        latitude: lat.toDouble(),
        longitude: lng.toDouble());
    if (!person.hasValidLocation) {
      throw const ApiFailure(ApiFailureKind.invalidResponse);
    }
    return person;
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
      alertHistory[idx] =
          alertHistory[idx].copyWith(status: AlertStatus.resolved);
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

        // Use actual emergency coordinates if provided by FastAPI.
        latitude: double.tryParse(
          alert['latitude']?.toString() ?? '',
        ),
        longitude: double.tryParse(
          alert['longitude']?.toString() ?? '',
        ),
      );

      notifyListeners();
    } catch (error, stackTrace) {
      debugPrint('NEARBY ERROR: $error');
      debugPrint('$stackTrace');
    }
  }

  Future<void> acknowledgeNearbyAlert(
      {NearbyPerson? notificationAlert, int? notificationSession}) async {
    final session = notifications.sessionVersion;
    if (notificationSession != null && session != notificationSession) {
      throw const ApiFailure(ApiFailureKind.authentication);
    }
    final person = notificationAlert ?? nearbyPerson;

    if (person == null) return;

    final acknowledgement = await _api.acknowledgeAlert(person.id);
    if (_disposed || session != notifications.sessionVersion) return;

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

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _authGeneration++;
    _resetBackendProfile();
    _resetProfilePhoto(null);
    _photos.dispose();
    contactLinks.removeListener(_onContactLinksChanged);
    contactLinks.dispose();
    notifications.removeListener(_onContactLinksChanged);
    notifications.dispose();
    super.dispose();
  }
}
