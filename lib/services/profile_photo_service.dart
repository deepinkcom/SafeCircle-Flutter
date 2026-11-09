import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../firebase_bootstrap.dart';
import '../models/profile_photo.dart';
import 'user_repository.dart';

/// Firestore is the sole photo-reference authority; Storage contains private bytes.
/// No public download URLs, disk image cache, backend mutations or FCM calls.
class ProfilePhotoService {
  ProfilePhotoService({
    FirebaseAuth? auth,
    FirebaseStorage? storage,
    UserRepository? users,
    ImagePicker? picker,
  })  : _auth = auth,
        _providedStorage = storage,
        _users = users,
        _picker = picker;

  static const maxInputBytes = 8 * 1024 * 1024;
  static const maxStoredBytes = 2 * 1024 * 1024;
  final FirebaseAuth? _auth;
  final FirebaseStorage? _providedStorage;
  final UserRepository? _users;
  final ImagePicker? _picker;
  StreamSubscription<User?>? _authChanges;
  UploadTask? _upload;
  String? _uid;
  String? _observedUid;
  int _epoch = 0;
  bool _busy = false;
  bool _disposed = false;
  VoidCallback? onSessionInvalidated;

  FirebaseAuth get _firebaseAuth => _auth ?? FirebaseAuth.instance;
  FirebaseStorage get _storage => _providedStorage ?? FirebaseStorage.instance;
  UserRepository get _repository => _users ?? UserRepository();
  bool sessionMatches(String uid) => !_disposed && _uid == uid;
  bool isCurrentOwner(String uid) => FirebaseBootstrap.isReady &&
      !_disposed && _uid == uid && _firebaseAuth.currentUser?.uid == uid;
  bool get cameraSupported => !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  void setSession(String? uid) {
    _epoch++;
    _uid = uid == null || uid.isEmpty ? null : uid;
    final upload = _upload;
    if (upload != null) unawaited(upload.cancel().catchError((Object _) => false));
  }

  void _watchAuthentication() {
    if (_authChanges != null) return;
    _observedUid = _firebaseAuth.currentUser?.uid;
    _authChanges = _firebaseAuth.authStateChanges().listen((user) {
      if (user?.uid == _observedUid) return;
      _observedUid = user?.uid;
      _epoch++;
      final upload = _upload;
      if (upload != null) unawaited(upload.cancel().catchError((Object _) => false));
      if (!_disposed) onSessionInvalidated?.call();
    }, onError: (Object _) {
      _epoch++;
      _uid = null;
      final upload = _upload;
      if (upload != null) unawaited(upload.cancel().catchError((Object _) => false));
      if (!_disposed) onSessionInvalidated?.call();
    });
  }

  void _guard(String uid, int epoch, bool Function() isCurrent) {
    if (!FirebaseBootstrap.isReady || _disposed || _uid != uid ||
        _epoch != epoch || !isCurrent() || _firebaseAuth.currentUser?.uid != uid) {
      throw const ProfilePhotoFailure('The photo session changed. Close and try again.');
    }
  }

  void _ready(String uid) {
    if (!FirebaseBootstrap.isReady || _disposed || uid.isEmpty || _uid != uid ||
        _firebaseAuth.currentUser?.uid != uid) {
      throw const ProfilePhotoFailure('Sign in before changing your picture.');
    }
    _watchAuthentication();
  }

  ProfilePhotoFailure _safeFailure(Object error, {bool requiresRefresh = false}) {
    if (error is ProfilePhotoFailure && !requiresRefresh) return error;
    var message = 'The picture could not be processed. Please try again.';
    if (error is FirebaseException) {
      switch (error.code) {
        case 'unauthenticated':
        case 'unauthorized':
        case 'permission-denied':
          message = 'Photo access was denied. Check your sign-in and storage configuration.';
          break;
        case 'bucket-not-found':
        case 'project-not-found':
          message = 'Profile-picture storage is not configured yet.';
          break;
        case 'canceled':
        case 'cancelled':
          message = 'The picture operation was cancelled.';
          break;
        default:
          message = 'Photo storage is unavailable. Check your connection and retry.';
          break;
      }
    } else if (error is PlatformException) {
      message = 'Camera or photo access is unavailable. Check device permissions and try again.';
    }
    return ProfilePhotoFailure(
      requiresRefresh
          ? 'The photo update could not be confirmed. Refresh before trying again.'
          : message,
      requiresRefresh: requiresRefresh,
    );
  }

