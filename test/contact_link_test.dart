import 'package:flutter_test/flutter_test.dart';
import 'package:safecircle/models/contact_link.dart';

Map<String, dynamic> relationshipJson() => {
      'id': 7,
      'inviter_user_id': 1,
      'invitee_user_id': 2,
      'other_user_id': 2,
      'status': 'pending',
      'created_at': '2026-11-07T10:00:00.000Z',
      'updated_at': '2026-11-07T10:00:00.000Z',
      'responded_at': null,
      'revoked_at': null,
      'other_user': {
        'id': 2,
        'name': 'Example Member',
        'email': 'member@example.invalid',
      },
    };

void main() {
  test('round trips all relationship fields and integer IDs', () {
    final json = relationshipJson();
    final link = ContactLink.fromJson(json);
    expect(link.id, 7);
    expect(link.inviterUserId, 1);
    expect(link.inviteeUserId, 2);
    expect(link.otherUserId, 2);
    expect(link.otherUser!.id, 2);
    expect(link.otherUser!.name, 'Example Member');
    expect(link.otherUser!.email, 'member@example.invalid');
    expect(link.createdAt.isUtc, isTrue);
    expect(link.toJson(), json);
  });

  test('nullable counterparty and transition timestamps stay null', () {
    final link =
        ContactLink.fromJson(relationshipJson()..['other_user'] = null);
    expect(link.otherUser, isNull);
    expect(link.respondedAt, isNull);
    expect(link.revokedAt, isNull);
    expect(link.toJson()['other_user'], isNull);
  });

  for (final status in ContactLinkStatus.values) {
    test('status ${status.name} has safe acceptance and activity flags', () {
      final link = ContactLink.fromJson(
        relationshipJson()..['status'] = status.name,
      );
      expect(link.status, status);
      expect(link.isAccepted, status == ContactLinkStatus.accepted);
      expect(
          link.isActive,
          status == ContactLinkStatus.pending ||
              status == ContactLinkStatus.accepted);
    });
  }

  for (final value in ['future-status', '', 'ACCEPTED']) {
    test('unknown status is inactive and preserved: $value', () {
      final link = ContactLink.fromJson(relationshipJson()..['status'] = value);
      expect(link.status, ContactLinkStatus.unknown);
      expect(link.isAccepted, isFalse);
      expect(link.isActive, isFalse);
      expect(link.toJson()['status'], value);
    });
  }

  test('parses offsets and microseconds and serializes UTC timestamps', () {
    final link = ContactLink.fromJson(relationshipJson()
      ..['created_at'] = '2026-11-07T12:00:00+02:00'
      ..['updated_at'] = '2026-11-07T10:05:00.123456+00:00'
      ..['responded_at'] = '2026-11-07T10:03:00Z'
      ..['revoked_at'] = '2026-11-07T11:05:00+01:00');
    expect(link.createdAt, DateTime.utc(2026, 11, 7, 10));
    expect(link.updatedAt.microsecond, 456);
    expect(link.respondedAt, DateTime.utc(2026, 11, 7, 10, 3));
    expect(link.revokedAt, DateTime.utc(2026, 11, 7, 10, 5));
    expect(link.toJson()['created_at'], '2026-11-07T10:00:00.000Z');
    expect(link.toJson()['updated_at'], '2026-11-07T10:05:00.123456Z');
  });

  for (final field in relationshipJson().keys) {
    test('rejects missing contract field $field', () {
      expect(() => ContactLink.fromJson(relationshipJson()..remove(field)),
          throwsFormatException);
    });
  }

  for (final field in [
    'id',
    'inviter_user_id',
    'invitee_user_id',
    'other_user_id'
  ]) {
    for (final value in <Object?>['2', 2.0, null]) {
      test('rejects noninteger $field (${value.runtimeType})', () {
        expect(() => ContactLink.fromJson(relationshipJson()..[field] = value),
            throwsFormatException);
      });
    }
  }

  for (final value in <Object?>[
    null,
    42,
    'not-a-date',
    '2026-11-07',
    '2026-11-07T10:00:00',
    '2026-02-30T10:00:00Z',
    '2026-11-07T24:00:00Z',
    '2026-11-07T10:60:00Z',
    '2026-11-07T10:00:60Z',
    '2026-11-07T10:00:00+24:00',
  ]) {
    test('rejects invalid timestamp $value', () {
      expect(
          () =>
              ContactLink.fromJson(relationshipJson()..['created_at'] = value),
          throwsFormatException);
    });
  }

  for (final field in ['updated_at', 'responded_at', 'revoked_at']) {
    test('rejects invalid $field', () {
      expect(
          () => ContactLink.fromJson(relationshipJson()..[field] = 'invalid'),
          throwsFormatException);
    });
  }

  for (final identity in <Object>[
    'not-an-object',
    {},
    {'id': '2', 'name': 'Member', 'email': 'member@example.invalid'},
    {'id': 2, 'name': null, 'email': 'member@example.invalid'},
    {'id': 2, 'name': 'Member', 'email': 42},
    {'id': 3, 'name': 'Unrelated', 'email': 'other@example.invalid'},
  ]) {
    test('rejects malformed or unrelated counterparty $identity', () {
      expect(
          () => ContactLink.fromJson(
              relationshipJson()..['other_user'] = identity),
          throwsFormatException);
    });
  }

  test('rejects an other-user ID outside the relationship', () {
    expect(
      () => ContactLink.fromJson(relationshipJson()
        ..['other_user_id'] = 3
        ..['other_user'] = null),
      throwsFormatException,
    );
  });

  test('rejects self relationships', () {
    expect(
      () => ContactLink.fromJson(relationshipJson()..['inviter_user_id'] = 2),
      throwsFormatException,
    );
  });

  test('does not serialize unapproved identity fields', () {
    final json = relationshipJson();
    (json['other_user'] as Map<String, dynamic>)['phone'] = 'synthetic-private';
    final result = ContactLink.fromJson(json).toJson();
    expect((result['other_user'] as Map).keys,
        unorderedEquals(['id', 'name', 'email']));
  });
}
