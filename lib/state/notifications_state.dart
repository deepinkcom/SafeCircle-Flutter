import 'package:flutter/foundation.dart';

import '../models/app_notification.dart';
import '../services/api_failure.dart';
import '../services/api_service.dart';

class NotificationsState extends ChangeNotifier {
  NotificationsState({required ApiService apiService}) : _api = apiService;
  final ApiService _api;
  String? _userId;
  int _session = 0, _epoch = 0, _pageVersion = 0, _countVersion = 0;
  bool _disposed = false, _recovering = false;
  List<AppNotification> _items = [];
  final Set<int> _busy = {}, _uncertain = {};
  final Map<int, ApiFailure> _mutationErrors = {};
  final Map<int, AppNotification> _resolved = {};
  bool _managing = false;
  bool get isManaging => _managing;
  NotificationCategory? _category;
  int _nextOffset = 0, _total = 0;
  int? _unreadCount;
  bool _loading = false,
      _loadingMore = false,
      _countLoading = false,
      _hasMore = false,
      _hasLoaded = false;
  ApiFailure? _error, _countError, _accessFailure;

  String? get userId => _userId;
  int get sessionVersion => _session;
  List<AppNotification> get items => List.unmodifiable(_items);
  NotificationCategory? get category => _category;
  int? get unreadCount => _unreadCount;
  int get total => _total;
  bool get isLoading => _loading;
  bool get isLoadingMore => _loadingMore;
  bool get isCountLoading => _countLoading;
  bool get hasMore => _hasMore;
  bool get hasLoaded => _hasLoaded;
  ApiFailure? get error => _error;
  ApiFailure? get countError => _countError;
  ApiFailure? get accessFailure => _accessFailure;
  bool get needsAuthentication =>
      _userId == null || _accessFailure?.kind == ApiFailureKind.authentication;
  bool get needsBackendProfile =>
      _accessFailure?.kind == ApiFailureKind.forbidden;
  bool get isAccessBlocked =>
      _userId == null || _accessFailure != null || _recovering;
  bool isMutating(int id) => _busy.contains(id);
  bool requiresRefresh(int id) => _uncertain.contains(id);
  ApiFailure? mutationError(int id) => _mutationErrors[id];
  void reportAccessFailure(ApiFailure failure) {
    if (!_disposed) _recordFailure(failure);
  }

  bool _current(int epoch) => !_disposed && _epoch == epoch;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static ApiFailure _failure(Object error) =>
      error is ApiFailure ? error : const ApiFailure(ApiFailureKind.unexpected);

  void setSession(String? userId) {
    if (_disposed) return;
    final owner = userId == null || userId.isEmpty ? null : userId;
    if (_userId == owner) return;
    _userId = owner;
    _session++;
    _clear();
    _notify();
  }

  void _invalidateReads() {
    _pageVersion++;
    _countVersion++;
    _loading = false;
    _loadingMore = false;
    _countLoading = false;
  }

  void _clear() {
    _epoch++;
    _invalidateReads();
    _items = [];
    _category = null;
    _nextOffset = 0;
    _total = 0;
    _unreadCount = null;
    _hasMore = false;
    _hasLoaded = false;
    _error = null;
    _countError = null;
    _accessFailure = null;
    _recovering = false;
    _busy.clear();
    _uncertain.clear();
    _mutationErrors.clear();
    _resolved.clear();
    _managing = false;
  }

  void _recordFailure(ApiFailure failure) {
    if (failure.kind == ApiFailureKind.authentication ||
        failure.kind == ApiFailureKind.forbidden) {
      _clear();
      _accessFailure = failure;
      _notify();
    }
  }

  Future<bool> selectCategory(NotificationCategory? category) async {
    if (_disposed || category == NotificationCategory.unknown) return false;
    if (_category != category) {
      _pageVersion++;
      _category = category;
      _items = [];
      _hasLoaded = false;
      _nextOffset = 0;
      _hasMore = false;
      _total = 0;
      _error = null;
      _loadingMore = false;
    }
    return refresh();
  }

  Future<bool> refresh() async {
    if (_disposed || _userId == null || _accessFailure != null) return false;
    final epoch = _epoch;
    final uncertain = Set<int>.of(_uncertain);
    final page = loadPage();
    final count = _current(epoch) ? refreshCount() : Future.value(false);
    final results = await Future.wait([page, count]);
    if (!_current(epoch)) return false;
    final success = results.every((result) => result);
    if (success) {
      _uncertain.removeAll(uncertain);
      _recovering = false;
    }
    _notify();
    return _current(epoch) && success;
  }

  Future<bool> retryAccess() async {
    if (_disposed || _userId == null) return false;
    _accessFailure = null;
    _recovering = true;
    return refresh();
  }

