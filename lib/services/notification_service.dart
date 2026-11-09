import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'api_service.dart';
import 'api_failure.dart';

class NotificationService {
  NotificationService({
    FirebaseMessaging? messaging,
    ApiService? apiService,
    String? Function()? currentUserId,
  })  : _currentUserId =
            currentUserId ?? (() => FirebaseAuth.instance.currentUser?.uid),
        _messaging = messaging,
        _apiService = apiService ?? ApiService();

  final FirebaseMessaging? _messaging;
  final ApiService _apiService;
  final String? Function() _currentUserId;
  String? _boundUser;
  bool _disposed = false;
  bool _detaching = false;
  _DeviceSession? _deviceSession, _logoutSession;
  final List<_DeviceSession> _retired = [];
  Future<void> _tail = Future<void>.value();
  Future<void>? _detachTransport;

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
    if (session.tokens.isNotEmpty) {
      if (_signedInUser() == session.owner) {
        // Normal logout refreshes the old owner's bearer before sign-out.
        try {
          final fresh = await _apiService.openDeviceRegistrationSession(
              isCurrent: () => _signedInUser() == session.owner);
          session.auth?.close();
          session.auth = fresh;
        } on ApiFailure {
          // An account may change while the refresh is pending. Only the
          // already captured old-owner bearer is a permissible fallback.
          if (session.auth == null) rethrow;
        }
      }
      final auth = session.auth;
      if (auth == null) throw const ApiFailure(ApiFailureKind.authentication);
      for (final token in session.tokens.toList()) {
        await auth.unregister(token);
        session.tokens.remove(token);
        session.cleaned.add(token);
      }
    }
    session.auth?.close();
    session.auth = null;
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
      await _apiService.fetchNotification(
          id); // Suppress deleted or inaccessible inbox entries.
      if (owner != _boundUser || validNotification(message) != id) return;
      onInboxChanged?.call();
      if (_shown.length > 512) _shown.clear();
      if (!_shown.add('$owner:$id')) return;
      await showNotification(message);
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
    final session = _deviceSession ?? _logoutSession;
    _logoutSession = session;
    _detaching = true;
    bindUser(null);
    final operation = _enqueue(() async {
      // The queue waits for the REAL HTTP transport, even if its UI future
      // timed out. Owned DELETE therefore follows the last registration.
      await _cleanRetired();
      if (session != null && _signedInUser() == session.owner) {
        // Also cover an existing installation restored before registration.
        // ignore: deprecated_member_use
        final token = await _firebaseMessaging
            // ignore: deprecated_member_use
            .getToken()
            .timeout(_apiService.requestTimeout);
        if (token != null &&
            token.trim().isNotEmpty &&
            !session.cleaned.contains(token)) {
          final auth = await _apiService.openDeviceRegistrationSession(
              isCurrent: () => _signedInUser() == session.owner);
          try {
            await auth.unregister(token);
          } on ApiFailure catch (error) {
            // A Firebase-only account cannot own an FK-enforced device row.
            if (error.statusCode != 403 ||
                session.registeredToken != null ||
                session.tokens.isNotEmpty) {
              rethrow;
            }
          } finally {
            auth.close();
          }
          session.cleaned.add(token);
        }
        if (_signedInUser() == session.owner) {
          // Keep FCM registration tokens, not installation IDs.
          // ignore: deprecated_member_use
          await _firebaseMessaging
              // ignore: deprecated_member_use
              .deleteToken()
              .timeout(_apiService.requestTimeout);
        }
      }
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

  Future<void> showNotification(RemoteMessage message) async {
    final id = validNotification(message);
    if (id == null) return;
    const title = 'SafeCircle';
    const body = 'You have a SafeCircle update.';
    await _localNotifications.show(
      id: id,
      payload: '${message.data["recipient_uid"]}|$id',
      title: title,
      body: body,
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
    // Existing backend accepts registration tokens, not installation IDs.
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
        if (session.retired) await _cleanSession(session);
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
    // The backend accepts FCM registration tokens, not installation IDs.
    // ignore: deprecated_member_use
    final token = hint ??
        // ignore: deprecated_member_use
        await _firebaseMessaging.getToken().timeout(_apiService.requestTimeout);
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
          canStart: () => _currentDeviceSession(session));
      if (_currentDeviceSession(session)) session.registeredToken = token;
    } on ApiFailure catch (error) {
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
  String? registeredToken, pendingToken;
  final Set<String> tokens = {}, cleaned = {};
  DeviceRegistrationSession? auth;
  Future<void>? transport, visible;
}
