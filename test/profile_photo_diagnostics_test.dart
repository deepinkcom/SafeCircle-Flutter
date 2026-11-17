import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:safecircle/firebase_bootstrap.dart';
import 'package:safecircle/models/profile_photo.dart';
import 'package:safecircle/services/profile_photo_service.dart';

class PhotoAuth extends Fake implements FirebaseAuth {
  @override
  User get currentUser => PhotoUser();
  @override
  Stream<User?> authStateChanges() => const Stream.empty();
}

class PhotoUser extends Fake implements User {
  @override
  String get uid => 'synthetic-owner';
}

void main() {
  test('another account cannot load this session photo', () async {
    FirebaseBootstrap.isReady = true;
    final service = ProfilePhotoService(auth: PhotoAuth())
      ..setSession('synthetic-owner');
    addTearDown(() {
      service.dispose();
      FirebaseBootstrap.isReady = false;
    });
    await expectLater(service.load(uid: 'other-owner', isCurrent: () => true),
        throwsA(isA<ProfilePhotoFailure>()));
  });
  test('another owner photo path is rejected before any storage operation',
      () async {
    FirebaseBootstrap.isReady = true;
    final service = ProfilePhotoService(auth: PhotoAuth())
      ..setSession('synthetic-owner');
    addTearDown(() {
      service.dispose();
      FirebaseBootstrap.isReady = false;
    });
    await expectLater(
        service.save(
            uid: 'synthetic-owner',
            expectedPath: 'profilePhotos/other-owner/${'a' * 32}.png',
            draft: null,
            isCurrent: () => true),
        throwsA(isA<ProfilePhotoFailure>()));
  });
  test(
      'photo storage errors identify permission configuration quota and transfer failures',
      () {
    expect(ProfilePhotoService.storageFailureMessage('unauthorized'),
        contains('rules'));
    expect(ProfilePhotoService.storageFailureMessage('unauthenticated'),
        contains('Sign in'));
    expect(ProfilePhotoService.storageFailureMessage('bucket-not-found'),
        contains('not configured'));
    expect(ProfilePhotoService.storageFailureMessage('quota-exceeded'),
        contains('quota'));
    expect(ProfilePhotoService.storageFailureMessage('retry-limit-exceeded'),
        contains('timed out'));
    expect(ProfilePhotoService.storageFailureMessage('invalid-checksum'),
        contains('incomplete'));
    expect(ProfilePhotoService.storageFailureMessage('object-not-found'),
        contains('unavailable'));
    expect(ProfilePhotoService.storageFailureMessage('private-unknown-code'),
        isNot(contains('private-unknown-code')));
  });
}
