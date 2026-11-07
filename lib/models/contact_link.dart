enum ContactLinkStatus {
  pending,
  accepted,
  rejected,
  revoked,
  unknown;

  static ContactLinkStatus fromValue(String value) => switch (value) {
        'pending' => pending,
        'accepted' => accepted,
        'rejected' => rejected,
        'revoked' => revoked,
        _ => unknown,
      };
}

enum ContactInvitationAction { accept, reject }

/// Participant identity, available only within an authorized relationship.
class ContactLinkUser {
  const ContactLinkUser({
    required this.id,
    required this.name,
    required this.email,
  });

  final int id;
  final String name;
  final String email;

  factory ContactLinkUser.fromJson(Map<String, dynamic> json) {
    if (json['id'] is! int ||
        json['name'] is! String ||
        json['email'] is! String) {
      throw const FormatException('Invalid relationship participant response.');
    }
    return ContactLinkUser(
      id: json['id'] as int,
      name: json['name'] as String,
      email: json['email'] as String,
    );
  }

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'email': email};
}

class ContactLink {
  const ContactLink({
    required this.id,
    required this.inviterUserId,
    required this.inviteeUserId,
    required this.otherUserId,
    required this.rawStatus,
    required this.createdAt,
    required this.updatedAt,
    this.respondedAt,
    this.revokedAt,
    this.otherUser,
  });

  final int id;
  final int inviterUserId;
  final int inviteeUserId;
  final int otherUserId;

  /// Retained for forward-compatible serialization; never infer acceptance.
  final String rawStatus;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? respondedAt;
  final DateTime? revokedAt;
  final ContactLinkUser? otherUser;

  ContactLinkStatus get status => ContactLinkStatus.fromValue(rawStatus);
  bool get isAccepted => status == ContactLinkStatus.accepted;
  bool get isActive =>
      status == ContactLinkStatus.pending ||
      status == ContactLinkStatus.accepted;

  factory ContactLink.fromJson(Map<String, dynamic> json) {
    const fields = {
      'id',
      'inviter_user_id',
      'invitee_user_id',
      'other_user_id',
      'status',
      'created_at',
      'updated_at',
      'responded_at',
      'revoked_at',
      'other_user',
    };
    if (!fields.every(json.containsKey) ||
        json['id'] is! int ||
        json['inviter_user_id'] is! int ||
        json['invitee_user_id'] is! int ||
        json['other_user_id'] is! int ||
        json['status'] is! String) {
      throw const FormatException('Invalid relationship response.');
    }
    final inviter = json['inviter_user_id'] as int;
    final invitee = json['invitee_user_id'] as int;
    final otherId = json['other_user_id'] as int;
    final identity = json['other_user'];
    if (inviter == invitee ||
        (otherId != inviter && otherId != invitee) ||
        (identity != null && identity is! Map<String, dynamic>)) {
      throw const FormatException('Invalid relationship participant response.');
    }
    final other = identity == null
        ? null
        : ContactLinkUser.fromJson(identity as Map<String, dynamic>);
    if (other != null && other.id != otherId) {
      throw const FormatException('Invalid relationship participant response.');
    }
    return ContactLink(
      id: json['id'] as int,
      inviterUserId: inviter,
      inviteeUserId: invitee,
      otherUserId: otherId,
      rawStatus: json['status'] as String,
      createdAt: _timestamp(json['created_at']),
      updatedAt: _timestamp(json['updated_at']),
      respondedAt: json['responded_at'] == null
          ? null
          : _timestamp(json['responded_at']),
      revokedAt:
          json['revoked_at'] == null ? null : _timestamp(json['revoked_at']),
      otherUser: other,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'inviter_user_id': inviterUserId,
        'invitee_user_id': inviteeUserId,
        'other_user_id': otherUserId,
        'status': rawStatus,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
        'responded_at': respondedAt?.toUtc().toIso8601String(),
        'revoked_at': revokedAt?.toUtc().toIso8601String(),
        'other_user': otherUser?.toJson(),
      };

  static DateTime _timestamp(Object? value) {
    // The backend uses timezone-aware ISO timestamps. Reject missing zones and
    // calendar overflows rather than silently interpreting them in local time.
    if (value is! String) {
      throw const FormatException('Invalid relationship timestamp.');
    }
    final match = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?(Z|[+-](\d{2}):(\d{2}))$',
    ).firstMatch(value);
    final parsed = DateTime.tryParse(value);
    if (match == null || parsed == null) {
      throw const FormatException('Invalid relationship timestamp.');
    }
    final year = int.parse(match[1]!);
    final month = int.parse(match[2]!);
    final day = int.parse(match[3]!);
    final date = DateTime.utc(year, month, day);
    if (date.year != year ||
        date.month != month ||
        date.day != day ||
        int.parse(match[4]!) > 23 ||
        int.parse(match[5]!) > 59 ||
        int.parse(match[6]!) > 59 ||
        (match[8] != null && int.parse(match[8]!) > 23) ||
        (match[9] != null && int.parse(match[9]!) > 59)) {
      throw const FormatException('Invalid relationship timestamp.');
    }
    return parsed.toUtc();
  }
}
