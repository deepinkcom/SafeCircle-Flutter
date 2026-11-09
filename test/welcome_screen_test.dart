import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safecircle/screens/welcome_screen.dart';
import 'package:safecircle/services/location_service.dart';
import 'package:safecircle/services/notification_service.dart';
import 'package:safecircle/theme/app_theme.dart';

import 'welcome_navigation_test.dart' show tapWelcomeText;

class WelcomeLocation extends LocationService {
  LocationAccess result = LocationAccess.granted;
  Future<LocationAccess> Function()? onRequest;
  int requests = 0;
  int appSettings = 0;
  int locationSettings = 0;
  bool settingsResult = true;
  bool settingsThrow = false;
  @override
  Future<LocationAccess> requestPermission() async {
    requests++;
    return onRequest != null ? onRequest!() : result;
  }

  @override
  Future<bool> openLocationSettings() async {
    locationSettings++;
    if (settingsThrow) throw StateError('synthetic internal detail');
    return settingsResult;
  }

  @override
  Future<bool> openAppSettings() async {
    appSettings++;
    return settingsResult;
  }
}

NotificationSettings notificationSettings(AuthorizationStatus status) =>
    NotificationSettings(
      authorizationStatus: status,
      alert: AppleNotificationSetting.notSupported,
      announcement: AppleNotificationSetting.notSupported,
      badge: AppleNotificationSetting.notSupported,
      carPlay: AppleNotificationSetting.notSupported,
      lockScreen: AppleNotificationSetting.notSupported,
      notificationCenter: AppleNotificationSetting.notSupported,
      showPreviews: AppleShowPreviewSetting.notSupported,
      sound: AppleNotificationSetting.notSupported,
      timeSensitive: AppleNotificationSetting.notSupported,
      criticalAlert: AppleNotificationSetting.notSupported,
      providesAppNotificationSettings: AppleNotificationSetting.notSupported,
    );

// Keep the real NotificationService permission method; fake only the SDK boundary.
class WelcomeMessaging extends Fake implements FirebaseMessaging {
  AuthorizationStatus status = AuthorizationStatus.authorized;
  int requests = 0;
  Future<NotificationSettings> Function()? onRequest;
  @override
  Future<NotificationSettings> requestPermission({
    bool alert = true,
    bool announcement = false,
    bool badge = true,
    bool carPlay = false,
    bool criticalAlert = false,
    bool provisional = false,
    bool sound = true,
    bool providesAppNotificationSettings = false,
  }) async {
    requests++;
    expect((alert, badge, sound), (true, true, true));
    return onRequest != null ? onRequest!() : notificationSettings(status);
  }
}

Future<void> pumpWelcome(
    WidgetTester tester, WelcomeLocation location, WelcomeMessaging messaging,
    {VoidCallback? signup, VoidCallback? login, double textScale = 1}) async {
  await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!),
      home: WelcomeScreen(
          onGetStarted: signup ?? () {},
          onLogIn: login ?? () {},
          locationService: location,
          notificationService: NotificationService(messaging: messaging))));
  await tester.pumpAndSettle();
}

