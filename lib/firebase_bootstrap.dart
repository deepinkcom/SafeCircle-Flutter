/// True after [Firebase.initializeApp] succeeds in `main`.
///
/// Kept outside `firebase_options.dart` so `flutterfire configure` can
/// replace that file without removing the startup flag.
class FirebaseBootstrap {
  static bool isReady = false;
}
