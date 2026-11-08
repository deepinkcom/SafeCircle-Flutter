enum NotificationCategory { emergency, connection, unknown }

class AppNotification {
  const AppNotification(
      {required this.id,
      required this.recipientUserId,
      required this.rawCategory,
      required this.eventType,
      required this.sourceId,
      required this.createdAt,
      required this.readAt,
      required this.title,
      required this.message});

  final int id;
  final int recipientUserId;
  final String rawCategory;
  final String eventType;
  final int sourceId;
  final DateTime createdAt;
  final DateTime? readAt;
  final String title;
  final String message;
  bool get isUnread => readAt == null;
  NotificationCategory get category => switch (rawCategory) {
        'emergency' => NotificationCategory.emergency,
        'connection' => NotificationCategory.connection,
        _ => NotificationCategory.unknown,
      };

  factory AppNotification.fromJson(Map<String, dynamic> json) {
    for (final name in ['id', 'recipient_user_id', 'source_id']) {
      if (json[name] is! int || (json[name] as int) <= 0) {
        throw const FormatException('Invalid notification identity.');
      }
    }
    for (final (name, length) in [
      ('category', 20),
      ('event_type', 64),
      ('title', 160),
      ('message', 500)
    ]) {
      final value = json[name];
      if (value is! String || value.trim().isEmpty || value.length > length) {
        throw const FormatException('Invalid notification text.');
      }
    }
    if (!json.containsKey('read_at')) {
      throw const FormatException('Missing read status.');
    }
    return AppNotification(
        id: json['id'] as int,
        recipientUserId: json['recipient_user_id'] as int,
        rawCategory: json['category'] as String,
        eventType: json['event_type'] as String,
        sourceId: json['source_id'] as int,
        createdAt: _timestamp(json['created_at']),
        readAt: json['read_at'] == null ? null : _timestamp(json['read_at']),
        title: json['title'] as String,
        message: json['message'] as String);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'recipient_user_id': recipientUserId,
        'category': rawCategory,
        'event_type': eventType,
        'source_id': sourceId,
        'created_at': createdAt.toUtc().toIso8601String(),
        'read_at': readAt?.toUtc().toIso8601String(),
        'title': title,
        'message': message,
      };

  static DateTime _timestamp(Object? value) {
    if (value is! String) {
      throw const FormatException('Invalid notification timestamp.');
    }
    final match = RegExp(
            r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?(Z|[+-](\d{2}):(\d{2}))$')
        .firstMatch(value);
    final parsed = DateTime.tryParse(value);
    if (match == null || parsed == null) {
      throw const FormatException('Invalid notification timestamp.');
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
      throw const FormatException('Invalid notification timestamp.');
    }
    return parsed.toUtc();
  }
}

class NotificationPage {
  NotificationPage(
      {required List<AppNotification> items,
      required this.total,
      required this.limit,
      required this.offset,
      required this.hasMore})
      : items = List.unmodifiable(items);
  final List<AppNotification> items;
  final int total;
  final int limit;
  final int offset;
  final bool hasMore;

  factory NotificationPage.fromJson(Map<String, dynamic> json) {
    if (json['items'] is! List ||
        json['total'] is! int ||
        (json['total'] as int) < 0 ||
        json['limit'] is! int ||
        (json['limit'] as int) < 1 ||
        (json['limit'] as int) > 100 ||
        json['offset'] is! int ||
        (json['offset'] as int) < 0 ||
        (json['offset'] as int) > 1000000 ||
        json['has_more'] is! bool) {
      throw const FormatException('Invalid notification page.');
    }
    final items = (json['items'] as List).map((row) {
      if (row is! Map<String, dynamic>) {
        throw const FormatException('Invalid notification item.');
      }
      return AppNotification.fromJson(row);
    }).toList();
    if (items.length > (json['limit'] as int) ||
        items.map((n) => n.recipientUserId).toSet().length > 1 ||
        items.map((n) => n.id).toSet().length != items.length ||
        (json['has_more'] == true && items.isEmpty)) {
      throw const FormatException('Invalid notification pagination.');
    }
    return NotificationPage(
        items: items,
        total: json['total'] as int,
        limit: json['limit'] as int,
        offset: json['offset'] as int,
        hasMore: json['has_more'] as bool);
  }
}
