import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

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
  AuthService(
      {FirebaseAuth? auth,
      UserRepository? users,
      void Function(Map<String, Object?>)? diagnostics})
      : _auth = auth,
        _users = users,
        _diagnostics = diagnostics;

  final FirebaseAuth? _auth;
  final UserRepository? _users;
  final void Function(Map<String, Object?>)? _diagnostics;

  void _loginDiagnostic(String stage, [String? code]) {
    final event = <String, Object?>{
      'event': 'safe_circle_login',
      'stage': stage,
      if (code != null) 'firebase_exception_code': code,
    };
    try {
      if (_diagnostics != null) {
        _diagnostics(event);
      } else {
        debugPrint(jsonEncode(event));
      }
    } catch (_) {/* Diagnostics cannot affect authentication. */}
  }

  bool get isReady => FirebaseBootstrap.isReady;

  FirebaseAuth get _firebaseAuth => _auth ?? FirebaseAuth.instance;

  UserRepository get _userRepository => _users ?? UserRepository();

  void _ensureReady() {
    if (!isReady) {
      _loginDiagnostic('firebase_initialization_unavailable');
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
    return await _profileFor(user);
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
    var stage = 'firebase_sign_in';
    _loginDiagnostic('${stage}_started');
    try {
      final credential = await _firebaseAuth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );

      final user = credential.user;
      if (user == null) {
        throw AuthFailure('Sign-in failed. Please try again.');
      }

      _loginDiagnostic('firebase_sign_in_succeeded');
      stage = 'firestore_profile';
      _loginDiagnostic('${stage}_started');
      final profile = await _profileFor(user);
      _loginDiagnostic('firestore_profile_succeeded');
      return profile;
    } on AuthFailure {
      rethrow;
    } on FirebaseAuthException catch (error) {
      _loginDiagnostic('${stage}_failed', error.code);
      if (error.code == 'network-request-failed') {
        throw AuthFailure(
            'SafeCircle could not reach Firebase sign-in. Check this phone\'s date and time, VPN or Private DNS, then try another network.');
      }
      throw AuthFailure(_authMessage(error));
    } on FirebaseException catch (error) {
      _loginDiagnostic('${stage}_failed', error.code);
      throw AuthFailure(error.code == 'permission-denied'
          ? 'Sign-in succeeded, but SafeCircle could not access your profile. Retry or contact the demonstration administrator.'
          : 'Sign-in succeeded, but your SafeCircle profile could not be loaded. Retry when Firebase profile access is available.');
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
    debugPrint(jsonEncode({
      'event': 'safe_circle_auth_sign_out',
      'stage': 'firebase_sign_out_attempted',
    }));
    try {
      await _firebaseAuth.signOut();
      debugPrint(jsonEncode({
        'event': 'safe_circle_auth_sign_out',
        'stage': 'firebase_sign_out_succeeded',
      }));
    } on FirebaseException catch (error) {
      debugPrint(jsonEncode({
        'event': 'safe_circle_auth_sign_out',
        'stage': 'firebase_sign_out_failed',
        'firebase_exception_code': error.code,
      }));
      rethrow;
    } catch (error) {
      debugPrint(jsonEncode({
        'event': 'safe_circle_auth_sign_out',
        'stage': 'firebase_sign_out_failed',
        'exception_type': error.runtimeType.toString(),
      }));
      rethrow;
    }
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
        return 'Firebase authentication could not complete. Retry or ask the administrator to check the diagnostic code.';
    }
  }
}
