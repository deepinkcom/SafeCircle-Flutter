import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/models.dart';

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
}
