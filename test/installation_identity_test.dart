import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:safecircle/services/installation_identity.dart';

class MemoryStorage implements InstallationIdStorage {
  String? value;
  int writes = 0;
  int failuresRemaining = 0;

  @override
  Future<String?> read() async {
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw StateError('synthetic storage read failure');
    }
    return value;
  }

  @override
  Future<void> write(String value) async {
    writes++;
    this.value = value;
  }
}

void main() {
  test('generates a 256-bit lowercase identifier once and reuses it', () async {
    final storage = MemoryStorage();
    final identity = InstallationIdentity(storage: storage, random: Random(27));

    final first = await identity.id;
    final second = await identity.id;

    expect(first, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(second, first);
    expect(storage.writes, 1);
    expect(await InstallationIdentity(storage: storage).id, first);
  });

  test('concurrent callers share one persisted identifier', () async {
    final storage = MemoryStorage();
    final identity = InstallationIdentity(storage: storage, random: Random(8));

    final ids = await Future.wait(List.generate(10, (_) => identity.id));

    expect(ids.toSet(), hasLength(1));
    expect(storage.writes, 1);
  });

  test('malformed stored identifiers fail closed instead of orphaning rows',
      () async {
    final storage = MemoryStorage()..value = 'copied-or-corrupt-id';
    final identity = InstallationIdentity(storage: storage);

    await expectLater(identity.id, throwsA(isA<StateError>()));
    expect(storage.writes, 0);
  });

  test('secure storage access can be retried after a transient failure',
      () async {
    final storage = MemoryStorage()..failuresRemaining = 1;
    final identity = InstallationIdentity(storage: storage, random: Random(11));

    await expectLater(identity.id, throwsA(isA<StateError>()));
    expect(await identity.id, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(storage.writes, 1);
  });
}
