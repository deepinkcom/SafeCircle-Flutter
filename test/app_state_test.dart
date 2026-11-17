import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safecircle/models/contact_link.dart';
import 'package:safecircle/models/models.dart';
import 'package:safecircle/services/api_service.dart';
import 'package:safecircle/services/auth_service.dart';
import 'package:safecircle/services/location_service.dart';
import 'package:safecircle/state/app_state.dart';

import 'support/contact_links_fakes.dart';

class FakeLocationService extends LocationService {
  bool shouldFail = false;
  int locationCalls = 0;
  int readableLocationCalls = 0;
  bool shouldFailReadable = false;
  final updates = StreamController<({double lat, double lng})>.broadcast();

  @override
  Stream<({double lat, double lng})> watchLocation() => updates.stream;

  @override
  Future<({double lat, double lng})> getCurrentLocation() async {
    locationCalls++;

    if (shouldFail) {
      throw Exception('Simulated location failure');
    }

    return (lat: -33.9, lng: 18.4);
  }

  @override
  Future<String> getReadableLocation({
    required double lat,
    required double lng,
  }) async {
    readableLocationCalls++;
    if (shouldFailReadable) throw StateError('No geocoder');
    return 'Test location';
  }
}

class FakeApiService extends ApiService {
  bool shouldFail = false;
  bool shouldFailResolve = false;
  int panicCalls = 0;
  int resolveCalls = 0;
  int? resolvedAlertId;
  double? sentLatitude;
  double? sentLongitude;
  int locationUpdates = 0;
  double? updatedLatitude;
  double? updatedLongitude;

  FakeApiService() : super(baseUrl: 'http://127.0.0.1:1');

  @override
  Future<int> sendPanicAlert({
    required double latitude,
    required double longitude,
  }) async {
    panicCalls++;
    sentLatitude = latitude;
    sentLongitude = longitude;

    if (shouldFail) {
      throw Exception('Simulated API failure');
    }

    return 123;
  }

  @override
  Future<void> resolveAlert(int alertId) async {
    resolveCalls++;
    resolvedAlertId = alertId;

    if (shouldFailResolve) {
      throw Exception('Simulated resolve failure');
    }
  }

  @override
  Future<void> updateAlertLocation({
    required int alertId,
    required double latitude,
    required double longitude,
  }) async {
    locationUpdates++;
    updatedLatitude = latitude;
    updatedLongitude = longitude;
  }
}

class FakeAuthService extends AuthService {}

