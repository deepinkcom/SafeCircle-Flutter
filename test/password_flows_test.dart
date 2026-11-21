import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safecircle/firebase_bootstrap.dart';
import 'package:safecircle/screens/login_screen.dart';
import 'package:safecircle/screens/password_screens.dart';
import 'package:safecircle/services/auth_service.dart';
import 'package:safecircle/state/app_state.dart';

import 'support/contact_links_fakes.dart';

class PasswordProvider extends Fake implements UserInfo {
  PasswordProvider(this.providerId);
  @override
  final String providerId;
}

class PasswordUser extends Fake implements User {
  PasswordUser({this.uid = 'alice', this.provider = 'password'});
  @override
  final String uid;
  final String provider;
  @override
  String get email => 'member@example.invalid';
  @override
  List<UserInfo> get providerData => [PasswordProvider(provider)];
  final calls = <String>[];
  Object? reauthError;
  Object? updateError;
  void Function()? afterReauth;
  String? savedPassword;
  @override
  Future<UserCredential> reauthenticateWithCredential(
      AuthCredential credential) async {
    calls.add('reauthenticate');
    expect(credential.providerId, 'password');
    if (reauthError != null) throw reauthError!;
    afterReauth?.call();
    return PasswordCredential();
  }

  @override
  Future<void> updatePassword(String newPassword) async {
    calls.add('update');
    if (updateError != null) throw updateError!;
    savedPassword = newPassword;
  }
}

class PasswordCredential extends Fake implements UserCredential {}

class PasswordAuth extends Fake implements FirebaseAuth {
  @override
  User? currentUser = PasswordUser();
  String? resetEmail;
  Object? resetError;
  @override
  Future<void> sendPasswordResetEmail(
      {required String email, ActionCodeSettings? actionCodeSettings}) async {
    resetEmail = email;
    if (resetError != null) throw resetError!;
  }
}

class PendingPasswordService extends AuthService {
  int requests = 0;
  final pending = Completer<void>();
  bool Function()? current;
  @override
  Future<void> changePassword(
      {required String ownerUid,
      required String currentPassword,
      required String newPassword,
      required bool Function() isCurrent}) async {
    requests++;
    current = isCurrent;
    await pending.future;
  }
}

Future<void> change(AuthService service, {bool Function()? current}) =>
    service.changePassword(
      ownerUid: 'alice',
      currentPassword: 'old-secret',
      newPassword: 'new-secret',
      isCurrent: current ?? () => true,
    );

