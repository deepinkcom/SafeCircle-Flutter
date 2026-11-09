import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:safecircle/models/app_notification.dart';
import 'package:safecircle/models/contact_link.dart';
import 'package:safecircle/navigation/app_router.dart';
import 'package:safecircle/screens/alert_history_screen.dart';
import 'package:safecircle/screens/contact_links_screen.dart';
import 'package:safecircle/screens/emergency_nearby_screen.dart';
import 'package:safecircle/screens/login_screen.dart';
import 'package:safecircle/screens/notifications_screen.dart';
import 'package:safecircle/services/api_failure.dart';
import 'package:safecircle/services/location_service.dart';
import 'package:safecircle/state/app_state.dart';
import 'package:safecircle/state/notifications_state.dart';
import 'package:safecircle/theme/app_theme.dart';
import 'package:safecircle/widgets/notification_bell.dart';

import 'support/contact_links_fakes.dart';
import 'support/contact_links_widget_harness.dart' show tapText;
import 'support/notifications_fakes.dart';

Future<NotificationsState> pumpInbox(
    WidgetTester tester, NotificationsFakeApi api,
    {Future<String?> Function(AppNotification)? open,
    Future<void> Function()? signIn,
    Future<void> Function()? profile,
    double scale = 1}) async {
  final state = NotificationsState(apiService: api)..setSession('alice');
  addTearDown(state.dispose);
  await tester.pumpWidget(ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(
          theme: AppTheme.light,
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!),
          home: NotificationsScreen(
              onOpen: open ?? (_) async => null,
              onSignIn: signIn ?? () async {},
              onCompleteProfile: profile ?? () async {}))));
  await tester.pump();
  return state;
}

class NoDeviceLocation extends GeolocatorPlatform {
  @override
  Future<bool> isLocationServiceEnabled() async => false;
}

class TestLocation extends LocationService {
  int reads = 0;
  @override
  Future<({double lat, double lng})> getCurrentLocation() async {
    reads++;
    return (lat: 0.0, lng: 0.0);
  }
}

class NotificationsApp extends AppState {
  NotificationsApp(NotificationsFakeApi api)
      : super(
            apiService: api,
            authService: ContactLinksFakeAuth(),
            locationService: TestLocation());
  @override
  Future<void> loadAlertHistory() async {}
  @override
  Future<void> loadCurrentLocation() async {}
  @override
  Future<void> loadNearbyAlert() async {}
}

Future<NotificationsApp> boot(
    WidgetTester tester, NotificationsFakeApi api) async {
  final previous = GeolocatorPlatform.instance;
  GeolocatorPlatform.instance = NoDeviceLocation();
  addTearDown(() => GeolocatorPlatform.instance = previous);
  tester.view.physicalSize = const Size(800, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final app = NotificationsApp(api);
  addTearDown(app.dispose);
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: app, child: const SafeCircleApp()));
  await tester.pumpAndSettle();
  return app;
}

