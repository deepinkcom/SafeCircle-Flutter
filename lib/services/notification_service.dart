import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'api_service.dart';

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
  final Set<String> _shown = {};
  final Map<String, DateTime> _tapped = {};
  StreamSubscription<RemoteMessage>? _openedSubscription;
  StreamSubscription<String>? _tokenSubscription;
  void Function()? onInboxChanged;
  void Function(int notificationId)? onNotificationTap;
  void bindUser(String? uid) {
    if (_boundUser != uid) {
      _boundUser = uid;
      _shown.clear();
      _tapped.clear();
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

  Future<void> detachDevice() async {
    bindUser(null);
    try {
      // Keep the existing FCM registration-token contract (not installation IDs).
      // ignore: deprecated_member_use
      final token = await _firebaseMessaging.getToken();
      if (token != null) {
        await _apiService
            .unregisterDevice(fcmToken: token)
            .timeout(const Duration(seconds: 5));
      }
    } catch (_) {}
    try {
      // ignore: deprecated_member_use
      await _firebaseMessaging
          // ignore: deprecated_member_use
          .deleteToken()
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
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
    _tokenSubscription = _firebaseMessaging.onTokenRefresh.listen((_) {
      if (_boundUser != null && _currentUserId() == _boundUser) {
        registerDevice().catchError((Object _) {});
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

  Future<void> registerDevice() async {
    final owner = _boundUser;
    if (owner == null || _currentUserId() != owner) return;
    if (kIsWeb) {
      throw UnsupportedError(
        'Device registration is currently supported on Android and iOS only.',
      );
    }

    final platform = defaultTargetPlatform;

    final platformName = switch (platform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      _ => throw UnsupportedError(
          'Device registration is currently supported on Android and iOS only.',
        ),
    };

    final settings = await _firebaseMessaging.getNotificationSettings();
    final permission = settings.authorizationStatus;

    if (permission != AuthorizationStatus.authorized &&
        permission != AuthorizationStatus.provisional) {
      throw Exception(
        'Notification permission has not been granted. '
        'Request permission before registering the device.',
      );
    }

    // The backend expects an FCM registration token.
    // ignore: deprecated_member_use
    final token = await _firebaseMessaging.getToken();

    if (token == null || token.trim().isEmpty) {
      throw Exception('Firebase did not provide a device token.');
    }

    if (owner != _boundUser || _currentUserId() != owner) return;
    await _apiService.registerDevice(
      fcmToken: token,
      platform: platformName,
    );
  }
}