void main() {
  setUp(() => FirebaseBootstrap.isReady = true);
  tearDown(() => FirebaseBootstrap.isReady = false);

  test('reset sends the trimmed address to Firebase', () async {
    final auth = PasswordAuth();
    await AuthService(auth: auth).sendPasswordReset(' member@example.invalid ');
    expect(auth.resetEmail, 'member@example.invalid');
  });

  test('invalid reset email is rejected before Firebase', () async {
    final auth = PasswordAuth();
    await expectLater(AuthService(auth: auth).sendPasswordReset('invalid'),
        throwsA(isA<AuthFailure>()));
    expect(auth.resetEmail, isNull);
  });

  test('unknown email does not reveal account existence', () async {
    final auth = PasswordAuth()
      ..resetError = FirebaseAuthException(code: 'user-not-found');
    await AuthService(auth: auth).sendPasswordReset('unknown@example.invalid');
  });

  test('reset network failures are retryable and hide provider details',
      () async {
    final auth = PasswordAuth()
      ..resetError = FirebaseAuthException(
          code: 'network-request-failed', message: 'private-provider-detail');
    await expectLater(
        AuthService(auth: auth).sendPasswordReset('member@example.invalid'),
        throwsA(isA<AuthFailure>().having(
            (e) => e.message, 'message', contains('Check your connection'))));
  });

  test('password update reauthenticates before changing the password',
      () async {
    final auth = PasswordAuth();
    final user = auth.currentUser! as PasswordUser;
    await change(AuthService(auth: auth));
    expect(user.calls, ['reauthenticate', 'update']);
    expect(user.savedPassword, 'new-secret');
  });

  test('wrong current password blocks update', () async {
    final auth = PasswordAuth();
    final user = auth.currentUser! as PasswordUser;
    user.reauthError = FirebaseAuthException(code: 'invalid-credential');
    await expectLater(
        change(AuthService(auth: auth)),
        throwsA(isA<AuthFailure>().having((e) => e.message, 'message',
            contains('current password is incorrect'))));
    expect(user.calls, ['reauthenticate']);
  });

  test('Google-only accounts cannot acquire a password through this flow',
      () async {
    final user = PasswordUser(provider: 'google.com');
    final auth = PasswordAuth()..currentUser = user;
    final service = AuthService(auth: auth);
    expect(service.canChangePasswordFor('alice'), isFalse);
    await expectLater(
        change(service),
        throwsA(isA<AuthFailure>()
            .having((e) => e.message, 'message', contains('Google Account'))));
    expect(user.calls, isEmpty);
  });

  test('server password policy rejection gets safe guidance', () async {
    final auth = PasswordAuth();
    final user = auth.currentUser! as PasswordUser;
    user.updateError = FirebaseAuthException(code: 'weak-password');
    await expectLater(
        change(AuthService(auth: auth)),
        throwsA(isA<AuthFailure>().having(
            (e) => e.message, 'message', contains('stronger password'))));
    expect(user.savedPassword, isNull);
  });

  test('account switch during reauthentication blocks the password update',
      () async {
    final auth = PasswordAuth();
    final user = auth.currentUser! as PasswordUser;
    user.afterReauth = () => auth.currentUser = PasswordUser(uid: 'bob');
    await expectLater(
        change(AuthService(auth: auth)), throwsA(isA<AuthFailure>()));
    expect(user.calls, ['reauthenticate']);
  });

  test('same-account new session invalidates an old password form', () async {
    final auth = PasswordAuth();
    final user = auth.currentUser! as PasswordUser;
    bool current = true;
    user.afterReauth = () => current = false;
    await expectLater(change(AuthService(auth: auth), current: () => current),
        throwsA(isA<AuthFailure>()));
    expect(user.calls, ['reauthenticate']);
  });

  test('signed-out user cannot change a password', () async {
    final auth = PasswordAuth()..currentUser = null;
    await expectLater(
        change(AuthService(auth: auth)), throwsA(isA<AuthFailure>()));
  });

  test('state rejects duplicate submissions and invalidates disposed requests',
      () async {
    final service = PendingPasswordService();
    final app =
        AppState(authService: service, apiService: ContactLinksFakeApi());
    app.userProfile = testProfile('alice');
    final first = app.changePassword(
        ownerUid: 'alice', currentPassword: 'old', newPassword: 'next-secret');
    expect(
        await app.changePassword(
            ownerUid: 'alice',
            currentPassword: 'old',
            newPassword: 'next-secret'),
        contains('already being updated'));
    expect(service.requests, 1);
    app.dispose();
    expect(service.current!(), isFalse);
    service.pending.complete();
    expect(await first, isNotNull);
  });

  testWidgets('Forgot Password opens a prefilled reset screen and submits once',
      (tester) async {
    final pending = Completer<String?>();
    int calls = 0;
    await tester.pumpWidget(MaterialApp(
        home: LoginScreen(
      onLogIn: (_, __) async => null,
      onCreateAccount: () {},
      onPasswordReset: (email) {
        calls++;
        expect(email, 'member@example.invalid');
        return pending.future;
      },
    )));
    await tester.enterText(
        find.byType(TextField).first, 'member@example.invalid');
    await tester.ensureVisible(find.text('Forgot Password?'));
    await tester.tap(find.text('Forgot Password?'));
    await tester.pumpAndSettle();
    expect(find.byType(ForgotPasswordScreen), findsOneWidget);
    await tester.tap(find.text('Send reset email'));
    await tester.pump();
    await tester.tap(find.text('Requesting reset…'));
    expect(calls, 1);
    pending.complete(null);
    await tester.pumpAndSettle();
    expect(find.textContaining('If an email/password account exists'),
        findsOneWidget);
  });

  testWidgets('new password mismatch prevents submission', (tester) async {
    int calls = 0;
    await tester.pumpWidget(MaterialApp(
        home: ChangePasswordScreen(
      passwordEnabled: true,
      onChange: (_, __) async {
        calls++;
        return null;
      },
    )));
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'old-secret');
    await tester.enterText(fields.at(1), 'new-secret');
    await tester.enterText(fields.at(2), 'different');
    await tester.ensureVisible(find.text('Save new password'));
    await tester.tap(find.text('Save new password'));
    await tester.pumpAndSettle();
    expect(find.text('The new passwords do not match.'), findsOneWidget);
    expect(calls, 0);
  });

  testWidgets('successful change clears password fields and shows confirmation',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: ChangePasswordScreen(
      passwordEnabled: true,
      onChange: (old, next) async {
        expect(old, 'old-secret');
        expect(next, 'new-secret');
        return null;
      },
    )));
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'old-secret');
    await tester.enterText(fields.at(1), 'new-secret');
    await tester.enterText(fields.at(2), 'new-secret');
    await tester.ensureVisible(find.text('Save new password'));
    await tester.tap(find.text('Save new password'));
    await tester.pumpAndSettle();
    expect(find.text('Your password has been changed.'), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);
  });

  testWidgets('Google-only password screen has guidance and no password form',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: ChangePasswordScreen(
      passwordEnabled: false,
      onChange: (_, __) async => throw StateError('must not run'),
    )));
    expect(find.textContaining('Google Account'), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);
  });
}
