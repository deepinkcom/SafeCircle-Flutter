import 'dart:async';
import 'dart:convert';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:safecircle/services/api_failure.dart';
import 'package:safecircle/services/api_service.dart';
import 'package:safecircle/services/notification_service.dart';
import 'package:safecircle/services/installation_identity.dart';

class MemoryInstallationStorage implements InstallationIdStorage {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async => this.value = value;
}

http.Response successFor(http.Request request) => request.url.path ==
        '/devices/installation'
    ? http.Response(
        '{"success":true,"revoked_count":0,"installation_registrations_remain":false,"unattributed_legacy_registrations_remain":false}',
        200)
    : http.Response(
        request.method == 'POST' ? '{"id":7,"user_id":1}' : '{"success":true}',
        200);

class TestMessaging extends Fake implements FirebaseMessaging {
  String token = 'synthetic-fcm-one';
  AuthorizationStatus permission = AuthorizationStatus.authorized;
  Future<String?> Function()? onToken;
  Future<NotificationSettings> Function()? onPermission;
  Future<void> Function()? onDelete;
  int deleted = 0, reads = 0;
  final refreshed = StreamController<String>.broadcast(sync: true);
  @override
  Stream<String> get onTokenRefresh => refreshed.stream;
  @override
  Future<String?> getToken(
      {String? vapidKey, String? serviceWorkerScriptPath}) async {
    reads++;
    return onToken != null ? await onToken!() : token;
  }

  @override
  Future<void> deleteToken() async {
    deleted++;
    await onDelete?.call();
  }

  @override
  Future<NotificationSettings> getNotificationSettings() async =>
      onPermission != null
          ? await onPermission!()
          : NotificationSettings(
              authorizationStatus: permission,
              alert: AppleNotificationSetting.enabled,
              announcement: AppleNotificationSetting.disabled,
              badge: AppleNotificationSetting.enabled,
              carPlay: AppleNotificationSetting.disabled,
              criticalAlert: AppleNotificationSetting.disabled,
              lockScreen: AppleNotificationSetting.enabled,
              notificationCenter: AppleNotificationSetting.enabled,
              showPreviews: AppleShowPreviewSetting.always,
              sound: AppleNotificationSetting.enabled,
              timeSensitive: AppleNotificationSetting.disabled,
              providesAppNotificationSettings:
                  AppleNotificationSetting.disabled);
}

class Service extends NotificationService {
  Service(TestMessaging messaging, ApiService api, String? Function() user,
      void Function(Map<String, Object?> event)? diagnostics,
      {required InstallationIdentity installationIdentity})
      : super(
            messaging: messaging,
            apiService: api,
            installationIdentity: installationIdentity,
            currentUserId: user,
            diagnostics: diagnostics);
  @override
  Future<void> initializeLocalNotifications() async {}
}

class Harness {
  String? owner = 'alice';
  final messaging = TestMessaging();
  final requests = <http.Request>[];
  final diagnostics = <Map<String, Object?>>[];
  final installationStorage = MemoryInstallationStorage();
  Future<http.Response> Function(http.Request)? respond;
  Future<String?> Function()? auth;
  Future<String?> Function()? forceAuth;
  late final ApiService api;
  late final Service service;
  Harness({Duration timeout = const Duration(seconds: 1)}) {
    api = ApiService(
        requestTimeout: timeout,
        tokenProvider: () =>
            auth != null ? auth!() : Future.value('synthetic-auth-$owner'),
        forceRefreshTokenProvider: () => forceAuth != null
            ? forceAuth!()
            : Future.value('synthetic-auth-$owner'),
        client: MockClient((request) async {
          requests.add(request);
          return respond != null
              ? await respond!(request)
              : request.url.path == '/devices/installation'
                  ? http.Response(
                      '{"success":true,"revoked_count":0,"installation_registrations_remain":false,"unattributed_legacy_registrations_remain":false}',
                      200)
                  : http.Response(
                      request.method == 'POST'
                          ? '{"id":7,"user_id":1}'
                          : '{"success":true}',
                      200);
        }));
    service = Service(messaging, api, () => owner, diagnostics.add,
        installationIdentity:
            InstallationIdentity(storage: installationStorage))
      ..bindUser(owner);
  }
  Future<void> close() async {
    await service.dispose();
    await messaging.refreshed.close();
  }

