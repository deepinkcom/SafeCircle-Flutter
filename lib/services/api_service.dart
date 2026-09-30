/// Talks to the FastAPI backend (see 6.2.1 Suggested Technology Stack:
/// "Backend API - Python 3 with FastAPI").
///
/// This is currently a stub that the rest of the app calls through, so the
/// UI is already wired for a real backend swap: point [baseUrl] at the
/// deployed Azure App Service URL, replace each method body with a real
/// `dio`/`http` call, and nothing above this layer needs to change.
///
/// Suggested endpoints on the FastAPI side (adjust to taste):
///   POST   /auth/session          - exchange a Firebase ID token for a
///                                   backend session / verify identity
///   GET    /contacts              - list the signed-in user's emergency
///                                   contacts
///   POST   /contacts              - add a contact
///   PATCH  /contacts/{id}         - toggle/edit a contact
///   POST   /alerts/panic          - start an emergency alert (lat/lng),
///                                   fans out via FCM + PostGIS radius query
///   POST   /alerts/{id}/resolve   - mark "I'm Safe"
///   GET    /alerts/history        - alert history (sent + received)
///   GET    /alerts/nearby         - nearby active alerts within N km,
///                                   backed by PostGIS ST_DWithin
class ApiService {
  ApiService({this.baseUrl = 'https://safecircle-api.azurewebsites.net'});

  final String baseUrl;

  Future<void> sendPanicAlert({
    required double latitude,
    required double longitude,
  }) async {
    // TODO: POST $baseUrl/alerts/panic with the auth token + coordinates.
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }

  Future<void> resolveAlert(int alertId) async {
    // TODO: POST $baseUrl/alerts/$alertId/resolve
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }

  Future<List<Map<String, dynamic>>> fetchNearbyAlerts({
    required double latitude,
    required double longitude,
    double radiusKm = 1,
  }) async {
    // TODO: GET $baseUrl/alerts/nearby?lat=&lng=&radius_km=
    // Backed server-side by a PostGIS ST_DWithin geography query.
    return <Map<String, dynamic>>[];
  }
}
