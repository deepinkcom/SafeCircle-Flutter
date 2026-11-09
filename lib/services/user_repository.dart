import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/models.dart';
import '../models/profile_photo.dart';

/// Stores SafeCircle user profiles in Cloud Firestore.
///
/// One document per signed-in person: `users/{firebaseUid}`.
/// Passwords stay in Firebase Authentication and are never written here.
class UserRepository {
  UserRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> get _users =>
      _firestore.collection('users');

  Future<UserProfile?> fetchUser(String uid) async {
    final snapshot = await _users.doc(uid).get();
    final data = snapshot.data();
    if (!snapshot.exists || data == null) return null;
    return UserProfile.fromMap(uid, data);
  }

  Future<void> createUser(UserProfile profile) async {
    await _users.doc(profile.uid).set({
      ...profile.toMap(),
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> updateUser(UserProfile profile) async {
    await _users.doc(profile.uid).update({
      'name': profile.name,
      'phone': profile.phone,
      'city': profile.city,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Authoritative read for photo mutation/recovery; never offline cache fallback.
  Future<String?> fetchPhotoPath(String uid) async {
    final snapshot = await _users.doc(uid).get(const GetOptions(source: Source.server));
    if (!snapshot.exists) {
      throw const ProfilePhotoFailure('Complete your profile before changing its picture.');
    }
    final path = snapshot.data()?['photoStoragePath'];
    if (path != null && (path is! String || !ProfilePhotoReference.valid(uid, path))) {
      throw const ProfilePhotoFailure('The saved picture reference is invalid. Contact support.');
    }
    return path as String?;
  }

  /// Compare-and-set preserves all text fields and rejects another device's edit.
  Future<void> compareAndSetPhoto({
    required String uid,
    required String? expectedPath,
    required String? nextPath,
    required bool Function() isCurrent,
  }) async {
    if ((expectedPath != null && !ProfilePhotoReference.valid(uid, expectedPath)) ||
        (nextPath != null && !ProfilePhotoReference.valid(uid, nextPath))) {
      throw const ProfilePhotoFailure('Invalid picture reference.');
    }
    await _firestore.runTransaction((transaction) async {
      if (!isCurrent()) throw const ProfilePhotoFailure('The account changed. Please try again.');
      final reference = _users.doc(uid);
      final snapshot = await transaction.get(reference);
      if (!isCurrent()) throw const ProfilePhotoFailure('The account changed. Please try again.');
      if (!snapshot.exists || snapshot.data()?['photoStoragePath'] != expectedPath) {
        throw const ProfilePhotoFailure(
          'Your picture changed elsewhere. Refresh before trying again.',
          requiresRefresh: true,
        );
      }
      transaction.update(reference, {
        'photoStoragePath': nextPath,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
  }
}
