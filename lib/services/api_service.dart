import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../models/contact_link.dart';
import '../models/app_notification.dart';
import '../models/registered_user.dart';
import 'api_failure.dart';

class ApiService {
  /// Injected clients belong to the caller. Default clients are created and
  /// closed per request, so existing callers need no new disposal lifecycle.
  /// Production authentication continues to use the current Firebase user.
  ApiService({
    this.baseUrl = 'http://192.168.0.28:8000',
    http.Client? client,
    Future<String?> Function()? tokenProvider,
    this.requestTimeout = const Duration(seconds: 20),
  })  : _client = client,
        _tokenProvider = tokenProvider ?? _firebaseIdToken {
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError('requestTimeout must be positive.');
    }
  }

  final String baseUrl;
  final Duration requestTimeout;
  final http.Client? _client;
  final Future<String?> Function() _tokenProvider;

  static Future<String?> _firebaseIdToken() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw const ApiFailure(ApiFailureKind.authentication);
    }
    return user.getIdToken();
  }

  Future<Map<String, String>> _authHeaders({bool jsonContent = false}) async {
    final token = await _tokenProvider();
    if (token == null || token.trim().isEmpty) {
      throw const ApiFailure(ApiFailureKind.authentication);
    }
    return {
      'Authorization': 'Bearer $token',
      if (jsonContent) 'Content-Type': 'application/json',
    };
  }

  Future<T> _request<T>(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
    bool decodeBody = true,
    required T Function(Object?) parse,
  }) async {
    final client = _client ?? http.Client();
    var expired = false;

    Future<T> perform() async {
      final Map<String, String> headers;
      try {
        headers = await _authHeaders(jsonContent: body != null);
      } catch (_) {
        throw const ApiFailure(ApiFailureKind.authentication);
      }
      // A slow token lookup must not start a write after its caller timed out.
      if (expired) throw const ApiFailure(ApiFailureKind.timeout);
      final uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
      final request = http.Request(method, uri)
        ..followRedirects = false
        ..headers.addAll(headers);
      if (body != null) request.body = jsonEncode(body);
      final response =
          await http.Response.fromStream(await client.send(request));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        // Never copy a backend detail, response body, URI, or token into errors.
        throw ApiFailure.fromStatus(response.statusCode);
      }
      try {
        if (!decodeBody) return parse(null);
        return parse(jsonDecode(utf8.decode(response.bodyBytes)));
      } catch (_) {
        throw const ApiFailure(ApiFailureKind.invalidResponse);
      }
    }

    try {
      // Includes token retrieval, sending, and receiving the complete body.
      // Writes are never automatically retried: a timeout may follow a commit.
      return await perform().timeout(requestTimeout, onTimeout: () {
        expired = true;
        throw const ApiFailure(ApiFailureKind.timeout);
      });
    } on ApiFailure {
      rethrow;
    } on TimeoutException {
      throw const ApiFailure(ApiFailureKind.timeout);
    } on Exception {
      throw const ApiFailure(ApiFailureKind.network);
    } catch (_) {
      throw const ApiFailure(ApiFailureKind.unexpected);
    } finally {
      if (_client == null) client.close();
    }
  }

  static Map<String, dynamic> _object(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Expected an object.');
    }
    return value;
  }

  static List<Map<String, dynamic>> _objects(Object? value) {
    if (value is! List) throw const FormatException('Expected a list.');
    return value.map(_object).toList();
  }

  static String _email(String value) {
    final email = value.trim();
    if (email.length < 3 ||
        email.length > 255 ||
        !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      throw const ApiFailure(ApiFailureKind.validation);
    }
    return email;
  }

  static void _linkId(int id) {
    if (id <= 0) throw const ApiFailure(ApiFailureKind.validation);
  }

  static ContactLink _link(Object? value, {int? expectedId}) {
    final link = ContactLink.fromJson(_object(value));
    if (expectedId != null && link.id != expectedId) {
      throw const FormatException('Unexpected relationship.');
    }
    return link;
  }

  static List<ContactLink> _links(Object? value) =>
      _objects(value).map(ContactLink.fromJson).toList();

  Future<List<RegisteredUser>> searchRegisteredUsers({required String email}) {
    final completeEmail = _email(email);
    return _request('GET', '/users/search', query: {'q': completeEmail},
        parse: (value) {
      final users = _objects(value).map(RegisteredUser.fromJson).toList();
      if (users.length > 1 ||
          users.any((user) =>
              user.email.toLowerCase() != completeEmail.toLowerCase())) {
        throw const FormatException('Unexpected discovery result.');
      }
      return users;
    });
  }

  Future<ContactLink> sendContactInvitation({required String email}) =>
      _request('POST', '/contact-links/invites',
          body: {'email': _email(email)}, parse: _link);

  Future<NotificationPage> fetchNotifications(
      {NotificationCategory? category, int limit = 20, int offset = 0}) {
    if (category == NotificationCategory.unknown ||
        limit < 1 ||
        limit > 100 ||
        offset < 0 ||
        offset > 1000000) {
      throw const ApiFailure(ApiFailureKind.validation);
    }
    return _request('GET', '/notifications', query: {
      if (category != null) 'category': category.name,
      'limit': '$limit',
      'offset': '$offset',
    }, parse: (value) {
      final page = NotificationPage.fromJson(_object(value));
      if (page.offset != offset ||
          page.limit != limit ||
          (category != null && page.items.any((n) => n.category != category))) {
        throw const FormatException('Unexpected notification page.');
      }
      return page;
    });
  }

  Future<int> fetchNotificationUnreadCount() =>
      _request('GET', '/notifications/unread-count', parse: (value) {
        final count = _object(value)['unread_count'];
        if (count is! int || count < 0) {
          throw const FormatException('Invalid unread count.');
        }
        return count;
      });

  Future<AppNotification> fetchNotification(int id) {
    _linkId(id);
    return _request('GET', '/notifications/$id', parse: (value) {
      final row = AppNotification.fromJson(_object(value));
      if (row.id != id) throw const FormatException('Unexpected notification.');
      return row;
    });
  }

  Future<void> manageNotifications(String operation,
      {NotificationCategory? category, int? id}) {
    if (!{'read-all', 'clear-read', 'clear-all', 'delete'}
            .contains(operation) ||
        category == NotificationCategory.unknown) {
      throw const ApiFailure(ApiFailureKind.validation);
    }
    if (operation == 'delete') _linkId(id ?? 0);
    return _request(
        operation == 'read-all' ? 'POST' : 'DELETE',
        operation == 'delete'
            ? '/notifications/$id'
            : operation == 'read-all'
                ? '/notifications/mark-all-read'
                : '/notifications',
        query: {
          if (category != null) 'category': category.name,
          if (operation.startsWith('clear-'))
            'scope': operation == 'clear-read' ? 'read' : 'all'
        }, parse: (value) {
      final n = _object(value)['affected'];
      if (n is! int || n < 0) {
        throw const FormatException('Invalid management response.');
      }
    });
  }

  Future<void> unregisterDevice({required String fcmToken}) =>
      _request('DELETE', '/devices',
          body: {'fcm_token': fcmToken}, decodeBody: false, parse: (_) {});

  Future<AppNotification> updateNotificationRead(
      {required int notificationId, required bool read}) {
    _linkId(notificationId);
    return _request('PATCH', '/notifications/$notificationId',
        body: {'read': read}, parse: (value) {
      final notification = AppNotification.fromJson(_object(value));
      if (notification.id != notificationId || notification.isUnread == read) {
        throw const FormatException('Unexpected notification update.');
      }
      return notification;
    });
  }

  Future<List<ContactLink>> fetchIncomingInvitations() =>
      _request('GET', '/contact-links/invites/incoming', parse: _links);

  Future<List<ContactLink>> fetchOutgoingInvitations() =>
      _request('GET', '/contact-links/invites/outgoing', parse: _links);

  Future<List<ContactLink>> fetchContactRelationships() =>
      _request('GET', '/contact-links/relationships', parse: _links);

  Future<ContactLink> respondToContactInvitation({
    required int linkId,
    required ContactInvitationAction action,
  }) {
    _linkId(linkId);
    return _request('POST', '/contact-links/$linkId/respond',
        body: {'action': action.name},
        parse: (value) => _link(value, expectedId: linkId));
  }

  Future<ContactLink> revokeContactRelationship({required int linkId}) {
    _linkId(linkId);
    return _request('DELETE', '/contact-links/$linkId',
        parse: (value) => _link(value, expectedId: linkId));
  }

  Future<Map<String, dynamic>> syncMyProfile({
    required String name,
    required String city,
    required String phone,
  }) =>
      _request('POST', '/users/me',
          body: {'name': name, 'city': city, 'phone': phone}, parse: _object);

  Future<int> sendPanicAlert({
    required double latitude,
    required double longitude,
  }) =>
      _request('POST', '/alerts/panic',
          body: {'latitude': latitude, 'longitude': longitude}, parse: (value) {
        final id = _object(value)['id'];
        if (id is! int) throw const FormatException('Invalid alert response.');
        return id;
      });

  Future<void> resolveAlert(int alertId) =>
      _request('POST', '/alerts/$alertId/resolve',
          decodeBody: false, parse: (_) {});

  Future<Map<String, dynamic>> acknowledgeAlert(int alertId) =>
      _request('POST', '/alerts/$alertId/acknowledge', parse: _object);

  Future<List<Map<String, dynamic>>> fetchAlertHistory() =>
      _request('GET', '/alerts/history', parse: _objects);

  Future<List<Map<String, dynamic>>> fetchNearbyAlerts({
    required double latitude,
    required double longitude,
    double radiusKm = 1,
  }) =>
      _request('GET', '/alerts/nearby',
          query: {
            'lat': '$latitude',
            'lng': '$longitude',
            'radius_km': '$radiusKm',
          },
          parse: _objects);

  Future<List<Map<String, dynamic>>> fetchContacts() =>
      _request('GET', '/contacts', parse: _objects);

  Future<Map<String, dynamic>> createContact({
    required String name,
    required String relationship,
    required String phone,
    bool enabled = true,
  }) =>
      _request('POST', '/contacts',
          body: {
            'name': name,
            'relationship': relationship,
            'phone': phone,
            'enabled': enabled,
          },
          parse: _object);

  Future<Map<String, dynamic>> updateContact({
    required int contactId,
    String? name,
    String? relationship,
    String? phone,
    bool? enabled,
  }) =>
      _request('PATCH', '/contacts/$contactId',
          body: {
            if (name != null) 'name': name,
            if (relationship != null) 'relationship': relationship,
            if (phone != null) 'phone': phone,
            if (enabled != null) 'enabled': enabled,
          },
          parse: _object);

  Future<Map<String, dynamic>> registerDevice({
    required String fcmToken,
    required String platform,
  }) =>
      _request('POST', '/devices',
          body: {'fcm_token': fcmToken, 'platform': platform}, parse: _object);

  Future<Map<String, dynamic>> sendTestNotification() =>
      _request('POST', '/test-notifications/me', parse: _object);
}
