/// Wraps Firebase Cloud Messaging (see stack: "Push notifications - Firebase
/// Cloud Messaging - delivers background and foreground emergency
/// notifications to registered devices").
///
/// To activate: uncomment `firebase_messaging` in pubspec.yaml, request
/// notification permission, register the device token with the backend
/// (`POST /devices`), and subscribe to a foreground message stream to show
/// in-app alerts like [EmergencyNearbyScreen].
class NotificationService {
  Future<void> registerDevice() async {
    // TODO: final token = await FirebaseMessaging.instance.getToken();
    //       POST it to the backend so it can be targeted for alert fan-out.
  }

  Future<void> requestPermission() async {
    // TODO: FirebaseMessaging.instance.requestPermission()
  }
}
