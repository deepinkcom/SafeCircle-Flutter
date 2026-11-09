import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:safecircle/models/app_notification.dart';
import 'package:safecircle/services/api_failure.dart';
import 'package:safecircle/state/app_state.dart';
import 'package:safecircle/state/notifications_state.dart';

import 'support/contact_links_fakes.dart';
import 'support/notifications_fakes.dart';

void main() {
  for (final transition in ['logout', 'switch', 'dispose']) {
    test('$transition invalidates pending page and unread-count responses',
        () async {
      final api = NotificationsFakeApi();
      final state = NotificationsState(apiService: api)..setSession('alice');
      addTearDown(state.dispose);
      final page = Completer<NotificationPage>();
      final count = Completer<int>();
      api.onPage = (_, __, ___) => page.future;
      api.onCount = () => count.future;
      final read = state.refresh();
      if (transition == 'dispose') {
        state.dispose();
      } else {
        state.setSession(transition == 'logout' ? null : 'bob');
      }
      page.complete(NotificationPage(
          items: [testNotification(1)],
          total: 1,
          limit: 20,
          offset: 0,
          hasMore: false));
      count.complete(37);
      expect(await read, isFalse);
      expect(state.items, isEmpty);
      expect(state.unreadCount, isNull);
    });
  }
  test('late old-account authentication errors do not clear a new session',
      () async {
    final api = NotificationsFakeApi();
    final state = NotificationsState(apiService: api)..setSession('alice');
    addTearDown(state.dispose);
    final pending = Completer<NotificationPage>();
    api.onPage = (_, __, ___) => pending.future;
    final old = state.loadPage();
    state.setSession('bob');
    api.onPage = null;
    api.notifications = [testNotification(2)];
    await state.refresh();
    pending.completeError(const ApiFailure(ApiFailureKind.authentication));
    await old;
    expect(state.userId, 'bob');
    expect(state.items.single.id, 2);
    expect(state.isAccessBlocked, isFalse);
  });
  late NotificationsFakeApi api;
  late NotificationsState state;
  setUp(() {
    api = NotificationsFakeApi();
    state = NotificationsState(apiService: api)..setSession('alice');
  });
  tearDown(() => state.dispose());

  test('starts empty with unknown unread count and no automatic requests', () {
    expect(state.unreadCount, isNull);
    expect(state.hasLoaded, isFalse);
    expect(api.pageCalls + api.countCalls, 0);
  });
  test(
      'server count is not inferred from a filtered page and filters reset pagination',
      () async {
    api.notifications = [
      testNotification(1),
      testNotification(2, category: 'emergency')
    ];
    api.onCount = () async => 37;
    await state.selectCategory(NotificationCategory.connection);
    expect(state.items.single.id, 1);
    expect(state.unreadCount, 37);
    expect(api.requests.last, (NotificationCategory.connection, 0));
    await state.selectCategory(NotificationCategory.emergency);
    expect(state.items.single.id, 2);
    await state.selectCategory(null);
    expect(state.items, hasLength(2));
    expect(() => state.items.clear(), throwsUnsupportedError);
  });
  test('loads all pages and deduplicates overlapping offset pages', () async {
    api.notifications = [for (var id = 1; id <= 25; id++) testNotification(id)];
    await state.refresh();
    expect(state.items, hasLength(20));
    expect(state.hasMore, isTrue);
    api.notifications.insert(0, testNotification(26));
    await state.loadPage(more: true);
    expect(state.items.map((n) => n.id).toSet(), hasLength(25));
    expect(api.requests.last, (null, 20));
    expect(state.hasMore, isFalse);
    await state.refresh();
    expect(state.items.first.id, 26);
  });
  test('loading flags and failed refresh preserve prior rows/count', () async {
    api.notifications = [testNotification(1)];
    await state.refresh();
    final pending = Completer<NotificationPage>();
    api.onPage = (_, __, ___) => pending.future;
    final read = state.refresh();
    expect(state.isLoading, isTrue);
    pending.completeError(const ApiFailure(ApiFailureKind.network));
    await read;
    expect(state.items.single.id, 1);
    expect(state.error!.kind, ApiFailureKind.network);
    api.onCount = () async => throw const ApiFailure(ApiFailureKind.network);
    await state.refreshCount();
    expect(state.unreadCount, 1);
    expect(state.countError, isNotNull);
  });
  test('new filter makes old page responses stale', () async {
    final old = Completer<NotificationPage>();
    api.onPage = (_, __, ___) => old.future;
    final read = state.refresh();
    api.onPage = null;
    api.notifications = [testNotification(2, category: 'emergency')];
    await state.selectCategory(NotificationCategory.emergency);
    old.complete(NotificationPage(
        items: [testNotification(1)],
        total: 1,
        limit: 20,
        offset: 0,
        hasMore: false));
    await read;
    expect(state.items.single.id, 2);
    expect(state.category, NotificationCategory.emergency);
  });
  test(
      'PATCH waits for confirmation, prevents duplicates and refreshes authoritative count',
      () async {
    api.notifications = [testNotification(1)];
    await state.refresh();
    final pending = Completer<AppNotification>();
    api.onUpdate = (_, __) => pending.future;
    final write = state.setRead(state.items.single, read: true);
    expect(state.items.single.isUnread, isTrue);
    expect(state.isMutating(1), isTrue);
    expect(await state.setRead(state.items.single, read: false), isFalse);
    expect(api.updates, [(1, true)]);
    api.notifications = [testNotification(1, read: true)];
    pending.complete(api.notifications.single);
    expect(await write, isTrue);
    expect(state.items.single.isUnread, isFalse);
    expect(state.unreadCount, 0);
    api.onUpdate = null;
    await state.setRead(state.items.single, read: false);
    expect(state.unreadCount, 1);
  });
  test('pre-PATCH page/count cannot resurrect stale read state', () async {
    api.notifications = [testNotification(1)];
    await state.refresh();
    final old = Completer<NotificationPage>();
    final oldCount = Completer<int>();
    api.onPage = (_, __, ___) => old.future;
    api.onCount = () => oldCount.future;
    final read = state.refresh();
    api.onPage = null;
    api.onCount = null;
    await state.setRead(state.items.single, read: true);
    old.complete(NotificationPage(
        items: [testNotification(1)],
        total: 1,
        limit: 20,
        offset: 0,
        hasMore: false));
    oldCount.complete(100);
    await read;
    expect(state.items.single.isUnread, isFalse);
    expect(state.unreadCount, 0);
  });
  test(
      'uncertain write blocks another update until authoritative recovery succeeds',
      () async {
    api.notifications = [testNotification(1)];
    await state.refresh();
    api.onUpdate = (_, __) async {
      api.onPage =
          (_, __, ___) async => throw const ApiFailure(ApiFailureKind.network);
      throw const ApiFailure(ApiFailureKind.timeout);
    };
    expect(await state.setRead(state.items.single, read: true), isFalse);
    expect(state.requiresRefresh(1), isTrue);
    expect(await state.setRead(state.items.single, read: false), isFalse);
    api.onPage = null;
    api.notifications = [testNotification(1, read: true)];
    await state.refresh();
    expect(state.requiresRefresh(1), isFalse);
    expect(state.items.single.isUnread, isFalse);
    expect(api.updates, hasLength(1));
  });
  for (final kind in [
    ApiFailureKind.authentication,
    ApiFailureKind.forbidden
  ]) {
    test(
        '$kind clears protected rows and count, blocks writes, requires explicit recovery',
        () async {
      api.notifications = [testNotification(1)];
      await state.refresh();
      api.onCount = () async => throw ApiFailure(kind);
      await state.refreshCount();
      expect(state.items, isEmpty);
      expect(state.unreadCount, isNull);
      expect(state.isAccessBlocked, isTrue);
      api.onCount = null;
      expect(await state.refresh(), isFalse);
      expect(await state.retryAccess(), isTrue);
      expect(state.items, hasLength(1));
    });
  }
  for (final transition in ['logout', 'switch', 'dispose']) {
    test('$transition discards late pages/counts and mutation results',
        () async {
      api.notifications = [testNotification(1)];
      await state.refresh();
      final pending = Completer<AppNotification>();
      api.onUpdate = (_, __) => pending.future;
      final write = state.setRead(state.items.single, read: true);
      if (transition == 'dispose') {
        state.dispose();
      } else {
        state.setSession(transition == 'logout' ? null : 'bob');
      }
      pending.complete(testNotification(1, read: true));
      expect(await write, isFalse);
      expect(state.items, isEmpty);
      expect(state.unreadCount, isNull);
    });
  }
  test(
      'listener account change prevents old-session refresh dispatch under new identity',
      () async {
    var switched = false;
    state.addListener(() {
      if (state.isLoading && !switched) {
        switched = true;
        state.setSession('bob');
      }
    });
    await state.refresh();
    expect(api.pageCalls + api.countCalls, 0);
    expect(state.userId, 'bob');
  });
  test(
      'same-account sign out/re-entry and AppState logout reset notification ownership',
      () async {
    final app = AppState(apiService: api, authService: ContactLinksFakeAuth())
      ..userProfile = testProfile('alice');
    addTearDown(app.dispose);
    api.notifications = [testNotification(1)];
    await app.notifications.refresh();
    final version = app.notifications.sessionVersion;
    await app.logOut();
    expect(app.notifications.items, isEmpty);
    expect(app.notifications.userId, isNull);
    app.userProfile = testProfile('alice');
    expect(app.notifications.sessionVersion, greaterThan(version));
    expect(app.contacts, isEmpty);
  });
  test('successful mutation remains confirmed even if subsequent refresh fails',
      () async {
    api.notifications = [testNotification(1)];
    await state.refresh();
    api.onUpdate = (id, read) async {
      api.onPage =
          (_, __, ___) async => throw const ApiFailure(ApiFailureKind.network);
      return testNotification(id, read: read);
    };
    expect(await state.setRead(state.items.single, read: true), isTrue);
    expect(state.items.single.isUnread, isFalse);
    expect(state.error, isNotNull);
  });
}
