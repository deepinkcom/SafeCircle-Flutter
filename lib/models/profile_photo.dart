import 'dart:typed_data';

enum ProfilePhotoSource { gallery, camera }

class ProfilePhotoFailure implements Exception {
  const ProfilePhotoFailure(this.message, {this.requiresRefresh = false});

  final String message;
  final bool requiresRefresh;

  @override
  String toString() => message;
}

/// A private Storage path, never a download URL or arbitrary bucket reference.
class ProfilePhotoReference {
  static bool valid(String uid, String? path) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(uid) || path == null) {
      return false;
    }
    final parts = path.split('/');
    return parts.length == 3 &&
        parts[0] == 'profilePhotos' &&
        parts[1] == uid &&
        RegExp(r'^[a-f0-9]{32}\.png$').hasMatch(parts[2]);
  }
}

/// Memory-only preview bound to the authentication epoch that selected it.
class ProfilePhotoDraft {
  ProfilePhotoDraft(this.ownerUid, this.sessionEpoch, Uint8List bytes)
      : _bytes = bytes,
        _view = bytes.asUnmodifiableView();

  final String ownerUid;
  final int sessionEpoch;
  final Uint8List _bytes;
  final Uint8List _view;
  bool _disposed = false;

  bool get disposed => _disposed;
  Uint8List get bytes => _view;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _bytes.fillRange(0, _bytes.length, 0);
  }
}

class ProfilePhotoResult {
  const ProfilePhotoResult({this.path, this.bytes, this.warning});

  final String? path;
  final Uint8List? bytes;
  final String? warning;
}
