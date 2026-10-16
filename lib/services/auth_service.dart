import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

import '../firebase_bootstrap.dart';
import '../models/models.dart';
import 'user_repository.dart';

/// Email/password sign-in plus the Cloud Firestore user profile.
///
/// Firebase Authentication owns the password. The profile document
/// (`users/{uid}`: name, email, phone, city) is written by [UserRepository].
class AuthFailure implements Exception {
  AuthFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

class AuthService {
  AuthService({FirebaseAuth? auth, UserRepository? users})
      : _auth = auth,
        _users = users;

  final FirebaseAuth? _auth;
  final UserRepository? _users;

  bool get isReady => FirebaseBootstrap.isReady;

  FirebaseAuth get _firebaseAuth => _auth ?? FirebaseAuth.instance;

  UserRepository get _userRepository => _users ?? UserRepository();

  void _ensureReady() {
    if (!isReady) {
      throw AuthFailure(
        'Firebase is not set up yet. Create a Firebase project, enable '
        'Email/Password and Cloud Firestore, then run flutterfire configure '
        'to replace lib/firebase_options.dart.',
      );
    }
  }

  Future<UserProfile?> restoreProfile() async {
    if (!isReady) return null;
    final user = _firebaseAuth.currentUser;
    if (user == null) return null;
    return _profileFor(user);
  }

  Future<UserProfile> signUp({
    required String fullName,
    required String email,
    required String phone,
    required String password,
  }) async {
    _ensureReady();
    try {
      final credential = await _firebaseAuth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      final user = credential.user;
      if (user == null) {
        throw AuthFailure('Account could not be created. Please try again.');
      }

      await user.updateDisplayName(fullName.trim());
      final profile = UserProfile(
        uid: user.uid,
        name: fullName.trim(),
        email: email.trim(),
        phone: phone.trim(),
        city: '',
      );

      try {
        await _userRepository.createUser(profile);
      } catch (_) {
        try {
          await user.delete();
        } catch (_) {}
        throw AuthFailure(
          'Your account could not be saved. Check your connection and try again.',
        );
      }
      return profile;
    } on AuthFailure {
      rethrow;
    } on FirebaseAuthException catch (error) {
      throw AuthFailure(_authMessage(error));
    }
  }

  Future<UserProfile> logIn({
    required String email,
    required String password,
  }) async {
    _ensureReady();
    try {
      final credential = await _firebaseAuth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      final user = credential.user;
      if (user == null) {
        throw AuthFailure('Sign-in failed. Please try again.');
      }
      return _profileFor(user);
    } on AuthFailure {
      rethrow;
    } on FirebaseAuthException catch (error) {
      throw AuthFailure(_authMessage(error));
    }
  }

  Future<UserProfile> updateProfile(UserProfile profile) async {
    _ensureReady();
    if (profile.uid.isEmpty) {
      throw AuthFailure('Sign in before updating your details.');
    }
    try {
      await _userRepository.updateUser(profile);
      final user = _firebaseAuth.currentUser;
      if (user != null && user.uid == profile.uid) {
        await user.updateDisplayName(profile.name);
      }
      return profile;
    } on FirebaseException {
      throw AuthFailure(
        'Your details could not be saved. Check your connection and try again.',
      );
    }
  }

  Future<void> logOut() async {
    if (!isReady) return;
    await _firebaseAuth.signOut();
  }

  Future<UserProfile> _profileFor(User user) async {
    final existing = await _userRepository.fetchUser(user.uid);
    if (existing != null) return existing;

    final profile = UserProfile(
      uid: user.uid,
      name: user.displayName ?? '',
      email: user.email ?? '',
      phone: '',
      city: '',
    );
    await _userRepository.createUser(profile);
    return profile;
  }

  String _authMessage(FirebaseAuthException error) {
    switch (error.code) {
      case 'email-already-in-use':
        return 'An account already exists for that email.';
      case 'invalid-email':
        return 'Enter a valid email address.';
      case 'weak-password':
        return 'Password must be at least 6 characters.';
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return 'Email or password is incorrect.';
      case 'user-disabled':
        return 'This account has been disabled.';
      case 'too-many-requests':
        return 'Too many attempts. Wait a moment and try again.';
      case 'network-request-failed':
        return 'Network error. Check your connection and try again.';
      default:
        return error.message ?? 'Authentication failed. Please try again.';
    }
  }
}
