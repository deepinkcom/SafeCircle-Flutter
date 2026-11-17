import 'dart:async';
import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'api_service.dart';
import 'api_failure.dart';
import 'installation_identity.dart';
import '../models/app_notification.dart';

class DeviceCleanupUnverified implements Exception {
  const DeviceCleanupUnverified(this.message);

  final String message;
}

class NotificationService {
  NotificationService({
    FirebaseMessaging? messaging,
    ApiService? apiService,
    InstallationIdentity? installationIdentity,
    String? Function()? currentUserId,
    void Function(Map<String, Object?> event)? diagnostics,
  })  : _currentUserId =
            currentUserId ?? (() => FirebaseAuth.instance.currentUser?.uid),
        _messaging = messaging,
        _apiService = apiService ?? ApiService(),
        _installationIdentity = installationIdentity ?? InstallationIdentity(),
        _diagnostics = diagnostics;

  final FirebaseMessaging? _messaging;
  final ApiService _apiService;
  final InstallationIdentity _installationIdentity;
  final String? Function() _currentUserId;
  final void Function(Map<String, Object?> event)? _diagnostics;
  String? _boundUser;
  bool _disposed = false;
  bool _detaching = false;
  _DeviceSession? _deviceSession, _logoutSession;
  final List<_DeviceSession> _retired = [];
  Future<void> _tail = Future<void>.value();
  Future<void>? _detachTransport;

  void _logCleanup(String stage, [Map<String, Object?> fields = const {}]) {
    final event = <String, Object?>{
      'event': 'safe_circle_logout_cleanup',
      'stage': stage,
      ...fields,
    };
    try {
      if (_diagnostics case final diagnostics?) {
        diagnostics(event);
      } else {
        debugPrint(jsonEncode(event));
      }
    } catch (_) {
      // Diagnostics must never change whether privacy cleanup succeeds.
    }
  }

  void _logCleanupException(String stage, Object error) {
    _logCleanup(stage, {
      'exception_type': error is TimeoutException
          ? 'TimeoutException'
          : error.runtimeType.toString(),
      if (error is FirebaseException) 'firebase_exception_code': error.code,
    });
  }

  String? _signedInUser() {
    try {
      return _currentUserId();
    } catch (_) {
      return null;
    }
  }

  bool _currentDeviceSession(_DeviceSession session) =>
      !_disposed &&
      identical(_deviceSession, session) &&
      !session.retired &&
      _boundUser == session.owner &&
      _signedInUser() == session.owner;

