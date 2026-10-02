import 'dart:convert';
import 'package:http/http.dart' as http;

// Talks to the FastAPI backend (see 6.2.1 Suggested Technology Stack:
// "Backend API - Python 3 with FastAPI").
//
// This is currently a stub that the rest of the app calls through, so the
// UI is already wired for a real backend swap: point [baseUrl] at the
// deployed Azure App Service URL, replace each method body with a real
// `dio`/`http` call, and nothing above this layer needs to change.
//
// Suggested endpoints on the FastAPI side (adjust to taste):
//   POST   /auth/session          - exchange a Firebase ID token for a
//                                   backend session / verify identity
//   GET    /contacts              - list the signed-in user's emergency
//                                   contacts
//   POST   /contacts              - add a contact
//   PATCH  /contacts/{id}         - toggle/edit a contact
//   POST   /alerts/panic          - start an emergency alert (lat/lng),
//                                   fans out via FCM + PostGIS radius query
//   POST   /alerts/{id}/resolve   - mark "I'm Safe"
//   GET    /alerts/history        - alert history (sent + received)
//   GET    /alerts/nearby         - nearby active alerts within N km,
//                                   backed by PostGIS ST_DWithin

class ApiService {
  ApiService({this.baseUrl = 'http://192.168.0.28:8000'});

  final String baseUrl;

  Future<int> sendPanicAlert({
  required double latitude,
  required double longitude,
}) async {
  final response = await http.post(
    Uri.parse('$baseUrl/alerts/panic'),
    headers: {
      'Content-Type': 'application/json',
    },
    body: '''
{
  "latitude": $latitude,
  "longitude": $longitude
}
''',
  );

  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw Exception(
      'Failed to send panic alert: '
      '${response.statusCode} ${response.body}',
    );
  }

  final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['id'] as int;
}

  Future<void> resolveAlert(int alertId) async {
  final response = await http.post(
    Uri.parse('$baseUrl/alerts/$alertId/resolve'),
  );

  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw Exception(
      'Failed to resolve alert: '
      '${response.statusCode} ${response.body}',
    );
  }
}

  Future<List<Map<String, dynamic>>> fetchNearbyAlerts({
  required double latitude,
  required double longitude,
  double radiusKm = 1,
}) async {
  final uri = Uri.parse(
    '$baseUrl/alerts/nearby'
    '?lat=$latitude'
    '&lng=$longitude'
    '&radius_km=$radiusKm',
  );

  final response = await http.get(uri);

  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw Exception(
      'Failed to fetch nearby alerts: '
      '${response.statusCode} ${response.body}',
    );
  }

  final data = jsonDecode(response.body);

  if (data is! List) {
    throw Exception('Unexpected nearby alerts response.');
  }

  return List<Map<String, dynamic>>.from(data);
}

    Future<List<Map<String, dynamic>>> fetchContacts() async {
      final response = await http.get(
        Uri.parse('$baseUrl/contacts'),
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(
          'Failed to fetch contacts: '
          '${response.statusCode} ${response.body}',
        );
      }

      final data = jsonDecode(response.body);

      if (data is! List) {
        throw Exception('Unexpected contacts response.');
      }

      return List<Map<String, dynamic>>.from(data);
    }

    Future<Map<String, dynamic>> createContact({
      required String name,
      required String relationship,
      required String phone,
      bool enabled = true,
    }) async {
      final response = await http.post(
        Uri.parse('$baseUrl/contacts'),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'name': name,
          'relationship': relationship,
          'phone': phone,
          'enabled': enabled,
        }),
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(
          'Failed to create contact: '
          '${response.statusCode} ${response.body}',
        );
      }

      final data = jsonDecode(response.body);

      if (data is! Map<String, dynamic>) {
        throw Exception('Unexpected create contact response.');
      }

      return data;
    }

    Future<Map<String, dynamic>> updateContact({
      required int contactId,
      String? name,
      String? relationship,
      String? phone,
      bool? enabled,
    }) async {
      final response = await http.patch(
        Uri.parse('$baseUrl/contacts/$contactId'),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          if (name != null) 'name': name,
          if (relationship != null) 'relationship': relationship,
          if (phone != null) 'phone': phone,
          if (enabled != null) 'enabled': enabled,
        }),
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(
          'Failed to update contact: '
          '${response.statusCode} ${response.body}',
        );
      }

      final data = jsonDecode(response.body);

      if (data is! Map<String, dynamic>) {
        throw Exception('Unexpected update contact response.');
      }

      return data;
    }
}
