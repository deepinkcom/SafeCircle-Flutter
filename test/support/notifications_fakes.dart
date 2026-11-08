import 'package:safecircle/models/app_notification.dart';

import 'contact_links_fakes.dart';

Map<String, dynamic> notificationJson(int id,
        {String category = 'connection', bool read = false, int source = 7}) =>
    {
      'id': id,
      'recipient_user_id': 1,
      'category': category,
      'event_type':
          category == 'connection' ? 'connection.invited' : 'emergency.created',
      'source_id': source,
      'created_at': '2026-11-08T10:00:00+00:00',
      'read_at': read ? '2026-11-08T11:00:00+00:00' : null,
      'title': 'Test notification $id',
      'message': 'Synthetic fixture message $id',
    };

AppNotification testNotification(int id,
        {String category = 'connection', bool read = false, int source = 7}) =>
    AppNotification.fromJson(
        notificationJson(id, category: category, read: read, source: source));

class NotificationsFakeApi extends ContactLinksFakeApi {
  List<AppNotification> notifications = [];
  int pageCalls = 0, countCalls = 0;
  final updates = <(int, bool)>[];
  final requests = <(NotificationCategory?, int)>[];
  Future<NotificationPage> Function(NotificationCategory?, int, int)? onPage;
  Future<int> Function()? onCount;
  Future<AppNotification> Function(int, bool)? onUpdate;
  List<Map<String, dynamic>> history = [];
  List<Map<String, dynamic>> nearby = [];
  int historyCalls = 0, nearbyCalls = 0;

  @override
  Future<NotificationPage> fetchNotifications(
      {NotificationCategory? category, int limit = 20, int offset = 0}) async {
    pageCalls++;
    requests.add((category, offset));
    if (onPage != null) return onPage!(category, limit, offset);
    final rows = notifications
        .where((n) => category == null || n.category == category)
        .toList()
      ..sort((a, b) => b.id.compareTo(a.id));
    return NotificationPage(
        items: rows.skip(offset).take(limit).toList(),
        total: rows.length,
        limit: limit,
        offset: offset,
        hasMore: offset + limit < rows.length);
  }

  @override
  Future<int> fetchNotificationUnreadCount() async {
    countCalls++;
    return onCount != null
        ? onCount!()
        : notifications.where((n) => n.isUnread).length;
  }

  @override
  Future<AppNotification> updateNotificationRead(
      {required int notificationId, required bool read}) async {
    updates.add((notificationId, read));
    if (onUpdate != null) return onUpdate!(notificationId, read);
    final index = notifications.indexWhere((n) => n.id == notificationId);
    final updated = AppNotification.fromJson({
      ...notifications[index].toJson(),
      'read_at': read ? '2026-11-08T12:00:00+00:00' : null
    });
    notifications[index] = updated;
    return updated;
  }

  @override
  Future<List<Map<String, dynamic>>> fetchAlertHistory() async {
    historyCalls++;
    return history;
  }

  @override
  Future<List<Map<String, dynamic>>> fetchNearbyAlerts(
      {required double latitude,
      required double longitude,
      double radiusKm = 1}) async {
    nearbyCalls++;
    return nearby;
  }
}
