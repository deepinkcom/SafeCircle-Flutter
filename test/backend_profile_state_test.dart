import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:safecircle/models/backend_profile_status.dart';
import 'package:safecircle/services/api_failure.dart';
import 'package:safecircle/services/api_service.dart';
import 'package:safecircle/state/app_state.dart';
import 'support/contact_links_fakes.dart';

const missing = BackendProfileStatus(
    id: null, profileReady: false, missingFields: ['name', 'phone', 'city']);
const ready =
    BackendProfileStatus(id: 11, profileReady: true, missingFields: []);

class ProfileApi extends ContactLinksFakeApi {
  ProfileApi() {
    onProfileStatus = () async => status;
  }
  BackendProfileStatus status = missing;
  Future<void> Function()? onSync;
  @override
  Future<Map<String, dynamic>> syncMyProfile(
      {required String name,
      required String city,
      required String phone}) async {
    profileSyncs++;
    await onSync?.call();
    status = ready;
    return {'id': 11};
  }
}

Future<void> authenticate(AppState app, String operation) async {
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
}

void main() {
  for (final operation in ['restore', 'login', 'signup']) {
    test('$operation checks readiness without automatically creating profiles',
        () async {
      final api = ProfileApi();
      final app =
          AppState(apiService: api, authService: ContactLinksFakeAuth());
      addTearDown(app.dispose);
      await authenticate(app, operation);
      expect(api.profileStatusReads, 1);
      expect(api.profileSyncs, 0);
      expect(app.backendProfile!.id, isNull);
      expect(app.backendProfile!.profileReady, isFalse);
      expect(app.userProfile.uid, 'alice');
    });
  }
  test('existing backend profile is read only across login and restoration',
      () async {
    final api = ProfileApi()..status = ready;
    final app = AppState(apiService: api, authService: ContactLinksFakeAuth());
    addTearDown(app.dispose);
    await authenticate(app, 'login');
    await authenticate(app, 'restore');
    expect(app.backendProfile!.id, 11);
    expect(api.profileSyncs, 0);
  });
  test(
      'explicit Personal Details completion synchronizes and confirms readiness',
      () async {
    final api = ProfileApi();
    final app = AppState(apiService: api, authService: ContactLinksFakeAuth());
    addTearDown(app.dispose);
    await authenticate(app, 'signup');
    expect(
        await app.updateProfile(
            name: ' New Name ', phone: ' 000 ', city: ' City '),
        isNull);
    expect(api.profileSyncs, 1);
    expect(api.profileStatusReads, 2);
    expect(app.backendProfile!.id, 11);
    expect(app.backendProfile!.profileReady, isTrue);
    expect(app.userProfile.city, 'City');
  });
  test('missing city fails before Firestore or backend writes', () async {
    int writes = 0;
    final auth = ContactLinksFakeAuth()
      ..onUpdate = (profile) async {
        writes++;
        return profile;
      };
    final api = ProfileApi();
    final app = AppState(apiService: api, authService: auth)
      ..userProfile = testProfile('alice');
    addTearDown(app.dispose);
    expect(await app.updateProfile(name: 'Name', phone: '000', city: ' '),
        contains('city'));
    expect(writes, 0);
    expect(api.profileSyncs, 0);
  });
  test('readiness failure is safe, retryable and does not repeat registration',
      () async {
    final api = ProfileApi()
      ..onProfileStatus =
          () async => throw const ApiFailure(ApiFailureKind.network);
    final app = AppState(apiService: api, authService: ContactLinksFakeAuth());
    addTearDown(app.dispose);
    await authenticate(app, 'signup');
    expect(app.backendProfileError!.kind, ApiFailureKind.network);
    expect(app.checkingBackendProfile, isFalse);
    api.onProfileStatus = () async => ready;
    expect(await app.checkBackendProfile(), isTrue);
    expect(app.backendProfileError, isNull);
    expect(api.profileSyncs, 0);
  });
  test('failed sync preserves authenticated session and allows retry',
      () async {
    final api = ProfileApi()
      ..onSync = () async => throw const ApiFailure(ApiFailureKind.timeout);
    final app = AppState(apiService: api, authService: ContactLinksFakeAuth());
    addTearDown(app.dispose);
    await authenticate(app, 'login');
    expect(await app.updateProfile(name: 'Name', phone: '000', city: 'City'),
        contains('syncing'));
    expect(app.backendProfile!.profileReady, isFalse);
    expect(app.userProfile.uid, 'alice');
    expect(app.savingProfile, isFalse);
    api.onSync = null;
    expect(await app.updateProfile(name: 'Name', phone: '000', city: 'City'),
        isNull);
    expect(app.backendProfile!.profileReady, isTrue);
  });
  test('duplicate profile submissions are prevented', () async {
    final gate = Completer<void>();
    final api = ProfileApi()..onSync = () => gate.future;
    final app = AppState(apiService: api, authService: ContactLinksFakeAuth())
      ..userProfile = testProfile('alice');
    addTearDown(app.dispose);
    final first = app.updateProfile(name: 'Name', phone: '000', city: 'City');
    expect(await app.updateProfile(name: 'Other', phone: '000', city: 'Other'),
        contains('already being saved'));
    gate.complete();
    expect(await first, isNull);
    expect(api.profileSyncs, 1);
  });
  for (final operation in ['logout', 'switch', 'dispose']) {
    test('late readiness response is discarded after $operation', () async {
      final gate = Completer<BackendProfileStatus>();
      final api = ProfileApi()..onProfileStatus = () => gate.future;
      final app = AppState(apiService: api, authService: ContactLinksFakeAuth())
        ..userProfile = testProfile('alice');
      final pending = app.checkBackendProfile();
      expect(app.checkingBackendProfile, isTrue);
      if (operation == 'logout') {
        await app.logOut();
      } else if (operation == 'switch') {
        app.userProfile = testProfile('bob');
      } else {
        app.dispose();
      }
      gate.complete(ready);
      expect(await pending, isFalse);
      expect(app.backendProfile, isNull);
      if (operation != 'dispose') app.dispose();
    });
  }
  test('newest readiness request wins', () async {
    final gate = Completer<BackendProfileStatus>();
    final api = ProfileApi()..onProfileStatus = () => gate.future;
    final app = AppState(apiService: api, authService: ContactLinksFakeAuth())
      ..userProfile = testProfile('alice');
    addTearDown(app.dispose);
    final old = app.checkBackendProfile();
    api.onProfileStatus = () async => missing;
    expect(await app.checkBackendProfile(), isFalse);
    gate.complete(ready);
    expect(await old, isFalse);
    expect(app.backendProfile!.id, isNull);
  });
  test(
      'readiness parser and authenticated request preserve safe minimal contract',
      () async {
    final api = ApiService(
        tokenProvider: () async => 'synthetic',
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/users/me');
          expect(request.headers['Authorization'], 'Bearer synthetic');
          return http.Response(
              jsonEncode({
                'id': null,
                'profile_ready': false,
                'missing_fields': ['city'],
                'private': 'discard'
              }),
              200);
        }));
    final status = await api.fetchMyProfileStatus();
    expect(status.profileReady, isFalse);
    expect(status.missingFields, ['city']);
    expect(
        () => BackendProfileStatus.fromJson(
            {'id': null, 'profile_ready': true, 'missing_fields': []}),
        throwsFormatException);
    expect(
        () => BackendProfileStatus.fromJson({
              'id': 1,
              'profile_ready': true,
              'missing_fields': ['city']
            }),
        throwsFormatException);
    expect(
        () => BackendProfileStatus.fromJson({
              'id': -1,
              'profile_ready': false,
              'missing_fields': ['city']
            }),
        throwsFormatException);
  });
}
