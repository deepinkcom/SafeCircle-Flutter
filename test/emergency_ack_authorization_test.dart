import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safecircle/models/models.dart';
import 'package:safecircle/models/backend_profile_status.dart';
import 'package:safecircle/models/contact_link.dart';
import 'package:safecircle/services/api_failure.dart';
import 'package:safecircle/state/app_state.dart';
import 'package:safecircle/screens/emergency_nearby_screen.dart';

import 'support/contact_links_fakes.dart';

class EmergencyAuthorizationApi extends ContactLinksFakeApi {
  final acknowledgementCalls = <int>[];

  @override
  Future<Map<String, dynamic>> acknowledgeAlert(int alertId) async {
    acknowledgementCalls.add(alertId);
    return {
      'id': 77,
      'alert_id': alertId,
      'responder_user_id': 1,
      'status': 'on_my_way',
      'created_at': '2026-11-15T10:00:00+00:00',
    };
  }
}

NearbyPerson alert({int id = 900, int owner = 2}) => NearbyPerson(
      id: id,
      ownerUserId: owner,
      name: 'Emergency contact',
      distanceLabel: '0.3 km away',
      locationLabel: 'Safe synthetic area',
      status: 'active',
      createdAt: DateTime.utc(2026, 11, 15, 9),
      latitude: -33.9,
      longitude: 18.4,
    );

Future<void> pumpFrames(WidgetTester tester) async {
  // RealMap intentionally retains its progress indicator while the platform
  // location channel is unavailable in widget tests, so avoid pumpAndSettle.
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late EmergencyAuthorizationApi api;
  late AppState app;

  Future<void> prepare({
    List<ContactLink> links = const [],
    Future<List<ContactLink>> Function()? onAccepted,
    Future<BackendProfileStatus> Function()? onProfile,
  }) async {
    api = EmergencyAuthorizationApi()
      ..acceptedData = links
      ..onAccepted = onAccepted
      ..onProfileStatus = onProfile;
    app = AppState(apiService: api, authService: ContactLinksFakeAuth())
      ..userProfile = testProfile('alice');
    await app.checkBackendProfile();
  }

  Future<void> showAlert(WidgetTester tester,
      {int owner = 2, Future<void> Function()? onImOnMyWay}) async {
    final item = alert(owner: owner);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          home: EmergencyNearbyScreen(
            notificationAlert: item,
            notificationSession: app.notifications.sessionVersion,
            onBack: () {},
            onImOnMyWay: onImOnMyWay ??
                () => app.acknowledgeNearbyAlert(
                    notificationAlert: item,
                    notificationSession: app.notifications.sessionVersion),
          ),
        ),
      ),
    );
  }

  tearDown(() => app.dispose());

  testWidgets('accepted emergency contact sees and uses acknowledgement',
      (tester) async {
    await prepare(links: [testLink(1, 'accepted', incoming: false)]);
    await showAlert(tester);
    await pumpFrames(tester);

    final action = find.text("I'm On My Way");
    expect(action, findsOneWidget);
    final button = tester.widget<OutlinedButton>(
      find.ancestor(of: action, matching: find.byType(OutlinedButton)),
    );
    expect(button.onPressed, isNotNull);

    await tester.ensureVisible(action);
    await tester.tap(action);
    await pumpFrames(tester);
    expect(api.acknowledgementCalls, [900]);
    expect(app.alertHistory.single.id, 77);
    expect(app.alertHistory.single.status, AlertStatus.acknowledged);
  });

  testWidgets('unrelated nearby user receives contact-only explanation',
      (tester) async {
    await prepare();
    await showAlert(tester);
    await pumpFrames(tester);

    expect(find.text("I'm On My Way"), findsNothing);
    expect(find.textContaining('Only accepted emergency contacts'),
        findsOneWidget);
  });

  for (final status in ['revoked', 'rejected', 'pending']) {
    testWidgets('$status relationship does not grant acknowledgement',
        (tester) async {
      await prepare(links: [testLink(1, status, incoming: false)]);
      await showAlert(tester);
      await pumpFrames(tester);

      expect(find.text("I'm On My Way"), findsNothing);
      expect(find.textContaining('Only accepted emergency contacts'),
          findsOneWidget);
    });
  }

  testWidgets('account switching clears previous accepted authorization',
      (tester) async {
    late AppState state;
    final switchingApi = EmergencyAuthorizationApi()
      ..acceptedData = [testLink(1, 'accepted', incoming: false)]
      ..onProfileStatus = () async => BackendProfileStatus(
          id: state.userProfile.uid == 'alice' ? 1 : 3,
          profileReady: true,
          missingFields: []);
    state =
        AppState(apiService: switchingApi, authService: ContactLinksFakeAuth())
          ..userProfile = testProfile('alice');
    app = state;
    await app.checkBackendProfile();
    await showAlert(tester);
    await pumpFrames(tester);
    expect(find.text("I'm On My Way"), findsOneWidget);

    switchingApi.acceptedData = [];
    app.userProfile = testProfile('bob');
    await tester.pump();
    expect(find.text("I'm On My Way"), findsNothing);
    await app.checkBackendProfile();
    await pumpFrames(tester);
    expect(find.text("I'm On My Way"), findsNothing);
  });

  testWidgets('stale accepted cache is hidden until revoked state refreshes',
      (tester) async {
    await prepare(links: [testLink(1, 'accepted', incoming: false)]);
    await app.contactLinks.loadAcceptedRelationships();
    expect(app.contactLinks.accepted.items, hasLength(1));

    final completer = Completer<List<ContactLink>>();
    api.onAccepted = () => completer.future;
    await showAlert(tester);
    await pumpFrames(tester);
    expect(find.text("I'm On My Way"), findsNothing);

    completer.complete([]);
    await pumpFrames(tester);
    expect(find.text("I'm On My Way"), findsNothing);
    expect(find.textContaining('Only accepted emergency contacts'),
        findsOneWidget);
  });

  testWidgets('loading relationship lookup never exposes action',
      (tester) async {
    final completer = Completer<List<ContactLink>>();
    await prepare(onAccepted: () => completer.future);
    await showAlert(tester);
    await tester.pump();

    expect(find.text("I'm On My Way"), findsNothing);
    expect(find.textContaining('Checking emergency-contact'), findsOneWidget);

    completer.complete([]);
    await pumpFrames(tester);
    expect(find.text("I'm On My Way"), findsNothing);
  });

  testWidgets('relationship lookup failure fails closed for expired session',
      (tester) async {
    await prepare(
        onAccepted: () async =>
            throw const ApiFailure(ApiFailureKind.authentication));
    await showAlert(tester);
    await pumpFrames(tester);

    expect(find.text("I'm On My Way"), findsNothing);
    expect(app.contactLinks.needsAuthentication, isTrue);
    expect(find.textContaining('session expired'), findsOneWidget);
  });

  testWidgets('alert owner cannot acknowledge own alert', (tester) async {
    await prepare(links: [testLink(1, 'accepted', incoming: false)]);
    await showAlert(tester, owner: 1);
    await pumpFrames(tester);

    expect(find.text("I'm On My Way"), findsNothing);
    expect(find.textContaining('cannot acknowledge your own'), findsOneWidget);
  });
}
