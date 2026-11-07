import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:safecircle/models/contact_link.dart';
import 'package:safecircle/models/registered_user.dart';
import 'package:safecircle/services/api_failure.dart';
import 'package:safecircle/services/api_service.dart';

const syntheticToken = 'synthetic-auth-token-not-real';
const privateMarker = 'synthetic-private-response-or-exception';

Map<String, dynamic> linkJson({String status = 'pending'}) => {
      'id': 7,
      'inviter_user_id': 1,
      'invitee_user_id': 2,
      'other_user_id': 2,
      'status': status,
      'created_at': '2026-11-07T10:00:00.000Z',
      'updated_at': '2026-11-07T10:00:00.000Z',
      'responded_at': null,
      'revoked_at': null,
      'other_user': {
        'id': 2,
        'name': 'Zoë & Li',
        'email': 'member@example.invalid'
      },
    };

http.Response reply(Object? json, {int status = 200}) => http.Response(
      jsonEncode(json),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

ApiService service(
  Future<http.Response> Function(http.Request) handler, {
  Future<String?> Function()? tokenProvider,
  Duration timeout = const Duration(seconds: 20),
}) {
  final client = MockClient(handler);
  addTearDown(client.close);
  return ApiService(
    baseUrl: 'https://api.example.invalid',
    client: client,
    tokenProvider: tokenProvider ?? () async => syntheticToken,
    requestTimeout: timeout,
  );
}

Future<ApiFailure> failureFrom(Future<dynamic> Function() action) async {
  try {
    await action();
  } catch (error) {
    expect(error, isA<ApiFailure>());
    final failure = error as ApiFailure;
    for (final value in [
      syntheticToken,
      privateMarker,
      'api.example.invalid'
    ]) {
      expect(failure.toString(), isNot(contains(value)));
      expect(failure.message, isNot(contains(value)));
    }
    return failure;
  }
  fail('Expected a safe API failure.');
}

typedef ApiCall = Future<dynamic> Function(ApiService api);

final newCalls = <String, ApiCall>{
  'search': (api) => api.searchRegisteredUsers(email: 'member@example.invalid'),
  'send': (api) => api.sendContactInvitation(email: 'member@example.invalid'),
  'incoming': (api) => api.fetchIncomingInvitations(),
  'outgoing': (api) => api.fetchOutgoingInvitations(),
  'relationships': (api) => api.fetchContactRelationships(),
  'accept': (api) => api.respondToContactInvitation(
      linkId: 7, action: ContactInvitationAction.accept),
  'reject': (api) => api.respondToContactInvitation(
      linkId: 7, action: ContactInvitationAction.reject),
  'revoke': (api) => api.revokeContactRelationship(linkId: 7),
};

void main() {
  const methods = {
    'search': 'GET',
    'send': 'POST',
    'incoming': 'GET',
    'outgoing': 'GET',
    'relationships': 'GET',
    'accept': 'POST',
    'reject': 'POST',
    'revoke': 'DELETE',
  };
  const paths = {
    'search': '/users/search',
    'send': '/contact-links/invites',
    'incoming': '/contact-links/invites/incoming',
    'outgoing': '/contact-links/invites/outgoing',
    'relationships': '/contact-links/relationships',
    'accept': '/contact-links/7/respond',
    'reject': '/contact-links/7/respond',
    'revoke': '/contact-links/7',
  };
  const bodies = {
    'send': {'email': 'member@example.invalid'},
    'accept': {'action': 'accept'},
    'reject': {'action': 'reject'},
  };
  for (final operation in newCalls.entries) {
    test(
        '${operation.key}: correct wire contract, bearer header and typed result',
        () async {
      var requests = 0;
      final api = service((request) async {
        requests++;
        expect(request.method, methods[operation.key]);
        expect(request.url.path, paths[operation.key]);
        expect(request.headers['Authorization'], 'Bearer $syntheticToken');
        expect(request.followRedirects, isFalse);
        if (bodies.containsKey(operation.key)) {
          expect(request.headers['content-type'], contains('application/json'));
          expect(jsonDecode(request.body), bodies[operation.key]);
        } else {
          expect(request.body, isEmpty);
        }
        if (operation.key == 'search') {
          expect(request.url.queryParameters, {'q': 'member@example.invalid'});
          return reply([
            {'name': 'Zoë & Li', 'email': 'member@example.invalid'}
          ]);
        }
        final status = switch (operation.key) {
          'accept' || 'relationships' => 'accepted',
          'reject' => 'rejected',
          'revoke' => 'revoked',
          _ => 'pending',
        };
        if (['incoming', 'outgoing', 'relationships'].contains(operation.key)) {
          return reply([linkJson(status: status)]);
        }
        return reply(linkJson(status: status),
            status: operation.key == 'send' ? 201 : 200);
      });
      final result = await operation.value(api);
      if (operation.key == 'search') {
        expect(result, isA<List<RegisteredUser>>());
        expect((result as List<RegisteredUser>).single.name, 'Zoë & Li');
      } else if (result is List<ContactLink>) {
        expect(result.single.id, 7);
        expect(result.single.otherUser!.name, 'Zoë & Li');
      } else {
        expect(result, isA<ContactLink>());
        expect((result as ContactLink).id, 7);
      }
      expect(requests, 1);
    });

    test('${operation.key}: safe HTTP failure with no sensitive details',
        () async {
      final api = service(
          (_) async => http.Response('$privateMarker $syntheticToken', 503));
      final failure = await failureFrom(() => operation.value(api));
      expect(failure.kind, ApiFailureKind.server);
      expect(failure.statusCode, 503);
    });
  }

  test('query encoding preserves plus, ampersand and mixed casing', () async {
    const email = 'Member+invite&friend@example.invalid';
    final api = service((request) async {
      expect(request.url.queryParameters, {'q': email});
      expect(request.url.query, contains('%2B'));
      expect(request.url.query, contains('%26'));
      return reply([
        {'name': 'Member', 'email': email}
      ]);
    });
    expect((await api.searchRegisteredUsers(email: ' $email ')).single.email,
        email);
  });

  for (final operation in ['search', 'incoming', 'outgoing', 'relationships']) {
    test('$operation: accepts an empty list', () async {
      final api = service((_) async => reply([]));
      expect(await newCalls[operation]!(api), isEmpty);
    });
  }

  test('nullable identity and unknown statuses are preserved', () async {
    final api = service((_) async => reply([
          linkJson()..['other_user'] = null,
          linkJson(status: 'future-status')..['id'] = 8,
        ]));
    final links = await api.fetchOutgoingInvitations();
    expect(links.first.otherUser, isNull);
    expect(links.last.status, ContactLinkStatus.unknown);
    expect(links.last.isActive, isFalse);
    expect(links.last.isAccepted, isFalse);
  });

  for (final entry in <int, ApiFailureKind>{
    400: ApiFailureKind.validation,
    401: ApiFailureKind.authentication,
    403: ApiFailureKind.forbidden,
    404: ApiFailureKind.notFound,
    409: ApiFailureKind.conflict,
    422: ApiFailureKind.validation,
    429: ApiFailureKind.rateLimited,
    500: ApiFailureKind.server,
    503: ApiFailureKind.server,
    302: ApiFailureKind.requestRejected,
  }.entries) {
    test('HTTP ${entry.key} maps to a safe classified failure', () async {
      final api = service((_) async => http.Response(
            jsonEncode({'detail': '$privateMarker $syntheticToken'}),
            entry.key,
          ));
      final failure = await failureFrom(api.fetchOutgoingInvitations);
      expect(failure.kind, entry.value);
      expect(failure.statusCode, entry.key);
    });
  }

  for (final token in <String?>[null, '', ' ']) {
    test('missing or empty injected token never sends a request ($token)',
        () async {
      var requests = 0;
      final api = service((_) async {
        requests++;
        return reply([]);
      }, tokenProvider: () async => token);
      expect((await failureFrom(api.fetchOutgoingInvitations)).kind,
          ApiFailureKind.authentication);
      expect(requests, 0);
    });
  }

  test('token retrieval errors are sanitized without sending', () async {
    var requests = 0;
    final api = service((_) async {
      requests++;
      return reply([]);
    },
        tokenProvider: () async =>
            throw StateError('$privateMarker $syntheticToken'));
    expect((await failureFrom(api.fetchOutgoingInvitations)).kind,
        ApiFailureKind.authentication);
    expect(requests, 0);
  });

  for (final (index, response) in <http.Response>[
    http.Response('', 200),
    http.Response('{invalid $privateMarker', 200),
    reply(null),
    reply({}),
    reply([null]),
    reply(['not-an-object']),
    reply([
      {'id': 7, 'unexpected': privateMarker}
    ]),
    http.Response.bytes([0xff, 0xfe], 200),
  ].indexed) {
    test('malformed list response is sanitized (case $index)', () async {
      final api = service((_) async => response);
      expect((await failureFrom(api.fetchOutgoingInvitations)).kind,
          ApiFailureKind.invalidResponse);
    });
  }

  for (final data in <Object?>[
    null,
    [],
    7,
    'bad',
    {'id': 7}
  ]) {
    test('malformed mutation response is sanitized ($data)', () async {
      final api = service((_) async => reply(data));
      expect(
          (await failureFrom(() => api.revokeContactRelationship(linkId: 7)))
              .kind,
          ApiFailureKind.invalidResponse);
    });
  }

  test(
      'DELETE requires the backend relationship JSON response, not an empty 204',
      () async {
    final api = service((_) async => http.Response('', 204));
    expect(
        (await failureFrom(() => api.revokeContactRelationship(linkId: 7)))
            .kind,
        ApiFailureKind.invalidResponse);
  });

  test('wrong relationship ID and counterparty are rejected', () async {
    for (final json in [
      linkJson()..['id'] = 99,
      linkJson()..['other_user_id'] = 3
    ]) {
      final api = service((_) async => reply(json));
      expect(
          (await failureFrom(() => api.revokeContactRelationship(linkId: 7)))
              .kind,
          ApiFailureKind.invalidResponse);
    }
  });

  test('discovery rejects multiple or unrelated results', () async {
    for (final users in [
      [
        {'name': 'One', 'email': 'member@example.invalid'},
        {'name': 'Two', 'email': 'member@example.invalid'}
      ],
      [
        {'name': 'Other', 'email': 'unrelated@example.invalid'}
      ],
    ]) {
      final api = service((_) async => reply(users));
      expect(
          (await failureFrom(() =>
                  api.searchRegisteredUsers(email: 'member@example.invalid')))
              .kind,
          ApiFailureKind.invalidResponse);
    }
  });

  for (final error in <Object>[
    http.ClientException('$privateMarker $syntheticToken'),
    const SocketException(privateMarker),
    Exception(privateMarker),
  ]) {
    test('network failure ${error.runtimeType} is sanitized', () async {
      final api = service((_) async => throw error);
      expect((await failureFrom(api.fetchOutgoingInvitations)).kind,
          ApiFailureKind.network);
    });
  }

  test('unexpected internal errors are sanitized', () async {
    final api = service((_) async => throw StateError(privateMarker));
    expect((await failureFrom(api.fetchOutgoingInvitations)).kind,
        ApiFailureKind.unexpected);
  });

  test('network-reported timeout is sanitized', () async {
    final api = service((_) async => throw TimeoutException(privateMarker));
    expect((await failureFrom(api.fetchOutgoingInvitations)).kind,
        ApiFailureKind.timeout);
  });

  test('request timeout does not automatically retry a mutation', () async {
    var requests = 0;
    final response = Completer<http.Response>();
    final api = service((_) {
      requests++;
      return response.future;
    }, timeout: const Duration(milliseconds: 30));
    final failure = await failureFrom(
        () => api.sendContactInvitation(email: 'member@example.invalid'));
    expect(failure.kind, ApiFailureKind.timeout);
    expect(requests, 1);
    response.complete(reply(linkJson(), status: 201));
    await Future<void>.delayed(Duration.zero);
    expect(requests, 1);
  });

  test('late authentication cannot send a mutation after timeout', () async {
    var requests = 0;
    final token = Completer<String?>();
    final api = service((_) async {
      requests++;
      return reply(linkJson(), status: 201);
    },
        tokenProvider: () => token.future,
        timeout: const Duration(milliseconds: 30));
    expect(
        (await failureFrom(() =>
                api.sendContactInvitation(email: 'member@example.invalid')))
            .kind,
        ApiFailureKind.timeout);
    token.complete(syntheticToken);
    await Future<void>.delayed(Duration.zero);
    expect(requests, 0);
  });

  test('invalid inputs never send network requests', () async {
    var requests = 0;
    final api = service((_) async {
      requests++;
      return reply(null);
    });
    for (final email in [
      '',
      'Member',
      '%',
      'member@example',
      'a' * 256 + '@example.invalid'
    ]) {
      expect(
          (await failureFrom(() => api.searchRegisteredUsers(email: email)))
              .kind,
          ApiFailureKind.validation);
      expect(
          (await failureFrom(() => api.sendContactInvitation(email: email)))
              .kind,
          ApiFailureKind.validation);
    }
    for (final id in [0, -1]) {
      expect(
          (await failureFrom(() => api.revokeContactRelationship(linkId: id)))
              .kind,
          ApiFailureKind.validation);
      expect(
          (await failureFrom(() => api.respondToContactInvitation(
                  linkId: id, action: ContactInvitationAction.accept)))
              .kind,
          ApiFailureKind.validation);
    }
    expect(requests, 0);
  });

  test('an injected client remains reusable and is not closed by the service',
      () async {
    final client = TrackingClient(MockClient((_) async => reply([])));
    addTearDown(client.close);
    final api =
        ApiService(client: client, tokenProvider: () async => syntheticToken);
    await api.fetchIncomingInvitations();
    await api.fetchOutgoingInvitations();
    expect(client.wasClosed, isFalse);
  });

  test('nonpositive timeouts are rejected', () {
    expect(
        () => ApiService(requestTimeout: Duration.zero), throwsArgumentError);
  });

  final legacy = <String,
      ({
    String method,
    String path,
    Map<String, dynamic>? body,
    Object? response,
    ApiCall call
  })>{
    'profile': (
      method: 'POST',
      path: '/users/me',
      body: {'name': 'Name', 'city': 'City', 'phone': '000'},
      response: {'id': 1},
      call: (api) => api.syncMyProfile(name: 'Name', city: 'City', phone: '000')
    ),
    'panic': (
      method: 'POST',
      path: '/alerts/panic',
      body: {'latitude': -33.9, 'longitude': 18.4},
      response: {'id': 7},
      call: (api) => api.sendPanicAlert(latitude: -33.9, longitude: 18.4)
    ),
    'resolve': (
      method: 'POST',
      path: '/alerts/7/resolve',
      body: null,
      response: null,
      call: (api) => api.resolveAlert(7)
    ),
    'acknowledge': (
      method: 'POST',
      path: '/alerts/7/acknowledge',
      body: null,
      response: {'id': 7},
      call: (api) => api.acknowledgeAlert(7)
    ),
    'history': (
      method: 'GET',
      path: '/alerts/history',
      body: null,
      response: [
        {'id': 7}
      ],
      call: (api) => api.fetchAlertHistory()
    ),
    'nearby': (
      method: 'GET',
      path: '/alerts/nearby',
      body: null,
      response: [],
      call: (api) => api.fetchNearbyAlerts(latitude: -33.9, longitude: 18.4)
    ),
    'contacts': (
      method: 'GET',
      path: '/contacts',
      body: null,
      response: [
        {'id': 2, 'enabled': false}
      ],
      call: (api) => api.fetchContacts()
    ),
    'create contact': (
      method: 'POST',
      path: '/contacts',
      body: {
        'name': 'Name',
        'relationship': 'Friend',
        'phone': '000',
        'enabled': true
      },
      response: {'id': 2},
      call: (api) =>
          api.createContact(name: 'Name', relationship: 'Friend', phone: '000')
    ),
    'edit contact': (
      method: 'PATCH',
      path: '/contacts/2',
      body: {'name': 'Updated', 'relationship': 'Family', 'phone': '001'},
      response: {'id': 2},
      call: (api) => api.updateContact(
          contactId: 2, name: 'Updated', relationship: 'Family', phone: '001')
    ),
    'toggle contact': (
      method: 'PATCH',
      path: '/contacts/2',
      body: {'enabled': false},
      response: {'id': 2, 'enabled': false},
      call: (api) => api.updateContact(contactId: 2, enabled: false)
    ),
    'device': (
      method: 'POST',
      path: '/devices',
      body: {'fcm_token': 'synthetic-device-token', 'platform': 'android'},
      response: {'id': 3},
      call: (api) => api.registerDevice(
          fcmToken: 'synthetic-device-token', platform: 'android')
    ),
    'test notification': (
      method: 'POST',
      path: '/test-notifications/me',
      body: null,
      response: {'success': true},
      call: (api) => api.sendTestNotification()
    ),
  };
  for (final entry in legacy.entries) {
    test('legacy ${entry.key} preserves its request and success result',
        () async {
      final api = service((request) async {
        expect(request.method, entry.value.method);
        expect(request.url.path, entry.value.path);
        expect(request.headers['Authorization'], 'Bearer $syntheticToken');
        if (entry.value.body != null) {
          expect(jsonDecode(request.body), entry.value.body);
        } else {
          expect(request.body, isEmpty);
        }
        if (entry.key == 'nearby') {
          expect(request.url.queryParameters,
              {'lat': '-33.9', 'lng': '18.4', 'radius_km': '1.0'});
        }
        return entry.key == 'resolve'
            ? http.Response('', 204)
            : reply(entry.value.response);
      });
      final result = await entry.value.call(api);
      expect(result, entry.key == 'panic' ? 7 : entry.value.response);
    });
    test('legacy ${entry.key} also sanitizes HTTP failures', () async {
      final api = service(
          (_) async => http.Response('$privateMarker $syntheticToken', 500));
      expect((await failureFrom(() => entry.value.call(api))).kind,
          ApiFailureKind.server);
    });
  }
}

class TrackingClient extends http.BaseClient {
  TrackingClient(this.delegate);
  final http.Client delegate;
  bool wasClosed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      delegate.send(request);

  @override
  void close() {
    wasClosed = true;
    delegate.close();
  }
}