  Future<ProfilePhotoDraft?> pick({
    required String uid,
    required ProfilePhotoSource source,
    required bool Function() isCurrent,
  }) async {
    _ready(uid);
    if (_busy) throw const ProfilePhotoFailure('A picture operation is already running.');
    if (source == ProfilePhotoSource.camera && !cameraSupported) {
      throw const ProfilePhotoFailure('Camera capture is available on Android and iOS.');
    }
    final epoch = _epoch;
    _busy = true;
    try {
      _guard(uid, epoch, isCurrent);
      final file = await (_picker ?? ImagePicker()).pickImage(
        source: source == ProfilePhotoSource.camera ? ImageSource.camera : ImageSource.gallery,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
        requestFullMetadata: false,
      );
      _guard(uid, epoch, isCurrent);
      if (file == null) return null;
      final length = await file.length();
      if (length <= 0 || length > maxInputBytes) {
        throw const ProfilePhotoFailure('Choose a JPEG or PNG picture no larger than 8 MiB after selection.');
      }
      final builder = BytesBuilder(copy: false);
      var count = 0;
      await for (final chunk in file.openRead()) {
        _guard(uid, epoch, isCurrent);
        count += chunk.length;
        if (count > maxInputBytes) {
          throw const ProfilePhotoFailure('The selected picture exceeds the 8 MiB limit.');
        }
        builder.add(chunk);
      }
      final input = builder.takeBytes();
      Uint8List? normalized;
      try {
        _guard(uid, epoch, isCurrent);
        normalized = await _normalize(input);
        _guard(uid, epoch, isCurrent);
        return ProfilePhotoDraft(uid, epoch, normalized);
      } catch (_) {
        if (normalized != null) normalized.fillRange(0, normalized.length, 0);
        rethrow;
      } finally {
        input.fillRange(0, input.length, 0);
      }
    } catch (error) {
      throw _safeFailure(error);
    } finally {
      _busy = false;
    }
  }

