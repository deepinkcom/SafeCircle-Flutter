
import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'api_service.dart';

class NotificationService {
  NotificationService({
    FirebaseMessaging? messaging,
    ApiService? apiService,
  })  : _messaging = messaging,
        _apiService = apiService ?? ApiService();

  final FirebaseMessaging? _messaging;
  final ApiService _apiService;

  FirebaseMessaging get _firebaseMessaging =>
      _messaging ?? FirebaseMessaging.instance;

  static const AndroidNotificationChannel _channel =
      AndroidNotificationChannel(
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
    );

    final androidPlugin = _localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    await androidPlugin?.createNotificationChannel(_channel);
  }

  Future<void> showNotification(RemoteMessage message) async {
    final notification = message.notification;

    final title = notification?.title ??
        message.data['title']?.toString() ??
        'SafeCircle Alert';

    final body = notification?.body ??
        message.data['body']?.toString() ??
        'You have a new safety update.';

    await _localNotifications.show(
      id: message.hashCode,
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
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      debugPrint(
        'FCM: Notification tapped from background: ${message.messageId}',
      );
    });

    final initialMessage = await _firebaseMessaging.getInitialMessage();

    if (initialMessage != null) {
      debugPrint(
        'FCM: App opened from notification: ${initialMessage.messageId}',
      );
    }
  }

  Future<void> startForegroundListener() async {
    await initializeLocalNotifications();

    await _foregroundSubscription?.cancel();

    _foregroundSubscription = FirebaseMessaging.onMessage.listen(
      (RemoteMessage message) {
        debugPrint(
          'FCM: Foreground message received: ${message.messageId}',
        );

        showNotification(message).catchError((Object error) {
          debugPrint('FCM: Failed to display notification: $error');
        });
      },
      onError: (Object error) {
        debugPrint('FCM: Foreground listener error: $error');
      },
    );
  }

  Future<void> dispose() async {
    await _foregroundSubscription?.cancel();
    _foregroundSubscription = null;
  }

  Future<NotificationSettings> requestPermission() async {
    return _firebaseMessaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
  }

  Future<void> registerDevice() async {
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

    await _apiService.registerDevice(
      fcmToken: token,
      platform: platformName,
    );
  }
}