  Future<bool> loadPage({bool more = false}) async {
    if (_disposed ||
        _userId == null ||
        _accessFailure != null ||
        (more && (!_hasMore || _loading || _loadingMore))) {
      return false;
    }
    final epoch = _epoch, version = ++_pageVersion;
    final category = _category;
    final offset = more ? _nextOffset : 0;
    if (more) {
      _loadingMore = true;
    } else {
      _loading = true;
      _loadingMore = false;
    }
    _error = null;
    _notify();
    bool current() => _current(epoch) && _pageVersion == version;
    if (!current()) return false;
    try {
      final page =
          await _api.fetchNotifications(category: category, offset: offset);
      if (!current()) return false;
      if (page.offset != offset ||
          (more &&
              _items.isNotEmpty &&
              page.items.any(
                  (n) => n.recipientUserId != _items.first.recipientUserId)) ||
          (category != null && page.items.any((n) => n.category != category))) {
        throw const ApiFailure(ApiFailureKind.invalidResponse);
      }
      final map = {
        if (more)
          for (final n in _items) n.id: n
      };
      for (final n in page.items) {
        map[n.id] = n;
      }
      _items = map.values.toList()
        ..sort((a, b) {
          final date = b.createdAt.compareTo(a.createdAt);
          return date == 0 ? b.id.compareTo(a.id) : date;
        });
      _nextOffset = page.offset + page.items.length;
      _total = page.total;
      _hasMore = page.hasMore && _nextOffset <= 1000000;
      _hasLoaded = true;
      return true;
    } catch (error) {
      if (!current()) return false;
      final failure = _failure(error);
      _recordFailure(failure);
      if (current()) _error = failure;
      return false;
    } finally {
      if (current()) {
        _loading = false;
        _loadingMore = false;
      }
      if (_current(epoch) || _accessFailure != null) _notify();
    }
  }

  Future<bool> refreshCount() async {
    if (_disposed || _userId == null || _accessFailure != null) return false;
    final epoch = _epoch, version = ++_countVersion;
    _countLoading = true;
    _notify();
    bool current() => _current(epoch) && _countVersion == version;
    if (!current()) return false;
    try {
      final count = await _api.fetchNotificationUnreadCount();
      if (!current()) return false;
      if (count < 0) throw const ApiFailure(ApiFailureKind.invalidResponse);
      _unreadCount = count;
      _countError = null;
      return true;
    } catch (error) {
      if (!current()) return false;
      final failure = _failure(error);
      _recordFailure(failure);
      if (current()) _countError = failure;
      return false;
    } finally {
      if (current()) _countLoading = false;
      if (_current(epoch) || _accessFailure != null) _notify();
    }
  }

  Future<bool> setRead(AppNotification item, {required bool read}) async {
    if (_disposed ||
        isAccessBlocked ||
        _managing ||
        _busy.contains(item.id) ||
        _uncertain.contains(item.id)) {
      return false;
    }
    final known =
        _items.where((n) => n.id == item.id).firstOrNull ?? _resolved[item.id];
    if (known == null) return false;
    final epoch = _epoch;
    _busy.add(item.id);
    _mutationErrors.remove(item.id);
    _invalidateReads();
    _notify();
    if (!_current(epoch)) return false;
    try {
      final updated = await _api.updateNotificationRead(
          notificationId: item.id, read: read);
      if (!_current(epoch)) return false;
      if (updated.id != item.id ||
          updated.recipientUserId != item.recipientUserId ||
          updated.sourceId != item.sourceId ||
          updated.rawCategory != item.rawCategory ||
          updated.eventType != item.eventType ||
          updated.isUnread == read) {
        throw const ApiFailure(ApiFailureKind.invalidResponse);
      }
      _invalidateReads();
      _items = [for (final n in _items) n.id == updated.id ? updated : n];
      _unreadCount = null;
      _notify();
      if (!_current(epoch)) return false;
      await refresh();
      return _current(epoch) && _accessFailure == null;
    } catch (error) {
      if (!_current(epoch)) return false;
      final failure = _failure(error);
      _recordFailure(failure);
      if (!_current(epoch)) return false;
      _mutationErrors[item.id] = failure;
      if ({
        ApiFailureKind.network,
        ApiFailureKind.timeout,
        ApiFailureKind.server,
        ApiFailureKind.invalidResponse,
        ApiFailureKind.unexpected
      }.contains(failure.kind)) {
        _uncertain.add(item.id);
      }
      _invalidateReads();
      await refresh();
      return false;
    } finally {
      if (_current(epoch)) {
        _busy.remove(item.id);
        _notify();
      }
    }
  }

  Future<AppNotification?> resolvePush(int id) async {
    if (_disposed || isAccessBlocked) return null;
    final epoch = _epoch;
    try {
      final row = await _api.fetchNotification(id);
      if (!_current(epoch)) return null;
      _resolved[id] = row;
      return row;
    } catch (error) {
      if (_current(epoch)) _recordFailure(_failure(error));
      return null;
    }
  }

  Future<bool> manage(String operation, {int? id}) async {
    if (_disposed || isAccessBlocked || _managing || _busy.isNotEmpty) {
      return false;
    }
    final epoch = _epoch;
    _managing = true;
    _invalidateReads();
    _notify();
    if (!_current(epoch)) return false;
    try {
      await _api.manageNotifications(operation, category: _category, id: id);
      if (!_current(epoch)) return false;
      _invalidateReads();
      _items = [];
      _hasLoaded = false;
      _hasMore = false;
      _resolved.clear();
      _unreadCount = null;
      await refresh();
      return _current(epoch) && _accessFailure == null;
    } catch (error) {
      if (!_current(epoch)) return false;
      final failure = _failure(error);
      _recordFailure(failure);
      if (_current(epoch)) {
        await refresh();
        if (_current(epoch)) _error = failure;
      }
      return false;
    } finally {
      if (_current(epoch)) {
        _managing = false;
        _notify();
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _session++;
    _clear();
    super.dispose();
  }
}