void main() {
  test('restores own active emergency using owner-authorized server location',
      () async {
    final api = ContactLinksFakeApi()
      ..onAlertLocation = (id) async => {
            'id': id,
            'owner_user_id': 1,
            'status': 'active',
            'latitude': -33.9,
            'longitude': 18.4,
            'created_at': '2026-11-16T10:00:00Z',
          };
    final app = AppState(
        apiService: api,
        authService: ContactLinksFakeAuth(),
        locationService: FakeLocationService())
      ..userProfile = testProfile('alice');
    addTearDown(app.dispose);
    await app.checkBackendProfile();
    const event = AlertEvent(
      id: 44,
      kind: AlertKind.emergencySent,
      title: 'Emergency sent',
      timeLabel: '16 Nov 2026, 10:00',
      locationLabel: 'Test location',
      status: AlertStatus.active,
    );
    app.alertHistory.add(event);

    expect(await app.restoreActiveEmergency(event), isTrue);
    expect(app.isEmergencyActive, isTrue);
    expect(app.activeEmergencyPerson?.id, 44);
    expect(app.activeEmergencyPerson?.hasValidLocation, isTrue);
    expect(app.locationUpdatedAt, isNull);
  });

  relationshipIntegrationTests();
  late FakeLocationService location;
  late FakeApiService api;
  late AppState state;

  setUp(() {
    location = FakeLocationService();
    api = FakeApiService();

    state = AppState(
      locationService: location,
      apiService: api,
      authService: FakeAuthService(),
    );
  });

  tearDown(() {
    state.dispose();
    location.updates.close();
  });

  test('starts emergency after location and API succeed', () async {
    await state.startEmergency();

    expect(location.locationCalls, 1);
    expect(location.readableLocationCalls, 1);
    expect(api.panicCalls, 1);
    expect(api.sentLatitude, -33.9);
    expect(api.sentLongitude, 18.4);

    expect(state.isEmergencyActive, isTrue);
    expect(state.activeEmergencyPerson?.latitude, -33.9);
    expect(state.activeEmergencyPerson?.longitude, 18.4);
    expect(state.currentLocation, 'Test location');
    expect(state.alertHistory, hasLength(1));
    expect(state.alertHistory.first.id, 123);
    expect(state.alertHistory.first.kind, AlertKind.emergencySent);
    expect(state.alertHistory.first.status, AlertStatus.active);
  });

  test('does not send API request if location retrieval fails', () async {
    location.shouldFail = true;

    await expectLater(
      state.startEmergency(),
      throwsA(isA<Exception>()),
    );

    expect(location.locationCalls, 1);
    expect(location.readableLocationCalls, 0);
    expect(api.panicCalls, 0);
    expect(state.isEmergencyActive, isFalse);
    expect(state.alertHistory, isEmpty);
  });

  test('does not activate emergency if API request fails', () async {
    api.shouldFail = true;

    await expectLater(
      state.startEmergency(),
      throwsA(isA<Exception>()),
    );

    expect(location.locationCalls, 1);
    expect(location.readableLocationCalls, 1);
    expect(api.panicCalls, 1);
    expect(state.isEmergencyActive, isFalse);
    expect(state.alertHistory, isEmpty);
  });

  test('uses coordinates when reverse geocoding is unavailable', () async {
    location.shouldFailReadable = true;
    await state.startEmergency();
    expect(api.panicCalls, 1);
    expect(state.currentLocation, '-33.90000, 18.40000');
    expect(state.activeEmergencyPerson?.hasValidLocation, isTrue);
  });

  test('uploads fresh GPS coordinates during an active emergency', () async {
    await state.startEmergency();
    location.updates.add((lat: -33.8, lng: 18.5));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(api.locationUpdates, 1);
    expect(api.updatedLatitude, -33.8);
    expect(api.updatedLongitude, 18.5);
    expect(state.activeEmergencyPerson?.latitude, -33.8);
  });

  test('keeps emergency active if backend resolution fails', () async {
    // Arrange: create an active emergency using fake services.
    await state.startEmergency();
    api.shouldFailResolve = true;

    // Act: simulate the backend failing to resolve the alert.
    await expectLater(
      state.resolveEmergency(),
      throwsA(isA<Exception>()),
    );

    // Assert: local state should still reflect the active emergency.
    expect(api.resolveCalls, 1);
    expect(api.resolvedAlertId, 123);
    expect(state.isEmergencyActive, isTrue);
    expect(state.alertHistory, hasLength(1));
    expect(state.alertHistory.first.status, AlertStatus.active);
  });

  test('resolves emergency after backend succeeds', () async {
    // Arrange: create an active emergency using fake services.
    await state.startEmergency();

    // Act: simulate successful backend resolution.
    await state.resolveEmergency();

    // Assert: local state reflects successful resolution.
    expect(api.resolveCalls, 1);
    expect(api.resolvedAlertId, 123);
    expect(state.isEmergencyActive, isFalse);
    expect(state.alertHistory, hasLength(1));
    expect(
      state.alertHistory.first.status,
      AlertStatus.resolved,
    );
  });
}

