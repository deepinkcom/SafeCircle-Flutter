import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:safecircle/firebase_bootstrap.dart';
import 'package:safecircle/models/models.dart';
import 'package:safecircle/screens/login_screen.dart';
import 'package:safecircle/services/auth_service.dart';
import 'package:safecircle/services/google_sign_in_service.dart';
import 'package:safecircle/services/user_repository.dart';
import 'package:safecircle/state/app_state.dart';

import 'support/contact_links_fakes.dart';

class GoogleIdentity extends Fake implements GoogleSignInService {
  Object? error;
  int signOuts = 0;
  @override
  Future<AuthCredential> authenticate() async {
    if (error != null) throw error!;
    return GoogleAuthProvider.credential(idToken: 'synthetic-secret-token');
  }

  @override
  Future<void> signOut() async {
    signOuts++;
  }
}

class GoogleUser extends Fake implements User {
  @override
  String get uid => 'synthetic-google-user';
  @override
  String get displayName => 'Example Member';
  @override
  String get email => 'member@example.invalid';
}

class GoogleResult extends Fake implements UserCredential {
  @override
  User get user => GoogleUser();
}

class GoogleAuth extends Fake implements FirebaseAuth {
  int signIns = 0;
  int signOuts = 0;
  Object? error;
  @override
  Future<UserCredential> signInWithCredential(AuthCredential credential) async {
    signIns++;
    expect(credential.providerId, 'google.com');
    if (error != null) throw error!;
    return GoogleResult();
  }

  @override
  Future<void> signOut() async {
    signOuts++;
  }
}

class GoogleProfiles extends Fake implements UserRepository {
  UserProfile? existing;
  UserProfile? created;
  Object? error;
  int reads = 0;
  @override
  Future<UserProfile?> fetchUser(String uid) async {
    reads++;
    if (error != null) throw error!;
    return existing;
  }

  @override
  Future<void> createUser(UserProfile profile) async {
    created = profile;
  }
}

class StateGoogleAuth extends AuthService {
  final Completer<UserProfile?> result = Completer<UserProfile?>();
  @override
  Future<UserProfile?> logInWithGoogle() => result.future;
}