void main() {
  late WelcomeLocation location;
  late WelcomeMessaging messaging;
  setUp(() {
    location = WelcomeLocation();
    messaging = WelcomeMessaging();
  });

  testWidgets('does not request permissions automatically', (tester) async {
    await pumpWelcome(tester, location, messaging);
    expect((location.requests, messaging.requests), (0, 0));
    expect(
        find.textContaining(
            'does not automatically activate nearby emergency push delivery'),
        findsOneWidget);
  });

  for (final (result, text, settings) in [
    (LocationAccess.granted, 'Location permission is enabled.', null),
    (LocationAccess.denied, 'Location permission was denied.', null),
    (
      LocationAccess.deniedForever,
      'Location permission is blocked.',
      'Open app settings'
    ),
    (
      LocationAccess.servicesDisabled,
      'Location services are off.',
      'Open location settings'
    ),
  ]) {
    testWidgets('location $result reports its outcome and settings recovery',
        (tester) async {
      location.result = result;
      await pumpWelcome(tester, location, messaging);
      await tapWelcomeText(tester, 'Enable location');
      expect(find.textContaining(text), findsOneWidget);
      expect(location.requests, 1);
      expect(messaging.requests, 0);
      if (settings != null) {
        await tapWelcomeText(tester, settings);
        expect(
            result == LocationAccess.servicesDisabled
                ? location.locationSettings
                : location.appSettings,
            1);
        // Opening settings is not proof of permission being granted.
        expect(find.text('Location permission is enabled.'), findsNothing);
      }
    });
  }

  testWidgets('temporary location denial can be retried successfully',
      (tester) async {
    location.result = LocationAccess.denied;
    await pumpWelcome(tester, location, messaging);
    await tapWelcomeText(tester, 'Enable location');
    location.result = LocationAccess.granted;
    await tapWelcomeText(tester, 'Enable location');
    expect(find.text('Location permission is enabled.'), findsOneWidget);
    expect(location.requests, 2);
  });

  for (final (status, text) in [
    (AuthorizationStatus.authorized, 'Notification permission is enabled.'),
    (
      AuthorizationStatus.provisional,
      'Quiet notification permission is enabled.'
    ),
    (AuthorizationStatus.denied, 'Notification permission was denied.'),
    (
      AuthorizationStatus.deniedPermanently,
      'Notification permission was denied.'
    ),
    (
      AuthorizationStatus.notDetermined,
      'Notification permission has not been granted.'
    ),
  ]) {
    testWidgets(
        'notification $status uses existing service and keeps delivery disclaimer',
        (tester) async {
      messaging.status = status;
      await pumpWelcome(tester, location, messaging);
      await tapWelcomeText(tester, 'Get nearby emergency alerts');
      expect(find.textContaining(text), findsOneWidget);
      expect(
          find.textContaining(
              'does not automatically activate nearby emergency push delivery'),
          findsOneWidget);
      expect((messaging.requests, location.requests), (1, 0));
      // Unstubbed messaging operations (token lookup/registration/listeners) throw.
      expect(tester.takeException(), isNull);
      if (status == AuthorizationStatus.denied ||
          status == AuthorizationStatus.deniedPermanently) {
        await tapWelcomeText(tester, 'Open app settings');
        expect(location.appSettings, 1);
      }
    });
  }

  for (final notifications in [false, true]) {
    testWidgets(
        '${notifications ? 'notification' : 'location'} permission failure is safe and retryable',
        (tester) async {
      if (notifications) {
        messaging.onRequest =
            () async => throw StateError('synthetic internal detail');
      } else {
        location.onRequest =
            () async => throw StateError('synthetic internal detail');
      }
      await pumpWelcome(tester, location, messaging);
      await tapWelcomeText(tester,
          notifications ? 'Get nearby emergency alerts' : 'Enable location');
      expect(find.textContaining('Could not request'), findsOneWidget);
      expect(find.textContaining('synthetic internal detail'), findsNothing);
      messaging.onRequest = null;
      location.onRequest = null;
      await tapWelcomeText(tester,
          notifications ? 'Get nearby emergency alerts' : 'Enable location');
      expect(find.textContaining('Could not request'), findsNothing);
    });
  }

  testWidgets(
      'pending permission prevents duplicate and concurrent native prompts',
      (tester) async {
    final pending = Completer<LocationAccess>();
    location.onRequest = () => pending.future;
    await pumpWelcome(tester, location, messaging);
    await Scrollable.ensureVisible(tester.element(find.text('Enable location')),
        alignment: 0.5);
    await tester.tap(find.text('Enable location'));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.tap(find.text('Enable location'));
    await tester.tap(find.text('Get nearby emergency alerts'));
    expect((location.requests, messaging.requests), (1, 0));
    pending.complete(LocationAccess.granted);
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  for (final notifications in [false, true]) {
    testWidgets(
        'leaving during ${notifications ? 'notification' : 'location'} request ignores late result',
        (tester) async {
      final gps = Completer<LocationAccess>();
      final fcm = Completer<NotificationSettings>();
      location.onRequest = () => gps.future;
      messaging.onRequest = () => fcm.future;
      var signup = 0;
      await pumpWelcome(tester, location, messaging, signup: () => signup++);
      final label =
          notifications ? 'Get nearby emergency alerts' : 'Enable location';
      await Scrollable.ensureVisible(tester.element(find.text(label)),
          alignment: 0.5);
      await tester.tap(find.text(label));
      await tester.pump();
      await tester.ensureVisible(find.text('Create an account'));
      await tester.pump();
      await tester.tap(find.text('Create an account'));
      expect(signup, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      if (notifications) {
        fcm.complete(notificationSettings(AuthorizationStatus.authorized));
      } else {
        gps.complete(LocationAccess.granted);
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  for (final throws in [false, true]) {
    testWidgets(
        'settings ${throws ? 'exception' : 'unavailable'} has safe manual recovery',
        (tester) async {
      location.result = LocationAccess.servicesDisabled;
      location.settingsResult = false;
      location.settingsThrow = throws;
      await pumpWelcome(tester, location, messaging);
      await tapWelcomeText(tester, 'Enable location');
      await tapWelcomeText(tester, 'Open location settings');
      expect(find.textContaining('Open your device settings manually'),
          findsOneWidget);
      expect(find.textContaining('synthetic internal detail'), findsNothing);
    });
  }

  testWidgets('narrow welcome with large text stays usable and logo loads',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpWelcome(tester, location, messaging, textScale: 1.8);
    expect(tester.takeException(), isNull);
    await tapWelcomeText(tester, 'Get nearby emergency alerts');
    await tapWelcomeText(tester, 'Get Started');
    await tapWelcomeText(tester, 'Log In');
    expect(tester.takeException(), isNull);
  });
}
