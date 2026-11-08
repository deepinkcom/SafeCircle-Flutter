import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:safecircle/models/app_notification.dart';
import 'package:safecircle/services/api_failure.dart';
import 'package:safecircle/services/api_service.dart';

import 'support/notifications_fakes.dart';

Map<String, dynamic> pageJson(List<Map<String, dynamic>> rows) => {
      'items': rows,
      'total': rows.length,
      'limit': 20,
      'offset': 0,
      'has_more': false
    };
http.Response reply(Object? value, {int status = 200}) =>
    http.Response(jsonEncode(value), status);

void main() {
  test('management API uses authenticated requests, filter and explicit scopes',
      () async {
    final requests = <http.Request>[];
    final api = ApiService(
        client: MockClient((request) async {
          requests.add(request);
          return reply({'affected': 1});
        }),
        tokenProvider: () async => 'synthetic-token');
    await api.manageNotifications('read-all',
        category: NotificationCategory.connection);
    await api.manageNotifications('clear-read');
    await api.manageNotifications('delete', id: 7);
    expect(requests.map((r) => r.method), ['POST', 'DELETE', 'DELETE']);
    expect(requests[0].url.path, '/notifications/mark-all-read');
    expect(requests[0].url.queryParameters, {'category': 'connection'});
    expect(requests[1].url.queryParameters, {'scope': 'read'});
    expect(requests[2].url.path, '/notifications/7');
    expect(
        requests.every(
            (r) => r.headers['Authorization'] == 'Bearer synthetic-token'),
        isTrue);
  });

  test(
      'notification model round trips only approved fields and UTC/read status',
      () {
    final model = AppNotification.fromJson(
        {...notificationJson(1), 'private': 'not retained'});
    expect(model.category, NotificationCategory.connection);
    expect(model.isUnread, isTrue);
    expect(model.createdAt.isUtc, isTrue);
    expect(model.toJson().containsKey('private'), isFalse);
    final read = AppNotification.fromJson(notificationJson(1, read: true));
    expect(read.readAt!.isUtc, isTrue);
    expect(read.isUnread, isFalse);
    expect(AppNotification.fromJson(read.toJson()).toJson(), read.toJson());
  });
  test(
      'unknown categories are safe, not interpreted as emergency or connection',
      () {
    expect(testNotification(1, category: 'future').category,
        NotificationCategory.unknown);
    expect(
        testNotification(1, category: 'future').toJson()['category'], 'future');
  });
  for (final (field, value) in [
    ('id', '1'),
    ('recipient_user_id', 0),
    ('source_id', -1),
    ('title', ''),
    ('message', null),
    ('category', ''),
    ('event_type', 7),
    ('created_at', '2026-02-30T00:00:00Z'),
    ('created_at', '2026-01-01'),
    ('read_at', 'invalid')
  ]) {
    test('rejects malformed notification $field=$value', () {
      expect(
          () =>
              AppNotification.fromJson({...notificationJson(1), field: value}),
          throwsFormatException);
    });
  }
  test('page parsing enforces bounds and immutable, nonduplicated items', () {
    final page = NotificationPage.fromJson(pageJson([notificationJson(1)]));
    expect(() => page.items.clear(), throwsUnsupportedError);
    for (final json in [
      pageJson([notificationJson(1), notificationJson(1)]),
      {...pageJson([]), 'has_more': true},
      {...pageJson([]), 'limit': 101},
      {...pageJson([]), 'total': -1},
      {
        ...pageJson([]),
        'items': [null]
      }
    ]) {
      expect(() => NotificationPage.fromJson(json), throwsFormatException);
    }
  });

  ApiService service(Future<http.Response> Function(http.Request) handler,
      {Duration timeout = const Duration(seconds: 1),
      Future<String?> Function()? token}) {
    final client = MockClient(handler);
    addTearDown(client.close);
    return ApiService(
        baseUrl: 'https://api.example.invalid',
        client: client,
        tokenProvider: token ?? () async => 'synthetic-token',
        requestTimeout: timeout);
  }

  test(
      'real service uses bearer auth, backend filters/pagination, and strict read body',
      () async {
    final requests = <http.Request>[];
    final api = service((request) async {
      requests.add(request);
      expect(request.headers['Authorization'], 'Bearer synthetic-token');
      if (request.method == 'PATCH') {
        expect(request.headers['Content-Type'], 'application/json');
        expect(jsonDecode(request.body), {'read': false});
        return reply(notificationJson(1));
      }
      if (request.url.path.endsWith('unread-count')) {
        return reply({'unread_count': 37});
      }
      expect(request.url.queryParameters,
          {'category': 'emergency', 'limit': '5', 'offset': '10'});
      return reply({
        ...pageJson([notificationJson(1, category: 'emergency')]),
        'offset': 10,
        'limit': 5,
        'total': 11
      });
    });
    final page = await api.fetchNotifications(
        category: NotificationCategory.emergency, limit: 5, offset: 10);
    expect(page.offset, 10);
    expect(await api.fetchNotificationUnreadCount(), 37);
    expect(
        (await api.updateNotificationRead(notificationId: 1, read: false))
            .isUnread,
        isTrue);
    expect(requests.map((r) => (r.method, r.url.path)), [
      ('GET', '/notifications'),
      ('GET', '/notifications/unread-count'),
      ('PATCH', '/notifications/1')
    ]);
  });
  test('missing token never dispatches HTTP', () async {
    final api = service((_) async => throw StateError('must not send'),
        token: () async => null);
    await expectLater(
        api.fetchNotifications(),
        throwsA(isA<ApiFailure>()
            .having((e) => e.kind, 'kind', ApiFailureKind.authentication)));
  });
  test('invalid query bounds never dispatch HTTP', () {
    final api = service((_) async => throw StateError('must not send'));
    expect(
        () => api.fetchNotifications(limit: 101), throwsA(isA<ApiFailure>()));
    expect(
        () => api.fetchNotifications(offset: -1), throwsA(isA<ApiFailure>()));
    expect(() => api.fetchNotifications(category: NotificationCategory.unknown),
        throwsA(isA<ApiFailure>()));
  });
  for (final status in [401, 403, 404, 422, 500]) {
    test('HTTP $status produces safe failure without response details',
        () async {
      final api =
          service((_) async => http.Response('synthetic-private-body', status));
      try {
        await api.fetchNotifications();
        fail('Expected failure');
      } on ApiFailure catch (e) {
        expect(e.statusCode, status);
        expect(e.toString(), isNot(contains('synthetic-private')));
        expect(e.toString(), isNot(contains('synthetic-token')));
      }
    });
  }
  test('malformed page, wrong page/category and invalid count are rejected',
      () async {
    for (final payload in [
      null,
      {},
      {...pageJson([]), 'offset': 1},
      pageJson([notificationJson(1, category: 'emergency')])
    ]) {
      final api = service((_) async => reply(payload));
      await expectLater(
          api.fetchNotifications(category: NotificationCategory.connection),
          throwsA(isA<ApiFailure>()
              .having((e) => e.kind, 'kind', ApiFailureKind.invalidResponse)));
    }
    final api = service((_) async => reply({'unread_count': -1}));
    await expectLater(
        api.fetchNotificationUnreadCount(), throwsA(isA<ApiFailure>()));
  });
  test('PATCH validates identity and server-confirmed read state', () async {
    for (final payload in [
      notificationJson(2, read: true),
      notificationJson(1)
    ]) {
      final api = service((_) async => reply(payload));
      await expectLater(
          api.updateNotificationRead(notificationId: 1, read: true),
          throwsA(isA<ApiFailure>()));
    }
  });
  test('network failures and timeout are safe', () async {
    final api =
        service((_) async => throw const SocketException('synthetic-private'));
    await expectLater(
        api.fetchNotifications(),
        throwsA(isA<ApiFailure>()
            .having((e) => e.kind, 'kind', ApiFailureKind.network)));
    final pending = Completer<http.Response>();
    final slow = service((_) => pending.future,
        timeout: const Duration(milliseconds: 5));
    await expectLater(
        slow.fetchNotifications(),
        throwsA(isA<ApiFailure>()
            .having((e) => e.kind, 'kind', ApiFailureKind.timeout)));
    pending.complete(reply(pageJson([])));
  });
}