void main() {
  setUp(() => FirebaseBootstrap.isReady = true);
  tearDown(() => FirebaseBootstrap.isReady = false);

  test('new Google user gets a profile without invented phone or city',
      () async {
    final profiles = GoogleProfiles();
    final events = <Map<String, Object?>>[];
    final auth = GoogleAuth();
    final service = AuthService(
        auth: auth,
        users: profiles,
        googleSignIn: GoogleIdentity(),
        diagnostics: events.add);
    final profile = await service.logInWithGoogle();
    expect(auth.signIns, 1);
    expect(profile!.uid, 'synthetic-google-user');
    expect(profile.name, 'Example Member');
    expect(profile.phone, isEmpty);
    expect(profile.city, isEmpty);
    expect(profiles.created, profile);
    expect(jsonEncode(events), isNot(contains('synthetic')));
    expect(jsonEncode(events), isNot(contains('example.invalid')));
  });

  test('existing profile details and photo are preserved', () async {
    final existing = testProfile('synthetic-google-user');
    final profiles = GoogleProfiles()..existing = existing;
    final service = AuthService(
        auth: GoogleAuth(), users: profiles, googleSignIn: GoogleIdentity());
    expect(await service.logInWithGoogle(), same(existing));
    expect(profiles.created, isNull);
  });

  test('cancelled chooser does not sign into Firebase or create a profile',
      () async {
    final google = GoogleIdentity()
      ..error =
          const GoogleSignInException(code: GoogleSignInExceptionCode.canceled);
    final auth = GoogleAuth();
    final profiles = GoogleProfiles();
    expect(
        await AuthService(auth: auth, users: profiles, googleSignIn: google)
            .logInWithGoogle(),
        isNull);
    expect(auth.signIns, 0);
    expect(profiles.reads, 0);
  });

  test('account conflict gives safe recovery without creating a profile',
      () async {
    final auth = GoogleAuth()
      ..error = FirebaseAuthException(
          code: 'account-exists-with-different-credential',
          message: 'private detail');
    final profiles = GoogleProfiles();
    await expectLater(
        AuthService(auth: auth, users: profiles, googleSignIn: GoogleIdentity())
            .logInWithGoogle(),
        throwsA(isA<AuthFailure>()
            .having((e) => e.message, 'message', contains('existing method'))));
    expect(profiles.reads, 0);
  });

  test('configuration errors do not expose provider details', () async {
    final google = GoogleIdentity()
      ..error = const GoogleSignInException(
          code: GoogleSignInExceptionCode.clientConfigurationError,
          description: 'private OAuth details');
    final events = <Map<String, Object?>>[];
    await expectLater(
        AuthService(
                auth: GoogleAuth(),
                users: GoogleProfiles(),
                googleSignIn: google,
                diagnostics: events.add)
            .logInWithGoogle(),
        throwsA(isA<AuthFailure>().having(
            (e) => e.message, 'message', contains('signing fingerprint'))));
    expect(jsonEncode(events), isNot(contains('private')));
  });

  test('Firestore failures are distinguished from Google authentication',
      () async {
    final profiles = GoogleProfiles()
      ..error = FirebaseException(
          plugin: 'cloud_firestore', code: 'permission-denied');
    await expectLater(
        AuthService(
                auth: GoogleAuth(),
                users: profiles,
                googleSignIn: GoogleIdentity())
            .logInWithGoogle(),
        throwsA(isA<AuthFailure>().having((e) => e.message, 'message',
            contains('profile could not be loaded'))));
  });

  test('logout signs out Firebase and the Google chooser session', () async {
    final auth = GoogleAuth();
    final google = GoogleIdentity();
    await AuthService(auth: auth, users: GoogleProfiles(), googleSignIn: google)
        .logOut();
    expect(auth.signOuts, 1);
    expect(google.signOuts, 1);
  });

  test('Google login uses existing backend profile readiness checks', () async {
    final auth = StateGoogleAuth();
    final api = ContactLinksFakeApi();
    final app = AppState(authService: auth, apiService: api);
    final login = app.logInWithGoogle();
    auth.result.complete(testProfile('google-user'));
    expect(await login, isNull);
    expect(app.userProfile.uid, 'google-user');
    expect(api.profileStatusReads, 1);
    app.dispose();
  });

  test('disposed login cannot apply a late Google account result', () async {
    final auth = StateGoogleAuth();
    final app = AppState(authService: auth, apiService: ContactLinksFakeApi());
    final login = app.logInWithGoogle();
    app.dispose();
    auth.result.complete(testProfile('late-user'));
    expect(await login, isNotNull);
    expect(app.userProfile.uid, isEmpty);
  });

  testWidgets(
      'Google button prevents duplicate login and recovers from cancellation',
      (tester) async {
    final pending = Completer<String?>();
    int calls = 0;
    await tester.pumpWidget(MaterialApp(
        home: LoginScreen(
      onLogIn: (_, __) async => null,
      onCreateAccount: () {},
      onGoogleSignIn: () {
        calls++;
        return pending.future;
      },
    )));
    final google = find.text('Continue with Google');
    await tester.ensureVisible(google);
    await tester.tap(google);
    await tester.pump();
    await tester.tap(google);
    expect(calls, 1);
    pending.complete('Google sign-in was cancelled.');
    await tester.pumpAndSettle();
    expect(find.text('Google sign-in was cancelled.'), findsOneWidget);
    expect(
        tester
            .widget<OutlinedButton>(find.ancestor(
                of: google, matching: find.byType(OutlinedButton)))
            .onPressed,
        isNotNull);
  });
}
