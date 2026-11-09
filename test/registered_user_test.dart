import 'package:flutter_test/flutter_test.dart';
import 'package:safecircle/models/registered_user.dart';

void main() {
  test('parses and serializes only the discovery contract', () {
    final user = RegisteredUser.fromJson({
      'name': 'Example Member',
      'email': 'member+invite&friend@example.invalid',
      'phone': 'synthetic-private-value',
    });
    expect(user.name, 'Example Member');
    expect(user.email, 'member+invite&friend@example.invalid');
    expect(user.toJson(), {
      'name': 'Example Member',
      'email': 'member+invite&friend@example.invalid',
    });
  });

  for (final (index, json) in <Map<String, dynamic>>[
    {},
    {'name': 'Member'},
    {'email': 'member@example.invalid'},
    {'name': 42, 'email': 'member@example.invalid'},
    {'name': 'Member', 'email': null},
  ].indexed) {
    test('rejects invalid discovery fields (case $index)', () {
      expect(() => RegisteredUser.fromJson(json), throwsFormatException);
    });
  }
}
