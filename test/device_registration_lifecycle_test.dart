import 'dart:async';
import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:safecircle/services/api_failure.dart';
import 'package:safecircle/services/api_service.dart';
import 'package:safecircle/services/notification_service.dart';

class TestMessaging extends Fake implements FirebaseMessaging {
  String token = 'synthetic-fcm-one';
  AuthorizationStatus permission = AuthorizationStatus.authorized;
  Future<String?> Function()? onToken;
  Future<NotificationSettings> Function()? onPermission;
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
  Service(TestMessaging messaging, ApiService api, String? Function() user)
      : super(messaging: messaging, apiService: api, currentUserId: user);
  @override
  Future<void> initializeLocalNotifications() async {}
}

class Harness {
  String? owner = 'alice';
  final messaging = TestMessaging();
  final requests = <http.Request>[];
  Future<http.Response> Function(http.Request)? respond;
  Future<String?> Function()? auth;
  late final ApiService api;
  late final Service service;
  Harness({Duration timeout = const Duration(seconds: 1)}) {
    api = ApiService(
        requestTimeout: timeout,
        tokenProvider: () =>
            auth != null ? auth!() : Future.value('synthetic-auth-$owner'),
        client: MockClient((request) async {
          requests.add(request);
          return respond != null
              ? await respond!(request)
              : http.Response(
                  request.method == 'POST'
                      ? '{"id":7,"user_id":1}'
                      : '{"success":true}',
                  200);
        }));
    service = Service(messaging, api, () => owner)..bindUser(owner);
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
  test(
      'old account epoch cannot enroll after switching away and back to same UID',
      () async {
    final h = Harness();
    addTearDown(h.close);
    final token = Completer<String?>();
    h.messaging.onToken = () => token.future;
    final old = h.service.registerDevice();
    await tick();
    h.owner = 'bob';
    h.service.bindUser('bob');
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
    h.respond = (r) async => r.method == 'POST'
        ? await post.future
        : http.Response('{"success":true}', 200);
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
        : http.Response(
            r.method == 'POST' ? '{"id":8,"user_id":2}' : '{"success":true}',
            200);
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
    await old;
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
    h.respond = (r) async => r.method == 'POST'
        ? await post.future
        : http.Response('{"success":true}', 200);
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
    h.respond = (r) async => http.Response(
        fail ? 'private ignored body' : '{"success":true}', fail ? 503 : 200);
    await expectLater(h.service.detachDevice(), throwsA(isA<ApiFailure>()));
    expect(h.messaging.deleted, 0);
    fail = false;
    await h.service.detachDevice();
    expect(h.messaging.deleted, 1);
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
  test('a Firebase-only account can still sign out without a backend profile',
      () async {
    final h = Harness();
    addTearDown(h.close);
    h.respond = (r) async => http.Response('{}', 403);
    await expectLater(h.service.registerDevice(), throwsA(isA<ApiFailure>()));
    await h.service.detachDevice();
    expect(h.messaging.deleted, 1);
  });
}
