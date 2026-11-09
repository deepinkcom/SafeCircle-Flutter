import 'dart:async';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safecircle/models/app_notification.dart';
import 'package:safecircle/services/notification_service.dart';
import 'package:safecircle/state/notifications_state.dart';
import 'notifications_ui_test.dart' as ui;
import 'welcome_navigation_test.dart' as welcome;
import 'support/notifications_fakes.dart';

class ManagementApi extends NotificationsFakeApi {
  final operations = <String>[];
  Future<void> Function()? waitForMutation;
  @override
  Future<AppNotification> fetchNotification(int id) async =>
      notifications.firstWhere((n) => n.id == id);
  @override
  Future<void> manageNotifications(String operation,
      {NotificationCategory? category, int? id}) async {
    operations.add(operation);
    if (waitForMutation != null) await waitForMutation!();
    bool matches(AppNotification n) =>
        category == null || n.category == category;
    if (operation == 'read-all') {
      notifications = [
        for (final n in notifications)
          if (matches(n))
            AppNotification.fromJson(
                {...n.toJson(), 'read_at': '2026-11-08T12:00:00Z'})
          else
            n
      ];
    } else {
      notifications.removeWhere((n) =>
          matches(n) &&
          (operation == 'clear-all' ||
              operation == 'delete' && n.id == id ||
              operation == 'clear-read' && !n.isUnread));
    }
  }
}

class PushService extends NotificationService {
  PushService(ManagementApi api, String? Function() owner)
      : super(apiService: api, currentUserId: owner);
  int displayed = 0;
  @override
  Future<void> showNotification(RemoteMessage message) async {
    displayed++;
  }
}

RemoteMessage push(int id, {String owner = 'alice'}) =>
    RemoteMessage(data: {'notification_id': '$id', 'recipient_uid': owner});
void main() {
  test(
      'foreground delivery deduplicates, revalidates ownership and suppresses deleted rows',
      () async {
    final api = ManagementApi()..notifications = [testNotification(1)];
    String? owner = 'alice';
    final service = PushService(api, () => owner)..bindUser(owner);
    int refreshes = 0;
    service.onInboxChanged = () => refreshes++;
    await service.receive(push(1));
    await service.receive(push(1));
    expect(service.displayed, 1);
    expect(refreshes, 2);
    await service.receive(push(1, owner: 'bob'));
    expect(service.displayed, 1);
    api.notifications.clear();
    await service.receive(push(2));
    expect(service.displayed, 1);
    owner = 'bob';
    service.bindUser(owner);
    await service.receive(push(1));
    expect(service.displayed, 1);
    await service.dispose();
  });
  test(
      'push taps route IDs only for active account and suppress duplicate taps',
      () async {
    final api = ManagementApi();
    String? owner = 'alice';
    final service = PushService(api, () => owner)..bindUser(owner);
    final opened = <int>[];
    service.onNotificationTap = opened.add;
    await service.receive(push(3), tap: true);
    await service.receive(push(3), tap: true);
    await service.receive(push(4, owner: 'bob'), tap: true);
    expect(opened, [3]);
    owner = null;
    service.bindUser(null);
    await service.receive(push(5), tap: true);
    expect(opened, [3]);
    expect(api.notifications, isEmpty);
    await service.dispose();
  });
  test('management obeys category, read state and authoritative unread count',
      () async {
    final api = ManagementApi()
      ..notifications = [
        testNotification(1),
        testNotification(2, category: 'emergency'),
        testNotification(3, read: true)
      ];
    final state = NotificationsState(apiService: api)..setSession('alice');
    addTearDown(state.dispose);
    await state.selectCategory(NotificationCategory.connection);
    expect(await state.manage('read-all'), isTrue);
    expect(state.unreadCount, 1);
    expect(state.items.every((n) => !n.isUnread), isTrue);
    expect(await state.manage('clear-read'), isTrue);
    expect(state.items, isEmpty);
    expect(api.notifications.single.id, 2);
    await state.selectCategory(null);
    await state.manage('delete', id: 2);
    expect(state.items, isEmpty);
    expect(state.unreadCount, 0);
  });
  test(
      'management prevents duplicates and discards completion after account switch',
      () async {
    final gate = Completer<void>();
    final api = ManagementApi()
      ..notifications = [testNotification(1)]
      ..waitForMutation = () => gate.future;
    final state = NotificationsState(apiService: api)..setSession('alice');
    addTearDown(state.dispose);
    await state.refresh();
    final pending = state.manage('clear-all');
    expect(state.isManaging, isTrue);
    expect(await state.manage('clear-all'), isFalse);
    expect(await state.setRead(state.items.single, read: true), isFalse);
    state.setSession('bob');
    gate.complete();
    expect(await pending, isFalse);
    expect(state.items, isEmpty);
    expect(state.unreadCount, isNull);
    expect(api.operations, ['clear-all']);
  });
  testWidgets('Profile bell uses backend unread count and shared inbox',
      (tester) async {
    final api = ManagementApi()..notifications = [testNotification(1)];
    await ui.boot(tester, api);
    await tester.tap(find.text('Profile').last);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Notifications, 1 unread'), findsOneWidget);
    await tester.tap(find.byTooltip('Notifications, 1 unread'));
    await tester.pumpAndSettle();
    expect(find.text('Test notification 1'), findsOneWidget);
  });
  testWidgets(
      'login renders existing SafeCircle asset with preserved proportions',
      (tester) async {
    await welcome.bootWelcome(tester);
    await welcome.tapWelcomeText(tester, 'Log In');
    final image = tester.widget<Image>(find.byType(Image));
    expect((image.image as AssetImage).assetName,
        'assets/branding/neon_guardian_shield_original.png');
    expect(image.fit, BoxFit.contain);
  });
  testWidgets('notification management menu confirms destructive clear',
      (tester) async {
    final api = ManagementApi()..notifications = [testNotification(1)];
    await ui.pumpInbox(tester, api);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear all notifications'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(api.operations, isEmpty);
  });
}