  Future<void> _enqueue(Future<void> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> _cleanSession(_DeviceSession session) async {
    _logCleanup('installation_cleanup_started', {
      'previously_registered_token_known': session.tokens.isNotEmpty,
    });
    try {
      session.installationId ??= await _installationIdentity.id;
    } catch (error) {
      _logCleanupException('installation_id_unavailable', error);
      throw const DeviceCleanupUnverified(
          'SafeCircle could not access this phone\'s secure installation record. Keep this account signed in and retry sign out.');
    }

    _logCleanup('retired_session_cleanup_started', {
      'previously_registered_token_known': session.tokens.isNotEmpty,
    });
    if (_signedInUser() == session.owner) {
      if (session.auth != null) {
        // Normal logout refreshes the old owner's bearer before sign-out.
        try {
          final fresh = await _apiService.openDeviceRegistrationSession(
              isCurrent: () => _signedInUser() == session.owner,
              onUnregisterResponseStatus: (statusCode) => _logCleanup(
                  'backend_delete_response', {'api_http_status': statusCode}));
          session.auth?.close();
          session.auth = fresh;
        } on ApiFailure {
          // An account may change while the refresh is pending. Only the
          // already captured old-owner bearer is a permissible fallback.
          if (session.auth == null) rethrow;
        }
      }
    }

    if (session.auth == null) {
      if (_signedInUser() != session.owner) {
        throw const ApiFailure(ApiFailureKind.authentication);
      }
      session.auth = await _apiService.openDeviceRegistrationSession(
          isCurrent: () => _signedInUser() == session.owner,
          onUnregisterResponseStatus: (statusCode) => _logCleanup(
              'backend_cleanup_response', {'api_http_status': statusCode}));
    }

    if (!session.installationRevoked) {
      var currentToken = session.registeredToken;
      InstallationCleanupResult cleanup;
      try {
        cleanup = await session.auth!.unregisterInstallation(
          session.installationId!,
          currentFcmToken: currentToken,
        );
      } on ApiFailure catch (error) {
        _logCleanup('installation_cleanup_failed', {
          'api_http_status': error.statusCode,
          'backend_cleanup_confirmed': false,
        });
        if (error.statusCode == 404) {
          throw const DeviceCleanupUnverified(
              'This SafeCircle app needs a server update to securely sign out. Keep this account signed in and contact the demonstration administrator.');
        }
        rethrow;
      }
      if (cleanup.unattributedLegacyRegistrationsRemain &&
          (currentToken == null || currentToken.trim().isEmpty)) {
        _logCleanup('legacy_token_lookup_started', {
          'previously_registered_token_known': false,
        });
        try {
          // Only use the current FCM token to attribute its own legacy row.
          // The backend rejects a token owned by another account/install.
          // ignore: deprecated_member_use
          currentToken = await _firebaseMessaging
              // ignore: deprecated_member_use
              .getToken()
              .timeout(_apiService.requestTimeout);
          _logCleanup('legacy_token_lookup_finished', {
            'current_token_retrieval_succeeded': true,
            'current_token_available':
                currentToken != null && currentToken.trim().isNotEmpty,
          });
        } catch (error) {
          _logCleanupException('legacy_token_lookup_failed', error);
          _logCleanup('legacy_token_lookup_result', {
            'current_token_retrieval_succeeded': false,
          });
        }
        if (currentToken != null && currentToken.trim().isNotEmpty) {
          cleanup = await session.auth!.unregisterInstallation(
            session.installationId!,
            currentFcmToken: currentToken,
          );
        }
      }
      _logCleanup('installation_cleanup_response', {
        'backend_cleanup_confirmed': !cleanup.installationRegistrationsRemain &&
            !(cleanup.unattributedLegacyRegistrationsRemain &&
                (currentToken == null || currentToken.trim().isEmpty)),
        'installation_registrations_revoked': cleanup.revokedCount,
        'installation_registrations_remain':
            cleanup.installationRegistrationsRemain,
        'unattributed_legacy_registrations_remain':
            cleanup.unattributedLegacyRegistrationsRemain,
      });
      if (cleanup.installationRegistrationsRemain ||
          (cleanup.unattributedLegacyRegistrationsRemain &&
              (currentToken == null || currentToken.trim().isEmpty))) {
        _logCleanup('cleanup_unverified', {
          'backend_cleanup_confirmed': false,
          'previously_registered_token_known': session.tokens.isNotEmpty,
        });
        throw const DeviceCleanupUnverified(
            'SafeCircle found a registration from an older app version that cannot be tied to this phone. This phone\'s identified registrations were revoked, but sign out is paused to prevent notifications reaching the wrong account. Reopen SafeCircle on each previously used phone and account to update its registration, then retry.');
      }
      if (cleanup.unattributedLegacyRegistrationsRemain) {
        _logCleanup('unattributed_legacy_registrations_preserved', {
          'previously_registered_token_known': session.tokens.isNotEmpty,
          'current_token_retrieval_succeeded':
              currentToken != null && currentToken.trim().isNotEmpty,
        });
      }
      session.installationRevoked = true;
    }

    session.auth?.close();
    session.auth = null;
    _logCleanup('retired_session_cleanup_complete', {
      'previously_registered_token_known': session.cleaned.isNotEmpty,
      'backend_cleanup_confirmed': session.installationRevoked,
    });
  }

  Future<void> _cleanRetired() async {
    for (final session in _retired.toList()) {
      await _cleanSession(session);
      _retired.remove(session);
    }
  }

  final Set<String> _shown = {};
  final Map<String, DateTime> _tapped = {};
  StreamSubscription<RemoteMessage>? _openedSubscription;
  StreamSubscription<String>? _tokenSubscription;
  void Function()? onInboxChanged;
  void Function(int notificationId)? onNotificationTap;
  void bindUser(String? uid) {
    if (_disposed) return;
    if (_boundUser != uid) {
      final old = _deviceSession;
      if (old != null) {
        old.retired = true;
        _retired.add(old);
      }
      _deviceSession = uid == null ? null : _DeviceSession(uid);
      _boundUser = uid;
      _shown.clear();
      _tapped.clear();
      if (_retired.isNotEmpty && !_detaching) {
        // Retain failed cleanup as a barrier; a new account cannot register
        // until the old authenticated cleanup has succeeded.
        unawaited(_enqueue(_cleanRetired).catchError((Object _) {}));
      }
    }
  }

  int? validNotification(RemoteMessage message) {
    if (_boundUser == null ||
        _currentUserId() != _boundUser ||
        message.data['recipient_uid'] != _boundUser) {
      return null;
    }
    final id = int.tryParse(message.data['notification_id']?.toString() ?? '');
    return id != null && id > 0 ? id : null;
  }

  Future<void> receive(RemoteMessage message, {bool tap = false}) async {
    final id = validNotification(message);
    if (id == null) return;
    final owner = _boundUser;
    if (tap) {
      final key = '$owner:$id';
      final now = DateTime.now();
      if (_tapped[key] != null && now.difference(_tapped[key]!).inSeconds < 2) {
        return;
      }
      if (_tapped.length > 512) _tapped.clear();
      _tapped[key] = now;
      onNotificationTap?.call(id);
      return;
    }
    try {
      final inboxNotification = await _apiService.fetchNotification(id);
      // The authenticated inbox row is authoritative for event type and copy.
      if (owner != _boundUser || validNotification(message) != id) return;
      onInboxChanged?.call();
      if (_shown.length > 512) _shown.clear();
      if (!_shown.add('$owner:$id')) return;
      await showNotification(message, inboxNotification: inboxNotification);
    } catch (_) {
      /* Offline/deleted notifications are not fabricated locally. */
    }
  }

  Future<void> detachDevice() {
    final running = _detachTransport;
    if (running != null) {
      return running.timeout(_apiService.requestTimeout,
          onTimeout: () => throw const ApiFailure(ApiFailureKind.timeout));
    }
    final session = _deviceSession ??
        _logoutSession ??
        (_signedInUser() == null ? null : _DeviceSession(_signedInUser()!));
    _logoutSession = session;
    _logCleanup('cleanup_started', {
      'previously_registered_token_known': session?.tokens.isNotEmpty ?? false,
    });
    _detaching = true;
    _logCleanup('notification_session_detaching');
    bindUser(null);
    final operation = _enqueue(() async {
      // The queue waits for the REAL HTTP transport, even if its UI future
      // timed out. Owned DELETE therefore follows the last registration.
      // bindUser(null) retires the current session. Remove it from that queue
      // here so this logout owns exactly one cleanup attempt and does not
      // close/reopen the captured old-account bearer before the DELETE.
      if (session != null) _retired.remove(session);
      await _cleanRetired();
      _logCleanup('notification_session_cleanup_complete');
      if (session == null) {
        throw const ApiFailure(ApiFailureKind.authentication);
      }

      await _cleanSession(session);
      var fcmTokenRevoked = false;
      if (_signedInUser() == session.owner) {
        // Installation-scoped backend revocation cancels queued deliveries.
        // FCM token deletion is best-effort only after that is confirmed.
        try {
          // ignore: deprecated_member_use
          await _firebaseMessaging
              // ignore: deprecated_member_use
              .deleteToken()
              .timeout(_apiService.requestTimeout);
          fcmTokenRevoked = true;
          _logCleanup('firebase_token_delete_succeeded', {
            'backend_cleanup_confirmed': session.installationRevoked,
            'fcm_token_revoked': true,
          });
        } catch (error) {
          _logCleanupException('firebase_token_delete_failed', error);
        }
      }
      _logCleanup('cleanup_complete', {
        'backend_cleanup_confirmed': session.installationRevoked,
        'fcm_token_revoked': fcmTokenRevoked,
      });
      _logoutSession = null;
    });
    _detachTransport = operation;
    operation.then<void>((_) {
      _detachTransport = null;
      _detaching = false;
    }, onError: (Object _, StackTrace __) {
      _detachTransport = null;
      _detaching = false;
    });
    return operation.timeout(_apiService.requestTimeout,
        onTimeout: () => throw const ApiFailure(ApiFailureKind.timeout));
  }

  Future<bool> permissionGranted() async {
    final status = (await _firebaseMessaging.getNotificationSettings())
        .authorizationStatus;
    return status == AuthorizationStatus.authorized ||
        status == AuthorizationStatus.provisional;
  }

  FirebaseMessaging get _firebaseMessaging =>
      _messaging ?? FirebaseMessaging.instance;

  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    'safecircle_alerts',
    'SafeCircle Alerts',
    description: 'Notifications for SafeCircle safety updates.',
    importance: Importance.high,
  );

  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  StreamSubscription<RemoteMessage>? _foregroundSubscription;

