import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safecircle/firebase_bootstrap.dart';
import 'package:safecircle/models/models.dart';
import 'package:safecircle/services/auth_service.dart';
import 'package:safecircle/services/user_repository.dart';

class LoginAuth extends Fake implements FirebaseAuth {
  Object? error;
  @override
  Future<UserCredential> signInWithEmailAndPassword(
      {required String email, required String password}) async {
    if (error != null) throw error!;
    return LoginCredential();
  }
}

class LoginCredential extends Fake implements UserCredential {
  @override
  User get user => LoginUser();
}

class LoginUser extends Fake implements User {
  @override
  String get uid => 'synthetic-private-uid';
}

class LoginProfiles extends Fake implements UserRepository {
  int reads = 0;
  Object? error;
  @override
  Future<UserProfile?> fetchUser(String uid) async {
    reads++;
    if (error != null) throw error!;
    return const UserProfile(
        uid: 'synthetic-private-uid', name: '', city: '', email: '', phone: '');
  }
}

void main() {
  setUp(() => FirebaseBootstrap.isReady = true);
  tearDown(() => FirebaseBootstrap.isReady = false);
  test('uninitialized Firebase is diagnosed before sign-in', () async {
    FirebaseBootstrap.isReady = false;
    final events = <Map<String, Object?>>[];
    final service = AuthService(
        auth: LoginAuth(), users: LoginProfiles(), diagnostics: events.add);
    await expectLater(
        service.logIn(
            email: 'private@example.invalid', password: 'private-password'),
        throwsA(isA<AuthFailure>()));
    expect(events.single['stage'], 'firebase_initialization_unavailable');
  });
  test('invalid credentials are distinct from network errors and never exposed',
      () async {
    final auth = LoginAuth()
      ..error = FirebaseAuthException(
          code: 'invalid-credential', message: 'private provider detail');
    final events = <Map<String, Object?>>[];
    final profiles = LoginProfiles();
    final service =
        AuthService(auth: auth, users: profiles, diagnostics: events.add);
    await expectLater(
        service.logIn(
            email: 'private@example.invalid', password: 'private-password'),
        throwsA(isA<AuthFailure>().having(
            (e) => e.message, 'message', 'Email or password is incorrect.')));
    expect(events.last['firebase_exception_code'], 'invalid-credential');
    expect(profiles.reads, 0);
    expect(jsonEncode(events), isNot(contains('private')));
  });
  test(
      'Firebase network error happens before profile access and logs no identity',
      () async {
    final auth = LoginAuth()
      ..error = FirebaseAuthException(
          code: 'network-request-failed', message: 'private provider detail');
    final profiles = LoginProfiles();
    final events = <Map<String, Object?>>[];
    final service =
        AuthService(auth: auth, users: profiles, diagnostics: events.add);
    await expectLater(
        service.logIn(
            email: 'private@example.invalid', password: 'private-password'),
        throwsA(isA<AuthFailure>().having(
            (e) => e.message, 'message', contains('Firebase sign-in'))));
    expect(profiles.reads, 0);
    expect(events.last['stage'], 'firebase_sign_in_failed');
    expect(events.last['firebase_exception_code'], 'network-request-failed');
    expect(jsonEncode(events), isNot(contains('private')));
  });
  test('Firestore failure is distinguished from successful Firebase sign-in',
      () async {
    final profiles = LoginProfiles()
      ..error = FirebaseException(
          plugin: 'cloud_firestore',
          code: 'permission-denied',
          message: 'private data');
    final events = <Map<String, Object?>>[];
    final service = AuthService(
        auth: LoginAuth(), users: profiles, diagnostics: events.add);
    await expectLater(
        service.logIn(
            email: 'private@example.invalid', password: 'private-password'),
        throwsA(isA<AuthFailure>().having(
            (e) => e.message, 'message', contains('Sign-in succeeded'))));
    expect(events.last['stage'], 'firestore_profile_failed');
    expect(events.last['firebase_exception_code'], 'permission-denied');
    expect(jsonEncode(events), isNot(contains('private')));
  });
  test('successful login completes both stages', () async {
    final events = <Map<String, Object?>>[];
    final service = AuthService(
        auth: LoginAuth(), users: LoginProfiles(), diagnostics: events.add);
    final profile = await service.logIn(
        email: 'private@example.invalid', password: 'private-password');
    expect(profile.uid, 'synthetic-private-uid');
    expect(events.last['stage'], 'firestore_profile_succeeded');
    expect(jsonEncode(events), isNot(contains('private')));
  });
}