void main() {
  testWidgets('Back during source lookup cancels late navigation',
      (tester) async {
    final api = NotificationsFakeApi()
      ..notifications = [testNotification(1, read: true)];
    final pending = Completer<List<ContactLink>>();
    await boot(tester, api);
    await tester.tap(find.byTooltip('Notifications, 0 unread'));
    await tester.pumpAndSettle();
    api.onIncoming = () => pending.future;
    await tester.tap(find.text('Test notification 1'));
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();
    pending.complete([testLink(7, 'pending')]);
    await tester.pumpAndSettle();
    expect(find.byType(ContactLinksScreen), findsNothing);
    expect(find.byType(NotificationsScreen), findsNothing);
  });
  testWidgets(
      'notification-opened history hides previous-session records on account switch',
      (tester) async {
    final api = NotificationsFakeApi()
      ..notifications = [testNotification(1, category: 'emergency', read: true)]
      ..history = [
        {
          'id': 7,
          'kind': 'panic',
          'status': 'resolved',
          'created_at': '2026-11-08T10:00:00Z',
          'location_label': 'Private previous-session area'
        }
      ];
    final app = await boot(tester, api);
    await tester.tap(find.byTooltip('Notifications, 0 unread'));
    await tester.pumpAndSettle();
    await tapText(tester, 'Test notification 1');
    expect(find.byType(AlertHistoryScreen), findsOneWidget);
    app.userProfile = testProfile('bob');
    await tester.pumpAndSettle();
    expect(
        find.text('This notification is unavailable in the current session.'),
        findsOneWidget);
    expect(find.text('Private previous-session area'), findsNothing);
  });
  testWidgets(
      'history acknowledgement IDs are not confused with source alert IDs',
      (tester) async {
    final api = NotificationsFakeApi()
      ..notifications = [testNotification(1, category: 'emergency', read: true)]
      ..history = [
        {
          'id': 7,
          'alert_id': 99,
          'kind': 'nearby_received',
          'status': 'on_my_way',
          'created_at': '2026-11-08T10:00:00Z'
        }
      ];
    await boot(tester, api);
    await tester.tap(find.byTooltip('Notifications, 0 unread'));
    await tester.pumpAndSettle();
    await tapText(tester, 'Test notification 1');
    expect(find.byType(NotificationsScreen), findsOneWidget);
    expect(find.byType(AlertHistoryScreen), findsNothing);
    expect(find.textContaining('outside your accessible nearby alerts'),
        findsOneWidget);
  });
  testWidgets(
      'unknown category remains visible but never opens a guessed source',
      (tester) async {
    final api = NotificationsFakeApi()
      ..notifications = [testNotification(1, category: 'future', read: true)];
    await boot(tester, api);
    await tester.tap(find.byTooltip('Notifications, 0 unread'));
    await tester.pumpAndSettle();
    await tapText(tester, 'Test notification 1');
    expect(find.text('This notification type is not supported yet.'),
        findsOneWidget);
    expect(api.historyCalls, 0);
    expect(api.nearbyCalls, 0);
    expect(api.incomingCalls, 0);
  });
  testWidgets(
      'filters server data, displays timestamps/status and read controls do not open source',
      (tester) async {
    final api = NotificationsFakeApi()
      ..notifications = [
        testNotification(1),
        testNotification(2, category: 'emergency')
      ];
    var opened = 0;
    final state = await pumpInbox(tester, api, open: (_) async {
      opened++;
      return null;
    });
    await tester.pumpAndSettle();
    expect(find.text('Test notification 2'), findsOneWidget);
    expect(find.textContaining('8 Nov 2026'), findsWidgets);
    await tapText(tester, 'Connections');
    expect(find.text('Test notification 2'), findsNothing);
    await tapText(tester, 'Mark read');
    expect(opened, 0);
    expect(api.updates, [(1, true)]);
    expect(find.text('Read'), findsOneWidget);
    expect(state.unreadCount, 1);
    await tapText(tester, 'Mark unread');
    expect(api.updates.last, (1, false));
    expect(state.unreadCount, 2);
    await tapText(tester, 'Emergency Alerts');
    expect(find.text('Test notification 1'), findsNothing);
    await tapText(tester, 'All');
    expect(state.items, hasLength(2));
  });
  testWidgets(
      'loading, true empty data and count failures have distinct states',
      (tester) async {
    final api = NotificationsFakeApi();
    final pending = Completer<NotificationPage>();
    api.onPage = (_, __, ___) => pending.future;
    await pumpInbox(tester, api);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    pending.complete(NotificationPage(
        items: [], total: 0, limit: 20, offset: 0, hasMore: false));
    await tester.pumpAndSettle();
    expect(find.text('No notifications in this view.'), findsOneWidget);
    api.onPage = null;
    api.onCount = () async => throw const ApiFailure(ApiFailureKind.network);
    await tester.tap(find.byTooltip('Refresh notifications'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Unread count could not be refreshed.'),
        findsOneWidget);
  });
  testWidgets('failed refresh retains loaded data and offers safe retry',
      (tester) async {
    final api = NotificationsFakeApi()..notifications = [testNotification(1)];
    await pumpInbox(tester, api);
    await tester.pumpAndSettle();
    api.onPage =
        (_, __, ___) async => throw const ApiFailure(ApiFailureKind.network);
    await tester.tap(find.byTooltip('Refresh notifications'));
    await tester.pumpAndSettle();
    expect(find.text('Test notification 1'), findsOneWidget);
    expect(find.textContaining('Previously loaded notifications are retained.'),
        findsOneWidget);
    api.onPage = null;
    await tapText(tester, 'Refresh notifications');
    expect(
        find.textContaining('Previously loaded notifications'), findsNothing);
  });
  testWidgets('Load more fetches the next backend page', (tester) async {
    final api = NotificationsFakeApi()
      ..notifications = [for (var id = 1; id <= 25; id++) testNotification(id)];
    final state = await pumpInbox(tester, api);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Load more'), 400,
        scrollable: find.byType(Scrollable).first);
    await tapText(tester, 'Load more');
    expect(state.items, hasLength(25));
    expect(api.requests.last, (null, 20));
  });
  testWidgets('opening marks read but only delegates source viewing',
      (tester) async {
    final api = NotificationsFakeApi()..notifications = [testNotification(1)];
    var opened = 0;
    await pumpInbox(tester, api, open: (item) async {
      opened = item.sourceId;
      return 'Source unavailable.';
    });
    await tester.pumpAndSettle();
    await tapText(tester, 'Test notification 1');
    expect(api.updates, [(1, true)]);
    expect(opened, 7);
    expect(find.text('Source unavailable.'), findsOneWidget);
    expect(api.responses, isEmpty);
    expect(api.revocations, isEmpty);
  });
  for (final kind in [
    ApiFailureKind.authentication,
    ApiFailureKind.forbidden
  ]) {
    testWidgets('$kind has explicit account recovery', (tester) async {
      final api = NotificationsFakeApi()
        ..onPage = (_, __, ___) async => throw ApiFailure(kind);
      var recoveries = 0;
      final state = await pumpInbox(tester, api, signIn: () async {
        recoveries++;
      }, profile: () async {
        recoveries++;
        api.onPage = null;
      });
      await tester.pumpAndSettle();
      await tapText(
          tester,
          kind == ApiFailureKind.authentication
              ? 'Sign in again'
              : 'Complete or sync profile');
      expect(recoveries, 1);
      if (kind == ApiFailureKind.forbidden) {
        expect(state.isAccessBlocked, isFalse);
      }
    });
  }
  testWidgets(
      'uncertain read update blocks repeats and offers authoritative refresh',
      (tester) async {
    final api = NotificationsFakeApi()..notifications = [testNotification(1)];
    final state = await pumpInbox(tester, api);
    await tester.pumpAndSettle();
    api.onUpdate = (_, __) async {
      api.onPage =
          (_, __, ___) async => throw const ApiFailure(ApiFailureKind.network);
      throw const ApiFailure(ApiFailureKind.timeout);
    };
    await tapText(tester, 'Mark read');
    expect(state.requiresRefresh(1), isTrue);
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Mark read'))
            .onPressed,
        isNull);
    api.onPage = null;
    api.notifications = [testNotification(1, read: true)];
    await tester.tap(find.byTooltip('Refresh notifications'));
    await tester.pumpAndSettle();
    expect(state.requiresRefresh(1), isFalse);
    expect(find.text('Read'), findsOneWidget);
    expect(api.updates, hasLength(1));
  });
  testWidgets('narrow layout supports large text and readable actions',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = NotificationsFakeApi()..notifications = [testNotification(1)];
    await pumpInbox(tester, api, scale: 1.8);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Mark read'));
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.widgetWithText(TextButton, 'Mark read')).height,
        greaterThanOrEqualTo(48));
  });
  testWidgets('bell indicators are based on known backend count only',
      (tester) async {
    for (final count in [null, 0, 7]) {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: NotificationBell(unreadCount: count, onTap: () {}))));
      expect(tester.widget<Badge>(find.byType(Badge)).isLabelVisible,
          count != null && count > 0);
    }
  });
  testWidgets(
      'both Home and Contacts bells open the same shared notification state',
      (tester) async {
    final api = NotificationsFakeApi()..notifications = [testNotification(1)];
    final app = await boot(tester, api);
    await tester.tap(find.byTooltip('Notifications, 1 unread'));
    await tester.pumpAndSettle();
    expect(
        identical(
            tester
                .element(find.byType(NotificationsScreen))
                .read<NotificationsState>(),
            app.notifications),
        isTrue);
    await tapText(tester, 'Mark read');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byTooltip('Notifications, 0 unread'), findsOneWidget);
    await tapText(tester, 'Emergency\nContacts');
    await tester.tap(find.byTooltip('Notifications, 0 unread'));
    await tester.pumpAndSettle();
    expect(find.byType(NotificationsScreen), findsOneWidget);
    expect(api.phoneWrites, 0);
  });
  for (final status in [
    'pending',
    'accepted',
    'rejected',
    'revoked',
    'missing'
  ]) {
    testWidgets(
        'connection notification resolves current $status state without accepting',
        (tester) async {
      final api = NotificationsFakeApi()
        ..notifications = [testNotification(1, read: true)];
      if (status == 'pending') {
        api.incomingData = [testLink(7, 'pending')];
      } else if (status == 'accepted') {
        api.acceptedData = [testLink(7, 'accepted')];
      } else if (status != 'missing') {
        api.outgoingData = [testLink(7, status, incoming: false)];
      }
      await boot(tester, api);
      await tester.tap(find.byTooltip('Notifications, 0 unread'));
      await tester.pumpAndSettle();
      await tapText(tester, 'Test notification 1');
      expect(find.byType(ContactLinksScreen), findsOneWidget);
      if (status == 'missing') {
        expect(find.textContaining('no longer available'), findsOneWidget);
      } else {
        expect(find.text(status[0].toUpperCase() + status.substring(1)),
            findsOneWidget);
      }
      expect(api.responses, isEmpty);
      expect(api.revocations, isEmpty);
    });
  }
  testWidgets('expired inbox session routes through existing logout/login',
      (tester) async {
    final api = NotificationsFakeApi()
      ..onPage = (_, __, ___) async =>
          throw const ApiFailure(ApiFailureKind.authentication);
    final app = await boot(tester, api);
    await tester.tap(find.byTooltip('Notifications, 0 unread'));
    await tester.pumpAndSettle();
    await tapText(tester, 'Sign in again');
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(app.notifications.userId, isNull);
  });
  testWidgets(
      'emergency accessible in real history opens existing history screen',
      (tester) async {
    final api = NotificationsFakeApi()
      ..notifications = [testNotification(1, category: 'emergency', read: true)]
      ..history = [
        {
          'id': 7,
          'kind': 'panic',
          'status': 'resolved',
          'created_at': '2026-11-08T10:00:00Z',
          'location_label': 'Synthetic area'
        }
      ];
    await boot(tester, api);
    await tester.tap(find.byTooltip('Notifications, 0 unread'));
    await tester.pumpAndSettle();
    await tapText(tester, 'Test notification 1');
    expect(find.byType(AlertHistoryScreen), findsOneWidget);
    expect(api.nearbyCalls, 0);
  });
  testWidgets(
      'emergency matches exact accessible nearby ID, never the first result',
      (tester) async {
    final api = NotificationsFakeApi()
      ..notifications = [testNotification(1, category: 'emergency', read: true)]
      ..nearby = [
        for (final id in [6, 7])
          {
            'id': id,
            'status': 'active',
            'distance_km': 1,
            'latitude': 0,
            'longitude': 0,
            'created_at': '2026-11-08T10:00:00Z',
            'location_label': 'Area $id'
          }
      ];
    final app = await boot(tester, api);
    await tester.tap(find.byTooltip('Notifications, 0 unread'));
    await tester.pumpAndSettle();
    await tapText(tester, 'Test notification 1');
    final screen = tester
        .widget<EmergencyNearbyScreen>(find.byType(EmergencyNearbyScreen));
    expect(screen.notificationAlert!.id, 7);
    expect(app.nearbyPerson, isNull);
    expect(screen.notificationAlert!.locationLabel, 'Area 7');
    expect(find.text('Area 6'), findsNothing);
  });
  testWidgets('inaccessible emergency does not invent or substitute an alert',
      (tester) async {
    final api = NotificationsFakeApi()
      ..notifications = [testNotification(1, category: 'emergency', read: true)]
      ..nearby = [
        {
          'id': 6,
          'status': 'active',
          'distance_km': 1,
          'latitude': 0,
          'longitude': 0,
          'created_at': '2026-11-08T10:00:00Z'
        }
      ];
    final app = await boot(tester, api);
    await tester.tap(find.byTooltip('Notifications, 0 unread'));
    await tester.pumpAndSettle();
    await tapText(tester, 'Test notification 1');
    expect(find.byType(NotificationsScreen), findsOneWidget);
    expect(find.textContaining('outside your accessible nearby alerts'),
        findsOneWidget);
    expect(app.nearbyPerson, isNull);
  });
  testWidgets('late connection lookup cannot navigate after account switch',
      (tester) async {
    final api = NotificationsFakeApi()
      ..notifications = [testNotification(1, read: true)];
    final pending = Completer<List<ContactLink>>();
    final app = await boot(tester, api);
    await tester.tap(find.byTooltip('Notifications, 0 unread'));
    await tester.pumpAndSettle();
    api.onIncoming = () => pending.future;
    await tester.tap(find.text('Test notification 1'));
    await tester.pump();
    app.userProfile = testProfile('bob');
    pending.complete([testLink(7, 'pending')]);
    await tester.pumpAndSettle();
    expect(find.byType(ContactLinksScreen), findsNothing);
    expect(app.notifications.items, isEmpty);
  });
}