  Future<void> initializeLocalNotifications() async {
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );

    const initializationSettings = InitializationSettings(
      android: androidSettings,
    );

    await _localNotifications.initialize(
      settings: initializationSettings,
      onDidReceiveNotificationResponse: (response) {
        final parts = response.payload?.split('|');
        if (parts == null ||
            parts.length != 2 ||
            parts[0] != _boundUser ||
            _currentUserId() != _boundUser) {
          return;
        }
        final id = int.tryParse(parts[1]);
        if (id != null && id > 0) onNotificationTap?.call(id);
      },
    );

    final androidPlugin =
        _localNotifications.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    await androidPlugin?.createNotificationChannel(_channel);
  }

  static ({String title, String body}) notificationCopy(
      AppNotification? inboxNotification) {
    if (inboxNotification?.category == NotificationCategory.emergency &&
        inboxNotification?.eventType == 'emergency.panic') {
      return (
        title: 'SafeCircle emergency alert',
        body: 'A SafeCircle connection has triggered a panic alert.',
      );
    }
    return (title: 'SafeCircle', body: 'You have a SafeCircle update.');
  }

  Future<void> showNotification(RemoteMessage message,
      {AppNotification? inboxNotification}) async {
    final id = validNotification(message);
    if (id == null) return;
    final copy = notificationCopy(inboxNotification);
    await _localNotifications.show(
      id: id,
      payload: '${message.data["recipient_uid"]}|$id',
      title: copy.title,
      body: copy.body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.id,
          _channel.name,
          channelDescription: _channel.description,
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
        ),
      ),
    );
  }

  Future<void> handleNotificationTaps() async {
    await _openedSubscription?.cancel();
    _openedSubscription =
        FirebaseMessaging.onMessageOpenedApp.listen((message) {
      receive(message, tap: true);
    });
    final initial = await _firebaseMessaging.getInitialMessage();
    if (initial != null) await receive(initial, tap: true);
  }

  Future<void> startForegroundListener() async {
    await initializeLocalNotifications();

    await _foregroundSubscription?.cancel();

    await _tokenSubscription?.cancel();
    // Token refreshes remain bound to this stable installation identifier.
    // ignore: deprecated_member_use
    _tokenSubscription = _firebaseMessaging.onTokenRefresh.listen((token) {
      if (_boundUser != null && _signedInUser() == _boundUser) {
        registerDevice(token: token).catchError((Object _) {});
      }
    });
    _foregroundSubscription = FirebaseMessaging.onMessage.listen(
      (RemoteMessage message) {
        receive(message).catchError((Object error) {
          debugPrint('FCM: Failed to display notification.');
        });
      },
      onError: (Object error) {
        debugPrint('FCM: Foreground listener failed.');
      },
    );
  }

  Future<void> dispose() async {
    _disposed = true;
    // Disposing the UI is not logout: preserve enrollment for background push.
    final sessions = <_DeviceSession>{
      if (_deviceSession != null) _deviceSession!,
      if (_logoutSession != null) _logoutSession!,
      ..._retired,
    };
    unawaited(_tail.then<void>((_) {
      for (final session in sessions) {
        session.auth?.close();
      }
    }));
    await _foregroundSubscription?.cancel();
    _foregroundSubscription = null;
    await _openedSubscription?.cancel();
    await _tokenSubscription?.cancel();
  }

  Future<NotificationSettings> requestPermission() async {
    return _firebaseMessaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
  }

  Future<void> registerDevice({String? token}) {
    final session = _deviceSession;
    if (session == null || !_currentDeviceSession(session)) {
      return Future.value();
    }
    if (token != null) session.pendingToken = token;
    final existing = session.visible;
    if (existing != null) return existing;
    final operation = _enqueue(() async {
      try {
        await _cleanRetired();
        do {
          final hint = session.pendingToken;
          session.pendingToken = null;
          await _register(session, hint);
        } while (
            _currentDeviceSession(session) && session.pendingToken != null);
      } finally {
        if (session.retired) {
          await _cleanSession(session);
          _retired.remove(session);
        }
      }
    });
    late final Future<void> transport;
    void clear() {
      if (identical(session.transport, transport)) {
        session.transport = null;
        session.visible = null;
      }
    }

    transport = operation.then<void>((_) {
      clear();
      // A refresh may arrive after the drain loop exits but before this future
      // completes. Do not lose that last event or cache a failed registration.
      final pending = session.pendingToken;
      if (_currentDeviceSession(session) &&
          pending != null &&
          pending != session.registeredToken) {
        unawaited(registerDevice(token: pending).catchError((Object _) {}));
      }
    }, onError: (Object error, StackTrace stack) {
      clear();
      Error.throwWithStackTrace(error, stack);
    });
    session.transport = transport;
    final visible = transport.timeout(_apiService.requestTimeout,
        onTimeout: () => throw const ApiFailure(ApiFailureKind.timeout));
    session.visible = visible;
    return visible;
  }

  Future<void> _register(_DeviceSession session, String? hint) async {
    if (!_currentDeviceSession(session)) return;
    if (kIsWeb) throw const ApiFailure(ApiFailureKind.requestRejected);
    final platformName = switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      _ => throw const ApiFailure(ApiFailureKind.requestRejected),
    };
    final settings = await _firebaseMessaging
        .getNotificationSettings()
        .timeout(_apiService.requestTimeout);
    if (!_currentDeviceSession(session)) return;
    if (settings.authorizationStatus != AuthorizationStatus.authorized &&
        settings.authorizationStatus != AuthorizationStatus.provisional) {
      throw const ApiFailure(ApiFailureKind.forbidden);
    }
    try {
      session.installationId ??= await _installationIdentity.id;
    } catch (error) {
      _logCleanupException('installation_id_unavailable', error);
      throw const DeviceCleanupUnverified(
          'SafeCircle could not access this phone\'s secure installation record. Restart the app and retry.');
    }
    // The FCM token can be unavailable during logout; cleanup uses the
    // independently persisted installation ID instead.
    String? token;
    try {
      token = hint ??
          // ignore: deprecated_member_use
          await _firebaseMessaging
              // ignore: deprecated_member_use
              .getToken()
              .timeout(_apiService.requestTimeout);
    } catch (error) {
      _logCleanupException('registration_current_token_lookup_failed', error);
      rethrow;
    }
    if (!_currentDeviceSession(session)) return;
    if (token == null || token.trim().isEmpty) {
      throw const ApiFailure(ApiFailureKind.requestRejected);
    }
    if (session.registeredToken == token) return;
    final fresh = await _apiService.openDeviceRegistrationSession(
        isCurrent: () => _currentDeviceSession(session));
    session.auth?.close();
    session.auth = fresh;
    if (!_currentDeviceSession(session)) return;
    session.tokens.add(token);
    try {
      await session.auth!.register(
          fcmToken: token,
          platform: platformName,
          installationId: session.installationId,
          canStart: () => _currentDeviceSession(session));
      if (_currentDeviceSession(session)) session.registeredToken = token;
      _logCleanup('backend_registration_succeeded');
    } on ApiFailure catch (error) {
      _logCleanup('backend_registration_failed', {
        'api_http_status': error.statusCode,
        'failure_kind': error.kind.name
      });
      if ({401, 403, 409, 422}.contains(error.statusCode)) {
        session.tokens.remove(token); // A definite rejection did not enroll it.
      }
      rethrow;
    }
  }
}

class _DeviceSession {
  _DeviceSession(this.owner);
  final String owner;
  bool retired = false;
  bool installationRevoked = false;
  String? installationId;
  String? registeredToken, pendingToken;
  final Set<String> tokens = {}, cleaned = {};
  DeviceRegistrationSession? auth;
  Future<void>? transport, visible;
}
