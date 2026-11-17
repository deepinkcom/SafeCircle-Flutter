import 'dart:async';
import 'dart:convert';
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
    _photoError =
        'The photo session changed. Close the editor and refresh after signing in.';
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
    bool current() =>
        _currentAuthentication(generation) &&
        uid == userProfile.uid &&
        version == _photoVersion;
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
      _userProfile = userProfile.copyWith(
          photoStoragePath: result.path, clearPhoto: result.path == null);
      _photoNeedsRefresh = false; // Metadata was read from the server.
      _photoError = result.warning;
      return true;
    } catch (error) {
      if (current()) {
        _photoError = error is ProfilePhotoFailure
            ? error.message
            : 'Your picture could not be loaded. Please retry.';
      }
      return false;
    } finally {
      if (current()) {
        _photoLoading = false;
        notifyListeners();
      }
    }
  }

  Future<ProfilePhotoDraft?> selectProfilePhoto(
      ProfilePhotoSource source) async {
    if (_disposed || !userProfile.isSignedIn || _photoBusy || _savingProfile) {
      return null;
    }
    final uid = userProfile.uid;
    final generation = _authGeneration;
    bool current() =>
        _currentAuthentication(generation) && uid == userProfile.uid;
    _photoBusy = true;
    _photoError = null;
    notifyListeners();
    try {
      final draft =
          await _photos.pick(uid: uid, source: source, isCurrent: current);
      if (!current()) {
        draft?.dispose();
        return null;
      }
      return draft;
    } catch (error) {
      if (current()) {
        _photoError = error is ProfilePhotoFailure
            ? error.message
            : 'Picture selection failed. Check access and try again.';
      }
      return null;
    } finally {
      if (current()) {
        _photoBusy = false;
        notifyListeners();
      }
    }
  }

  Future<bool> saveProfilePhoto(ProfilePhotoDraft draft) =>
      _changeProfilePhoto(draft);
  Future<bool> removeProfilePhoto() => _changeProfilePhoto(null);

  Future<bool> _changeProfilePhoto(ProfilePhotoDraft? draft) async {
    if (_disposed ||
        !userProfile.isSignedIn ||
        _photoBusy ||
        _savingProfile ||
        _photoNeedsRefresh) {
      return false;
    }
    if (draft == null && userProfile.photoStoragePath == null) return false;
    final uid = userProfile.uid;
    final generation = _authGeneration;
    final version = ++_photoVersion;
    bool current() =>
        _currentAuthentication(generation) &&
        uid == userProfile.uid &&
        version == _photoVersion;
    _photoBusy = true;
    _photoLoading = false;
    _photoError = null;
    _photoProgress = null;
    notifyListeners();
    try {
      final result = await _photos.save(
          uid: uid,
          expectedPath: userProfile.photoStoragePath,
          draft: draft,
          isCurrent: current,
          onProgress: (progress) {
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
      _userProfile = userProfile.copyWith(
          photoStoragePath: result.path, clearPhoto: result.path == null);
      _photoError = result.warning;
      return true;
    } catch (error) {
      if (current()) {
        _photoError = error is ProfilePhotoFailure
            ? error.message
            : 'Your picture could not be updated. Refresh before trying again.';
        _photoNeedsRefresh =
            error is! ProfilePhotoFailure || error.requiresRefresh;
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
      debugPrint(jsonEncode({
        'event': 'safe_circle_backend_profile',
        'stage': 'succeeded',
        'profile_ready': status.profileReady
      }));
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
      debugPrint(jsonEncode({
        'event': 'safe_circle_backend_profile',
        'stage': 'failed',
        'failure_kind': _backendProfileError!.kind.name,
        'api_http_status': _backendProfileError!.statusCode
      }));
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
    if (photoChanged &&
        profile.isSignedIn &&
        profile.photoStoragePath != null) {
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
    _stopEmergencyLocationUpdates();
    alertHistory.clear();
    isEmergencyActive = false;
    activeEmergencyPerson = null;
    emergencyLocationCache.clear();
    expiredEmergencyLocations.clear();
    nearbyPerson = null;
    currentLocation = '';
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

  /// Resolve the exact alert referenced by a recipient-owned notification.
  /// The backend enforces ownership and current accepted-connection access.
  Future<NearbyPerson?> findNotificationAlert(
      int notificationId, int expectedAlertId) async {
    final generation = _authGeneration;
    final Map<String, dynamic> row;
    try {
      row = await _api.fetchEmergencyAlertForNotification(notificationId);
    } on ApiFailure catch (failure) {
      if (failure.kind == ApiFailureKind.notFound ||
          failure.statusCode == 410) {
        return null;
      }
      rethrow;
    }
    if (!_currentAuthentication(generation) || row['id'] != expectedAlertId) {
      return null;
    }
    final lat = row['latitude'];
    final lng = row['longitude'];
    final ownerUserId = row['owner_user_id'];
    if (lat is! num || lng is! num || ownerUserId is! int || ownerUserId <= 0) {
      throw const ApiFailure(ApiFailureKind.invalidResponse);
    }
    final person = NearbyPerson(
        id: expectedAlertId,
        ownerUserId: ownerUserId,
        name: 'SafeCircle connection',
        distanceLabel: 'SafeCircle connection',
        locationLabel: row['location_label']?.toString() ?? '',
        status: 'active',
        createdAt: DateTime.parse(row['created_at'].toString()),
        latitude: lat.toDouble(),
        longitude: lng.toDouble());
    if (!person.hasValidLocation) {
      throw const ApiFailure(ApiFailureKind.invalidResponse);
    }
    emergencyLocationCache[expectedAlertId] = person;
    return person;
  }

  final List<AlertEvent> alertHistory = [];

  bool isEmergencyActive = false;
  NearbyPerson? nearbyPerson;
  NearbyPerson? activeEmergencyPerson;
  final Map<int, NearbyPerson> emergencyLocationCache = {};
  final Set<int> expiredEmergencyLocations = {};
  StreamSubscription<({double lat, double lng})>? _activeLocationSubscription;
  DateTime? locationUpdatedAt;
  String? locationUpdateError;

  /// Restore an owner's active alert from authenticated history and current
  /// owner-scoped location data; never trusts a client-supplied alert id alone.
  Future<bool> restoreActiveEmergency(AlertEvent event) async {
    if (event.kind != AlertKind.emergencySent ||
        event.status != AlertStatus.active ||
        !_userProfile.isSignedIn ||
        _backendProfile?.id == null ||
        !alertHistory.any((item) =>
            item.id == event.id &&
            item.kind == AlertKind.emergencySent &&
            item.status == AlertStatus.active)) {
      return false;
    }
    final generation = _authGeneration;
    final data = await _api.fetchAlertLocation(event.id);
    if (!_currentAuthentication(generation) ||
        data['id'] != event.id ||
        data['owner_user_id'] != _backendProfile?.id ||
        data['status'] != 'active') {
      return false;
    }
    final lat = data['latitude'];
    final lng = data['longitude'];
    if (lat != null && lat is! num || lng != null && lng is! num) {
      throw const ApiFailure(ApiFailureKind.invalidResponse);
    }
    final person = NearbyPerson(
      id: event.id,
      ownerUserId: _backendProfile!.id,
      name: _userProfile.name.trim().isEmpty ? 'You' : _userProfile.name.trim(),
      distanceLabel: 'Your location',
      locationLabel: event.locationLabel,
      status: 'active',
      createdAt: DateTime.now(),
      latitude: (lat as num?)?.toDouble(),
      longitude: (lng as num?)?.toDouble(),
    );
    if (person.hasValidLocation == false && (lat != null || lng != null)) {
      throw const ApiFailure(ApiFailureKind.invalidResponse);
    }
    isEmergencyActive = true;
    activeEmergencyPerson = person;
    locationUpdatedAt = null;
    locationUpdateError = null;
    emergencyLocationCache[event.id] = person;
    expiredEmergencyLocations.remove(event.id);
    _watchEmergencyLocation(event.id);
    notifyListeners();
    return true;
  }

  void _stopEmergencyLocationUpdates() {
    _activeLocationSubscription?.cancel();
    _activeLocationSubscription = null;
  }

  void _watchEmergencyLocation(int alertId) {
    _stopEmergencyLocationUpdates();
    _activeLocationSubscription = _location.watchLocation().listen(
      (coords) async {
        if (_disposed ||
            !isEmergencyActive ||
            activeEmergencyPerson?.id != alertId) {
          return;
        }
        final generation = _authGeneration;
        try {
          await _api.updateAlertLocation(
              alertId: alertId, latitude: coords.lat, longitude: coords.lng);
          if (!_currentAuthentication(generation) ||
              !isEmergencyActive ||
              activeEmergencyPerson?.id != alertId) {
            return;
          }
          activeEmergencyPerson = activeEmergencyPerson!.copyWith(
            latitude: coords.lat,
            longitude: coords.lng,
            locationUpdatedAt: DateTime.now(),
          );
          emergencyLocationCache[alertId] = activeEmergencyPerson!;
          locationUpdatedAt = DateTime.now();
          locationUpdateError = null;
          notifyListeners();
        } catch (_) {
          if (!_currentAuthentication(generation)) return;
          locationUpdateError =
              'Location update could not be sent. Showing the last reported location.';
          notifyListeners();
        }
      },
      onError: (_) {
        locationUpdateError =
            'Location updates are unavailable. Showing the last reported location.';
        notifyListeners();
      },
    );
  }

  Future<NearbyPerson?> refreshEmergencyLocation(NearbyPerson person) async {
    final generation = _authGeneration;
    final data = await _api.fetchAlertLocation(person.id);
    if (!_currentAuthentication(generation) || data['id'] != person.id) {
      return null;
    }
    final lat = data['latitude'];
    final lng = data['longitude'];
    if (lat is! num || lng is! num) {
      throw const FormatException('Invalid location response.');
    }
    final updated = person.copyWith(
      latitude: lat.toDouble(),
      longitude: lng.toDouble(),
      locationUpdatedAt: DateTime.now(),
    );
    if (!updated.hasValidLocation) {
      throw const FormatException('Invalid location response.');
    }
    if (activeEmergencyPerson?.id == person.id) {
      activeEmergencyPerson = updated;
    }
    if (nearbyPerson?.id == person.id) {
      nearbyPerson = updated;
    }
    emergencyLocationCache[person.id] = updated;
    expiredEmergencyLocations.remove(person.id);
    locationUpdatedAt = DateTime.now();
    locationUpdateError = null;
    notifyListeners();
    return updated;
  }

  void expireEmergencyLocation(int alertId) {
    emergencyLocationCache.remove(alertId);
    expiredEmergencyLocations.add(alertId);
    if (activeEmergencyPerson?.id == alertId) {
      activeEmergencyPerson = activeEmergencyPerson!
          .copyWith(status: 'resolved', clearLocation: true);
    }
    if (nearbyPerson?.id == alertId) {
      nearbyPerson = nearbyPerson!.copyWith(
        status: 'resolved',
        clearLocation: true,
      );
    }
    notifyListeners();
  }

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
      try {
        currentLocation = await _location.getReadableLocation(
            lat: coords.lat, lng: coords.lng);
      } catch (_) {
        currentLocation =
            '${coords.lat.toStringAsFixed(5)}, ${coords.lng.toStringAsFixed(5)}';
      }

      final backendAlertId = await _api.sendPanicAlert(
        latitude: coords.lat,
        longitude: coords.lng,
      );

      isEmergencyActive = true;
      activeEmergencyPerson = NearbyPerson(
        id: backendAlertId,
        ownerUserId: _backendProfile?.id,
        name: userProfile.name.trim().isEmpty ? 'You' : userProfile.name.trim(),
        distanceLabel: 'Your current location',
        locationLabel: currentLocation,
        status: 'active',
        createdAt: DateTime.now(),
        latitude: coords.lat,
        longitude: coords.lng,
        locationUpdatedAt: DateTime.now(),
      );
      emergencyLocationCache[backendAlertId] = activeEmergencyPerson!;
      locationUpdatedAt = DateTime.now();
      locationUpdateError = null;
      _watchEmergencyLocation(backendAlertId);

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
      unawaited(contactLinks.loadAcceptedRelationships());
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
    _stopEmergencyLocationUpdates();
    activeEmergencyPerson = null;
    if (idx != -1) {
      final resolvedId = alertHistory[idx].id;
      emergencyLocationCache.remove(resolvedId);
      expiredEmergencyLocations.add(resolvedId);
    }
    notifyListeners();
  }

  Future<void> resolveAlertById(int alertId) async {
    await _api.resolveAlert(alertId);
    final idx = alertHistory.indexWhere((e) => e.id == alertId);
    if (idx != -1) {
      alertHistory[idx] =
          alertHistory[idx].copyWith(status: AlertStatus.resolved);
    }
    if (activeEmergencyPerson?.id == alertId) {
      isEmergencyActive = false;
      _stopEmergencyLocationUpdates();
      activeEmergencyPerson = null;
    }
    emergencyLocationCache.remove(alertId);
    expiredEmergencyLocations.add(alertId);

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
        ownerUserId: alert['owner_user_id'] is int
            ? alert['owner_user_id'] as int
            : null,
        name: _acceptedConnectionName(alert['owner_user_id']),
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
        locationUpdatedAt: DateTime.now(),
      );
      emergencyLocationCache[nearbyPerson!.id] = nearbyPerson!;

      notifyListeners();
    } catch (error, stackTrace) {
      debugPrint('NEARBY ERROR: $error');
      debugPrint('$stackTrace');
    }
  }

  String _acceptedConnectionName(Object? ownerId) {
    if (ownerId is! int) return 'Emergency nearby';
    final match = contactLinks.accepted.items.where(
      (link) => link.isAccepted && link.otherUserId == ownerId,
    );
    if (match.isEmpty) return 'Emergency nearby';
    final name = match.first.otherUser?.name.trim() ?? '';
    return name.isEmpty ? 'SafeCircle connection' : name;
  }

  Future<void> acknowledgeNearbyAlert(
      {NearbyPerson? notificationAlert, int? notificationSession}) async {
    final session = notifications.sessionVersion;
    if (notificationSession != null && session != notificationSession) {
      throw const ApiFailure(ApiFailureKind.authentication);
    }
    final person = notificationAlert ?? nearbyPerson;

    if (person == null) return;

    final authGeneration = _authGeneration;
    final ownerUid = userProfile.uid;
    final relationshipSession = contactLinks.sessionVersion;
    final backendUserId = _backendProfile?.id;
    if (!userProfile.isSignedIn ||
        backendUserId == null ||
        !(_backendProfile?.profileReady ?? false) ||
        contactLinks.userId != ownerUid ||
        person.ownerUserId == null ||
        person.ownerUserId == backendUserId) {
      throw const ApiFailure(ApiFailureKind.forbidden);
    }

    final relationshipsLoaded = await contactLinks.loadAcceptedRelationships();
    if (!_currentAuthentication(authGeneration) ||
        notifications.sessionVersion != session ||
        contactLinks.sessionVersion != relationshipSession ||
        userProfile.uid != ownerUid) {
      throw const ApiFailure(ApiFailureKind.authentication);
    }
    if (!relationshipsLoaded) {
      throw contactLinks.accepted.error ??
          const ApiFailure(ApiFailureKind.forbidden);
    }
    final isAcceptedContact = contactLinks.accepted.items.any(
      (link) => link.isAccepted && link.otherUserId == person.ownerUserId,
    );
    if (!isAcceptedContact) {
      throw const ApiFailure(ApiFailureKind.forbidden);
    }

    final acknowledgement = await _api.acknowledgeAlert(person.id);
    if (!_currentAuthentication(authGeneration) ||
        session != notifications.sessionVersion ||
        relationshipSession != contactLinks.sessionVersion ||
        userProfile.uid != ownerUid) {
      return;
    }

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
