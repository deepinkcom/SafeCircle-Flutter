/// Wraps Firebase Authentication (see stack: "Authentication - Firebase
/// Authentication - provides secure sign-in and issues identity tokens
/// verified by the backend").
///
/// To activate: uncomment `firebase_core` and `firebase_auth` in
/// pubspec.yaml, add your `google-services.json` / `GoogleService-Info.plist`,
/// call `Firebase.initializeApp()` in `main()`, then replace the method
/// bodies below with real `FirebaseAuth.instance` calls. Everything above
/// this layer (screens, AppState) already calls through this class, so no
/// other file needs to change.
class AuthService {
  Future<String?> signUp({
    required String fullName,
    required String email,
    required String password,
  }) async {
    // TODO: FirebaseAuth.instance.createUserWithEmailAndPassword(...)
    // then POST the resulting ID token to POST /auth/session on the backend.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return null; // return an error message on failure, null on success
  }

  Future<String?> logIn({
    required String email,
    required String password,
  }) async {
    // TODO: FirebaseAuth.instance.signInWithEmailAndPassword(...)
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return null;
  }

  Future<void> logOut() async {
    // TODO: FirebaseAuth.instance.signOut()
  }
}