void relationshipIntegrationTests() {
  group('AppState relationship integration', () {
    late ContactLinksFakeApi api;
    late ContactLinksFakeAuth auth;
    late AppState app;
    setUp(() {
      api = ContactLinksFakeApi();
      auth = ContactLinksFakeAuth();
      app = AppState(apiService: api, authService: auth);
    });
    tearDown(() => app.dispose());

    for (final operation in ['restore', 'login', 'signup']) {
      test('$operation binds the feature to the authenticated Firebase UID',
          () async {
        expect(app.contactLinks.userId, isNull);
        switch (operation) {
          case 'restore':
            expect(await app.restoreSession(), isTrue);
          case 'login':
            expect(
                await app.logIn(
                    email: 'alice@example.invalid', password: 'synthetic'),
                isNull);
          case 'signup':
            expect(
                await app.signUp(
                    fullName: 'Alice',
                    email: 'alice@example.invalid',
                    phone: '000',
                    password: 'synthetic'),
                isNull);
        }
        expect(app.userProfile.uid, 'alice');
        expect(app.contactLinks.userId, 'alice');
        expect(api.incomingCalls + api.outgoingCalls + api.acceptedCalls, 0);
        api.incomingData = [testLink(7, 'pending')];
        expect(await app.contactLinks.loadIncomingInvitations(), isTrue);
        expect(api.incomingCalls, 1);
      });
    }

    test(
        'logout clears relationship data and gates before Firebase sign-out finishes',
        () async {
      app.userProfile = testProfile('alice');
      api.incomingData = [testLink(7, 'pending')];
      await app.contactLinks.loadIncomingInvitations();
      final pending = Completer<List<ContactLink>>();
      api.onIncoming = () => pending.future;
      final read = app.contactLinks.loadIncomingInvitations();
      final signOut = Completer<void>();
      auth.onLogout = () => signOut.future;
      final logout = app.logOut();
      expect(app.contactLinks.userId, isNull);
      expect(app.contactLinks.incoming.items, isEmpty);
      pending.complete([testLink(8, 'pending')]);
      expect(await read, isFalse);
      signOut.complete();
      await logout;
      expect(app.userProfile.isSignedIn, isFalse);
    });

    test(
        'Firebase sign-out failure keeps the account from being reported signed out',
        () async {
      app.userProfile = testProfile('alice');
      auth.onLogout =
          () async => throw AuthFailure('synthetic sign-out failure');

      await expectLater(app.logOut(), throwsA(isA<AuthFailure>()));

      expect(app.userProfile.uid, 'alice');
      expect(app.userProfile.isSignedIn, isTrue);
    });

    test('direct public profile account changes reset relationship caches',
        () async {
      app.userProfile = testProfile('alice');
      api.outgoingData = [testLink(7, 'pending')];
      await app.contactLinks.loadOutgoingInvitations();
      app.setName('Updated name');
      expect(app.contactLinks.outgoing.items, hasLength(1));
      app.userProfile = testProfile('bob');
      expect(app.contactLinks.userId, 'bob');
      expect(app.contactLinks.outgoing.items, isEmpty);
    });

    test('account switching invalidates requests as soon as login starts',
        () async {
      app.userProfile = testProfile('alice');
      final read = Completer<List<ContactLink>>();
      api.onOutgoing = () => read.future;
      final old = app.contactLinks.loadOutgoingInvitations();
      final login = Completer<UserProfile>();
      auth.onLogin = () => login.future;
      final switchAccount =
          app.logIn(email: 'bob@example.invalid', password: 'synthetic');
      expect(app.contactLinks.userId, isNull);
      read.complete([testLink(7, 'pending')]);
      expect(await old, isFalse);
      login.complete(testProfile('bob'));
      expect(await switchAccount, isNull);
      expect(app.contactLinks.userId, 'bob');
      expect(app.contactLinks.outgoing.items, isEmpty);
    });

    for (final operation in ['restore', 'login', 'signup']) {
      test('late $operation cannot restore an account after logout', () async {
        final pending = Completer<UserProfile>();
        auth.onRestore = () => pending.future;
        auth.onLogin = () => pending.future;
        auth.onSignUp = () => pending.future;
        final Future<Object?> request = switch (operation) {
          'restore' => app.restoreSession(),
          'login' =>
            app.logIn(email: 'alice@example.invalid', password: 'synthetic'),
          _ => app.signUp(
              fullName: 'Alice',
              email: 'alice@example.invalid',
              phone: '000',
              password: 'synthetic'),
        };
        await app.logOut();
        pending.complete(testProfile('alice'));
        final result = await request;
        expect(result, operation == 'restore' ? isFalse : isNotNull);
        expect(app.userProfile.isSignedIn, isFalse);
        expect(app.contactLinks.userId, isNull);
      });
    }

    test('the latest concurrent sign-in wins', () async {
      final first = Completer<UserProfile>();
      final second = Completer<UserProfile>();
      auth.onLogin = () => first.future;
      final old =
          app.logIn(email: 'alice@example.invalid', password: 'synthetic');
      auth.onLogin = () => second.future;
      final current =
          app.logIn(email: 'bob@example.invalid', password: 'synthetic');
      second.complete(testProfile('bob'));
      expect(await current, isNull);
      first.complete(testProfile('alice'));
      expect(await old, isNotNull);
      expect(app.userProfile.uid, 'bob');
      expect(app.contactLinks.userId, 'bob');
    });

    test('late logout cannot clear a newer account', () async {
      app.userProfile = testProfile('alice');
      final pending = Completer<void>();
      auth.onLogout = () => pending.future;
      final logout = app.logOut();
      auth.onLogin = () async => testProfile('bob');
      await app.logIn(email: 'bob@example.invalid', password: 'synthetic');
      pending.complete();
      await logout;
      expect(app.userProfile.uid, 'bob');
      expect(app.contactLinks.userId, 'bob');
    });

    test(
        'failed sign-in preserves public profile but keeps uncertain relationship access disabled',
        () async {
      app.userProfile = testProfile('alice');
      api.outgoingData = [testLink(7, 'pending')];
      await app.contactLinks.loadOutgoingInvitations();
      auth.onLogin = () async => throw AuthFailure('Synthetic sign-in failure');
      expect(
          await app.logIn(email: 'bob@example.invalid', password: 'synthetic'),
          'Synthetic sign-in failure');
      expect(app.userProfile.uid, 'alice');
      expect(app.contactLinks.userId, isNull);
      expect(app.contactLinks.needsAuthentication, isTrue);
      expect(app.contactLinks.outgoing.items, isEmpty);
    });

    test('late profile updates cannot rebind a signed-out session', () async {
      app.userProfile = testProfile('alice');
      final pending = Completer<UserProfile>();
      auth.onUpdate = (_) => pending.future;
      final update =
          app.updateProfile(name: 'Updated', phone: '000', city: 'City');
      await app.logOut();
      pending.complete(testProfile('alice'));
      expect(await update, isNotNull);
      expect(app.userProfile.isSignedIn, isFalse);
      expect(app.contactLinks.userId, isNull);
    });

    test(
        'AppState disposes owned feature and suppresses late authentication notifications',
        () async {
      final pending = Completer<UserProfile>();
      auth.onRestore = () => pending.future;
      final restore = app.restoreSession();
      var notifications = 0;
      app.addListener(() => notifications++);
      app.dispose();
      pending.complete(testProfile('alice'));
      expect(await restore, isFalse);
      expect(notifications, 0);
      expect(await app.contactLinks.loadIncomingInvitations(), isFalse);
      expect(api.incomingCalls, 0);
    });

    test(
        'notification-time account changes prevent stale authentication dispatch',
        () async {
      app.userProfile = testProfile('alice');
      var calls = 0;
      auth.onLogin = () async {
        calls++;
        return testProfile('alice');
      };
      app.addListener(() {
        if (app.contactLinks.userId == null) {
          app.userProfile = testProfile('bob');
        }
      });
      expect(
          await app.logIn(
              email: 'alice@example.invalid', password: 'synthetic'),
          isNotNull);
      expect(calls, 0);
      expect(app.userProfile.uid, 'bob');
    });

    test('notification-time account changes prevent stale backend profile sync',
        () async {
      app.userProfile = testProfile('alice');
      app.addListener(() {
        if (app.userProfile.name == 'Updated') {
          app.userProfile = testProfile('bob');
        }
      });
      expect(
          await app.updateProfile(name: 'Updated', phone: '000', city: 'City'),
          isNotNull);
      expect(api.profileSyncs, 0);
      expect(app.userProfile.uid, 'bob');
    });

    testWidgets(
        'existing AppState Provider forwards relationship state notifications',
        (tester) async {
      app.userProfile = testProfile('alice');
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: app,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Consumer<AppState>(
              builder: (_, state, __) => Text(
                  'Incoming: ${state.contactLinks.incoming.items.length}')),
        ),
      ));
      expect(find.text('Incoming: 0'), findsOneWidget);
      api.incomingData = [testLink(7, 'pending')];
      await app.contactLinks.loadIncomingInvitations();
      await tester.pump();
      expect(find.text('Incoming: 1'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
