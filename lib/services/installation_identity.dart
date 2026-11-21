import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class InstallationIdStorage {
  Future<String?> read();
  Future<void> write(String value);
}

class _FlutterSecureInstallationIdStorage implements InstallationIdStorage {
  _FlutterSecureInstallationIdStorage()
      : _storage = const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _key = 'safe_circle_installation_id_v1';

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);
}

/// One random, device-local ID shared by account sessions in this app install.
/// Firebase authentication still authorizes every backend operation.
class InstallationIdentity {
  InstallationIdentity({InstallationIdStorage? storage, Random? random})
      : _storage = storage ?? _FlutterSecureInstallationIdStorage(),
        _random = random ?? Random.secure();

  final InstallationIdStorage _storage;
  final Random _random;
  Future<String>? _pending;

  Future<String> get id async {
    final pending = _pending ??= _loadOrCreate();
    try {
      return await pending;
    } catch (_) {
      if (identical(_pending, pending)) _pending = null;
      rethrow;
    }
  }

  Future<String> _loadOrCreate() async {
    final saved = await _storage.read();
    if (saved != null) {
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(saved)) {
        throw StateError('Stored installation identifier is invalid.');
      }
      return saved;
    }
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    final generated =
        bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    await _storage.write(generated);
    return generated;
  }
}