  Future<Uint8List> _normalize(Uint8List input) async {
    final jpeg = input.length >= 3 && input[0] == 255 && input[1] == 216 && input[2] == 255;
    const pngHeader = [137, 80, 78, 71, 13, 10, 26, 10];
    final png = input.length >= 8 &&
        List.generate(8, (i) => input[i] == pngHeader[i]).every((value) => value);
    if (input.isEmpty || input.length > maxInputBytes || (!jpeg && !png)) {
      throw const ProfilePhotoFailure('Only valid JPEG and PNG pictures are supported.');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(input);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width <= 0 || descriptor.height <= 0 ||
          descriptor.width > 8192 || descriptor.height > 8192 ||
          descriptor.width * descriptor.height > 24000000) {
        throw const ProfilePhotoFailure('That picture is too large to process safely.');
      }
      final scale = min(1.0, 512 / max(descriptor.width, descriptor.height));
      codec = await descriptor.instantiateCodec(
        targetWidth: max(1, (descriptor.width * scale).round()),
        targetHeight: max(1, (descriptor.height * scale).round()),
      );
      image = (await codec.getNextFrame()).image;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null || data.lengthInBytes > maxStoredBytes) {
        throw const ProfilePhotoFailure('The processed picture exceeds the 2 MiB limit.');
      }
      // Re-encoding drops the original filename and EXIF/GPS metadata.
      return Uint8List.fromList(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  Future<ProfilePhotoResult> load({required String uid, required bool Function() isCurrent}) async {
    _ready(uid);
    final epoch = _epoch;
    try {
      _guard(uid, epoch, isCurrent);
      final path = await _repository.fetchPhotoPath(uid);
      _guard(uid, epoch, isCurrent);
      if (path == null) return const ProfilePhotoResult();
      try {
        final bytes = await _storage.ref(path).getData(maxStoredBytes);
        _guard(uid, epoch, isCurrent);
        if (bytes == null || bytes.isEmpty) throw const ProfilePhotoFailure('Picture unavailable.');
        Uint8List? normalized;
        try {
          normalized = await _normalize(bytes);
          _guard(uid, epoch, isCurrent);
          return ProfilePhotoResult(path: path, bytes: normalized);
        } catch (_) {
          if (normalized != null) normalized.fillRange(0, normalized.length, 0);
          rethrow;
        } finally {
          bytes.fillRange(0, bytes.length, 0);
        }
      } catch (error) {
        _guard(uid, epoch, isCurrent);
        return ProfilePhotoResult(path: path, warning: _safeFailure(error).message);
      }
    } catch (error) {
      throw _safeFailure(error);
    }
  }

  Future<ProfilePhotoResult> save({
    required String uid,
    required String? expectedPath,
    required ProfilePhotoDraft? draft,
    required bool Function() isCurrent,
    void Function(double)? onProgress,
  }) async {
    _ready(uid);
    if (_busy) throw const ProfilePhotoFailure('A picture operation is already running.');
    final epoch = _epoch;
    if (draft != null && (draft.disposed || draft.ownerUid != uid || draft.sessionEpoch != epoch)) {
      throw const ProfilePhotoFailure('Select a new picture for the current session.');
    }
    if (expectedPath != null && !ProfilePhotoReference.valid(uid, expectedPath)) {
      throw const ProfilePhotoFailure('Invalid saved picture reference.');
    }
    _busy = true;
    var committing = false;
    Uint8List? uploadBytes;
    StreamSubscription<TaskSnapshot>? progress;
    try {
      _guard(uid, epoch, isCurrent);
      String? nextPath;
      if (draft != null) {
        uploadBytes = await _normalize(draft.bytes);
        _guard(uid, epoch, isCurrent);
        final random = Random.secure();
        final object = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
        nextPath = 'profilePhotos/$uid/$object.png';
        final task = _storage.ref(nextPath).putData(uploadBytes,
          SettableMetadata(contentType: 'image/png', cacheControl: 'private, no-store',
            customMetadata: {'ownerUid': uid}));
        _upload = task;
        progress = task.snapshotEvents.listen((snapshot) {
          if (snapshot.totalBytes > 0 && isCurrent() && _epoch == epoch) {
            onProgress?.call((snapshot.bytesTransferred / snapshot.totalBytes).clamp(0.0, 1.0).toDouble());
          }
        }, onError: (Object _) {});
        await task.timeout(const Duration(seconds: 60), onTimeout: () async {
          await task.cancel();
          throw const ProfilePhotoFailure('Upload timed out. Refresh before trying again.', requiresRefresh: true);
        });
        _guard(uid, epoch, isCurrent);
      }
      committing = true;
      await _repository.compareAndSetPhoto(uid: uid, expectedPath: expectedPath, nextPath: nextPath,
        isCurrent: () => !_disposed && _epoch == epoch && _uid == uid &&
            _firebaseAuth.currentUser?.uid == uid && isCurrent());
      _guard(uid, epoch, isCurrent);
      String? warning;
      if (expectedPath != null && expectedPath != nextPath) {
        try {
          _guard(uid, epoch, isCurrent);
          // The draft Storage rules also refuse deletion of a referenced object.
          await _storage.ref(expectedPath).delete();
          _guard(uid, epoch, isCurrent);
        } catch (_) {
          warning = 'Picture updated. Previous-file cleanup could not be confirmed.';
        }
      }
      return ProfilePhotoResult(path: nextPath,
        bytes: uploadBytes == null ? null : Uint8List.fromList(uploadBytes), warning: warning);
    } catch (error) {
      // Never delete an uploaded object after an ambiguous Firestore commit: it
      // might be the current photo. Unreferenced leftovers need reviewed cleanup.
      throw _safeFailure(error, requiresRefresh: committing);
    } finally {
      await progress?.cancel();
      if (uploadBytes != null) uploadBytes.fillRange(0, uploadBytes.length, 0);
      _upload = null;
      _busy = false;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    onSessionInvalidated = null;
    setSession(null);
    unawaited(_authChanges?.cancel());
  }
}