  List<http.Request> get posts =>
      requests.where((r) => r.method == 'POST').toList();
  List<http.Request> get deletes =>
      requests.where((r) => r.method == 'DELETE').toList();
}

Future<void> tick() async {
  await Future<void>.delayed(Duration.zero);
}

void main() {
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('old backend cannot silently bypass installation cleanup', () async {
    final h = Harness();
    addTearDown(h.close);
    h.respond = (_) async => http.Response('{"detail":"Not Found"}', 404);
    await expectLater(
        h.service.detachDevice(),
        throwsA(isA<DeviceCleanupUnverified>()
            .having((e) => e.message, 'message', contains('server update'))));
    expect(h.messaging.deleted, 0);
    expect(
        h.diagnostics.any((e) =>
            e['stage'] == 'installation_cleanup_failed' &&
            e['api_http_status'] == 404),
        isTrue);
  });

  test(
      'account changing during cleanup refresh still uses captured old-owner bearer',
      () async {
    final h = Harness();
    addTearDown(h.close);
    await h.service.registerDevice();
    final auth = Completer<String?>();
    h.auth = () => auth.future;
    final logout = h.service.detachDevice();
    await tick();
    h.owner = 'bob';
    h.service.bindUser('bob');
    auth.complete('synthetic-auth-bob');
    await logout;
    expect(h.deletes.single.headers['Authorization'],
        'Bearer synthetic-auth-alice');
    expect(h.messaging.deleted, 0);
    h.auth = null;
    await h.service.registerDevice();
    expect(h.posts.last.headers['Authorization'], 'Bearer synthetic-auth-bob');
  });
  test('expired cleanup bearer is force-refreshed once after 401', () async {
    final h = Harness();
    addTearDown(h.close);
    await h.service.registerDevice();
    h.auth = () async => 'synthetic-expired-alice-bearer';
    h.forceAuth = () async => 'synthetic-refreshed-alice-bearer';
    h.respond = (request) async {
      if (request.method == 'DELETE' &&
          request.headers['Authorization'] ==
              'Bearer synthetic-expired-alice-bearer') {
        return http.Response('private auth detail', 401);
      }
      return successFor(request);
    };

    await h.service.detachDevice();

    expect(h.deletes, hasLength(2));
    expect(h.deletes.first.headers['Authorization'],
        'Bearer synthetic-expired-alice-bearer');
    expect(h.deletes.last.headers['Authorization'],
        'Bearer synthetic-refreshed-alice-bearer');
    expect(h.messaging.deleted, 1);
  });
  test('missing current token is safe when installation cleanup is confirmed',
      () async {
    final h = Harness();
    addTearDown(h.close);
    h.messaging.token = '';

    await h.service.detachDevice();

    expect(h.requests.map((request) => request.url.path),
        ['/devices/installation']);
    expect(h.messaging.deleted, 1);
    expect(
        h.diagnostics.any((event) =>
            event['stage'] == 'installation_cleanup_response' &&
            event['installation_registrations_remain'] == false &&
            event['backend_cleanup_confirmed'] == true),
        isTrue);
    expect(jsonEncode(h.diagnostics), isNot(contains('synthetic-fcm-one')));
  });
  test('registration and logout use the same persistent installation id',
      () async {
    final h = Harness();
    addTearDown(h.close);
    await h.service.registerDevice();
    final registration =
        jsonDecode(h.posts.single.body) as Map<String, dynamic>;
    final installId = registration['installation_id'] as String;
    expect(installId, matches(RegExp(r'^[0-9a-f]{64}$')));
    await h.service.detachDevice();
    final cleanup = h.deletes
        .singleWhere((request) => request.url.path == '/devices/installation');
    expect(
        (jsonDecode(cleanup.body) as Map<String, dynamic>)['installation_id'],
        installId);
  });
  test('FCM token lookup failure blocks cleanup when legacy rows remain',
      () async {
    final h = Harness();
    addTearDown(h.close);
    h.respond = (request) async => request.url.path == '/devices/installation'
        ? http.Response(
            '{"success":true,"revoked_count":0,"installation_registrations_remain":false,"unattributed_legacy_registrations_remain":true}',
            200)
        : successFor(request);
    h.messaging.onToken = () async =>
        throw FirebaseException(plugin: 'firebase_messaging', code: 'unknown');

    await expectLater(
        h.service.detachDevice(), throwsA(isA<DeviceCleanupUnverified>()));

    final failure = h.diagnostics
        .singleWhere((event) => event['stage'] == 'legacy_token_lookup_failed');
    expect(failure['firebase_exception_code'], 'unknown');
    expect(h.requests.map((request) => request.url.path),
        ['/devices/installation']);
    expect(jsonEncode(h.diagnostics), isNot(contains('synthetic-fcm-one')));
  });
  test('missing token does not sign out when backend reports a registration',
      () async {
    final h = Harness();
    addTearDown(h.close);
    h.messaging.token = '';
    h.respond = (request) async => request.url.path == '/devices/installation'
        ? http.Response(
            '{"success":true,"revoked_count":0,"installation_registrations_remain":false,"unattributed_legacy_registrations_remain":true}',
            200)
        : successFor(request);

    await expectLater(
        h.service.detachDevice(), throwsA(isA<DeviceCleanupUnverified>()));

    expect(h.messaging.deleted, 0);
    expect(h.diagnostics.any((event) => event['stage'] == 'cleanup_unverified'),
        isTrue);
  });
  test(
      'other-phone legacy registrations do not block cleanup with current token',
      () async {
    final h = Harness();
    addTearDown(h.close);
    h.respond = (request) async => request.url.path == '/devices/installation'
        ? http.Response(
            '{"success":true,"revoked_count":0,"installation_registrations_remain":false,"unattributed_legacy_registrations_remain":true}',
            200)
        : successFor(request);
    await h.service.detachDevice();
    expect(h.deletes, hasLength(2));
    expect(h.messaging.deleted, 1);
    expect(
        h.diagnostics.any((event) =>
            event['stage'] == 'unattributed_legacy_registrations_preserved' &&
            event['current_token_retrieval_succeeded'] == true),
        isTrue);
  });
  test('upgraded installation revokes its known token if later lookup fails',
      () async {
    final h = Harness();
    addTearDown(h.close);
    // The new APK's registration refresh discovers and reuses the old row.
    await h.service.registerDevice();
    h.messaging.onToken = () async => throw FirebaseException(
        plugin: 'firebase_messaging', code: 'unavailable');
    final readsBeforeLogout = h.messaging.reads;

    await h.service.detachDevice();

    expect(h.messaging.reads, readsBeforeLogout);
    expect(h.deletes, hasLength(1));
    expect(
        h.requests
            .any((request) => request.url.path == '/devices/cleanup-status'),
        isFalse);
    expect(
        h.diagnostics.any((event) =>
            event['stage'] == 'installation_cleanup_response' &&
            event['backend_cleanup_confirmed'] == true),
        isTrue);
  });
  test('Android notification permission does not block token cleanup',
      () async {
    final h = Harness();
    addTearDown(h.close);
    h.messaging.permission = AuthorizationStatus.denied;

    await h.service.detachDevice();

    expect(h.deletes, hasLength(1));
    expect(h.messaging.deleted, 1);
  });
  test(
      'old account epoch cannot enroll after switching away and back to same UID',
      () async {
    final h = Harness();
    addTearDown(h.close);
    final token = Completer<String?>();
    h.messaging.onToken = () => token.future;
    final old = h.service.registerDevice();
    await tick();
    h.owner = null;
    h.service.bindUser(null);
    h.owner = 'alice';
    h.service.bindUser('alice');
    token.complete('synthetic-fcm-one');
    await old;
    expect(h.posts, isEmpty);
    h.messaging.onToken = null;
    await h.service.registerDevice();
    expect(h.posts, hasLength(1));
  });
  test(
      'foreign-owner conflict is not cached as success or retried automatically',
      () async {
    final h = Harness();
    addTearDown(h.close);
    h.respond =
        (request) async => http.Response('sensitive response ignored', 409);
    await expectLater(h.service.registerDevice(), throwsA(isA<ApiFailure>()));
    await tick();
    expect(h.posts, hasLength(1));
    expect(h.deletes, isEmpty);
    await expectLater(h.service.registerDevice(), throwsA(isA<ApiFailure>()));
    expect(h.posts, hasLength(2));
    expect(h.deletes, isEmpty);
  });

  test(
      'overlapping callers share registration; successful same-token repeats do not POST',
      () async {
    final h = Harness();
    addTearDown(h.close);
    final gate = Completer<http.Response>();
    h.respond = (r) => gate.future;
    final a = h.service.registerDevice();
    final b = h.service.registerDevice();
    expect(identical(a, b), isTrue);
    await tick();
    expect(h.posts, hasLength(1));
    gate.complete(http.Response('{"id":7,"user_id":1}', 200));
    await Future.wait([a, b]);
    await h.service.registerDevice();
    expect(h.posts, hasLength(1));
  });
  test(
      'token refresh overlapping startup deduplicates and serializes a genuinely new token',
      () async {
    final h = Harness();
    addTearDown(h.close);
    await h.service.startForegroundListener();
    final token = Completer<String?>();
    h.messaging.onToken = () => token.future;
    final first = h.service.registerDevice();
    await tick();
    h.messaging.refreshed.add('synthetic-fcm-one');
    token.complete('synthetic-fcm-one');
    await first;
    expect(h.posts, hasLength(1));
    h.messaging.refreshed.add('synthetic-fcm-two');
    await tick();
    await tick();
    expect(h.posts, hasLength(2));
    expect(jsonDecode(h.posts.last.body)['fcm_token'], 'synthetic-fcm-two');
  });
  test(
      'logout drains actual in-flight POST then cleans with old owner before rotating FCM token',
      () async {
    final h = Harness();
    addTearDown(h.close);
    final post = Completer<http.Response>();
    h.respond =
        (r) async => r.method == 'POST' ? await post.future : successFor(r);
    final registration = h.service.registerDevice();
    await tick();
    final logout = h.service.detachDevice();
    await tick();
    expect(h.deletes, isEmpty);
    expect(h.messaging.deleted, 0);
    post.complete(http.Response('{"id":7,"user_id":1}', 200));
    await registration;
    await logout;
    expect(h.requests.map((r) => r.method), ['POST', 'DELETE']);
    expect(h.deletes.single.headers['Authorization'],
        'Bearer synthetic-auth-alice');
    expect(h.messaging.deleted, 1);
  });
  test(
      'account switch cleans a late Alice POST with Alice bearer before Bob registers',
      () async {
    final h = Harness();
    addTearDown(h.close);
    final post = Completer<http.Response>();
    int posted = 0;
    h.respond = (r) async => r.method == 'POST' && posted++ == 0
        ? await post.future
        : r.method == 'POST'
            ? http.Response('{"id":8,"user_id":2}', 200)
            : successFor(r);
    final alice = h.service.registerDevice();
    await tick();
    h.owner = 'bob';
    h.service.bindUser('bob');
    final bob = h.service.registerDevice();
    await tick();
    expect(h.posts, hasLength(1));
    post.complete(http.Response('{"id":7,"user_id":1}', 200));
    await alice;
    await bob;
    expect(h.requests.map((r) => r.method), ['POST', 'DELETE', 'POST']);
    expect(h.deletes.single.headers['Authorization'],
        'Bearer synthetic-auth-alice');
    expect(h.posts.last.headers['Authorization'], 'Bearer synthetic-auth-bob');
    expect(h.messaging.deleted, 0);
  });
  test(
      'account changes during permission lookup suppress old registration entirely',
      () async {
    final h = Harness();
    addTearDown(h.close);
    final permission = Completer<NotificationSettings>();
    final allowed = await h.messaging.getNotificationSettings();
    h.messaging.onPermission = () => permission.future;
    final old = h.service.registerDevice();
    await tick();
    h.owner = 'bob';
    h.service.bindUser('bob');
    permission.complete(allowed);
    await expectLater(old, throwsA(isA<ApiFailure>()));
    expect(h.posts, isEmpty);
  });
  test(
      'account changes during auth lookup never borrow Bob credentials for Alice data',
      () async {
    final h = Harness();
    addTearDown(h.close);
    final auth = Completer<String?>();
    h.auth = () => auth.future;
    final old = h.service.registerDevice();
    await tick();
    h.owner = 'bob';
    h.service.bindUser('bob');
    auth.complete('synthetic-auth-bob');
    await expectLater(old, throwsA(isA<ApiFailure>()));
    expect(h.posts, isEmpty);
  });
  test('failed registration can be retried without caching success', () async {
    final h = Harness();
    addTearDown(h.close);
    bool fail = true;
    h.respond = (r) async => http.Response(
        fail ? 'private ignored body' : '{"id":7,"user_id":1}',
        fail ? 503 : 200);
    await expectLater(h.service.registerDevice(), throwsA(isA<ApiFailure>()));
    fail = false;
    await h.service.registerDevice();
    expect(h.posts, hasLength(2));
  });
  test('timeout does not release teardown barrier or start a duplicate POST',
      () async {
    final h = Harness(timeout: const Duration(milliseconds: 40));
    addTearDown(h.close);
    final post = Completer<http.Response>();
    h.respond =
        (r) async => r.method == 'POST' ? await post.future : successFor(r);
    final pending = h.service.registerDevice();
    await expectLater(pending, throwsA(isA<ApiFailure>()));
    final logout = h.service.detachDevice();
    await tick();
    expect(h.deletes, isEmpty);
    expect(h.posts, hasLength(1));
    post.complete(http.Response('{"id":7,"user_id":1}', 200));
    await logout;
    expect(h.deletes, hasLength(1));
    expect(h.messaging.deleted, 1);
  });
  test('cleanup failure is explicit and retryable; never marks logout complete',
      () async {
    final h = Harness();
    addTearDown(h.close);
    await h.service.registerDevice();
    bool fail = true;
    h.respond = (r) async =>
        fail ? http.Response('private ignored body', 503) : successFor(r);
    await expectLater(h.service.detachDevice(), throwsA(isA<ApiFailure>()));
    expect(h.messaging.deleted, 0);
    fail = false;
    await h.service.detachDevice();
    expect(h.messaging.deleted, 1);
  });
  test('FCM token rotation failure does not undo confirmed backend cleanup',
      () async {
    final h = Harness();
    addTearDown(h.close);
    await h.service.registerDevice();
    h.messaging.onDelete = () async => throw FirebaseException(
        plugin: 'firebase_messaging', code: 'unavailable');

    await h.service.detachDevice();

    expect(h.deletes, hasLength(1));
    expect(h.messaging.deleted, 1);
    final failure = h.diagnostics.singleWhere(
        (event) => event['stage'] == 'firebase_token_delete_failed');
    expect(failure['firebase_exception_code'], 'unavailable');
    expect(jsonEncode(h.diagnostics), isNot(contains('synthetic-fcm-one')));
  });
  test('permission denial creates no enrollment and can recover', () async {
    final h = Harness();
    addTearDown(h.close);
    h.messaging.permission = AuthorizationStatus.denied;
    await expectLater(h.service.registerDevice(), throwsA(isA<ApiFailure>()));
    expect(h.posts, isEmpty);
    h.messaging.permission = AuthorizationStatus.authorized;
    await h.service.registerDevice();
    expect(h.posts, hasLength(1));
  });
  test('dispose preserves confirmed enrollment for background delivery',
      () async {
    final h = Harness();
    await h.service.registerDevice();
    await h.close();
    expect(h.deletes, isEmpty);
    expect(h.messaging.deleted, 0);
  });
  test(
      'an account without a backend profile cannot bypass cleanup authorization',
      () async {
    final h = Harness();
    addTearDown(h.close);
    h.respond = (r) async => http.Response('{}', 403);
    await expectLater(h.service.registerDevice(), throwsA(isA<ApiFailure>()));
    await expectLater(h.service.detachDevice(), throwsA(isA<ApiFailure>()));
    expect(h.messaging.deleted, 0);
  });
}
