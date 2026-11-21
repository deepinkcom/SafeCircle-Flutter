import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Only requests identity authentication; no contacts or other Google scopes.
class GoogleSignInService {
  static Future<void>? _initialization;

  Future<void> _initialize() async {
    final pending = _initialization ??= GoogleSignIn.instance.initialize();
    try {
      await pending;
    } catch (_) {
      if (identical(_initialization, pending)) _initialization = null;
      rethrow;
    }
  }

  Future<AuthCredential> authenticate() async {
    await _initialize();
    // An explicit sign-in must allow choosing another account on shared phones.
    await GoogleSignIn.instance.signOut();
    final account = await GoogleSignIn.instance.authenticate();
    final token = account.authentication.idToken;
    if (token == null || token.isEmpty) {
      throw FirebaseAuthException(code: 'google-missing-id-token');
    }
    return GoogleAuthProvider.credential(idToken: token);
  }

  Future<void> signOut() async {
    if (_initialization == null) return;
    await _initialize();
    await GoogleSignIn.instance.signOut();
  }
}
