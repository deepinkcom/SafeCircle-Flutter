import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/app_notification.dart';
import '../state/notifications_state.dart';
import '../theme/app_colors.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen(
      {super.key,
      required this.onOpen,
      required this.onSignIn,
      required this.onCompleteProfile,
      this.initialNotificationId});
  final int? initialNotificationId;
  final Future<String?> Function(AppNotification) onOpen;
  final Future<void> Function() onSignIn;
  final Future<void> Function() onCompleteProfile;
  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  late final NotificationsState _state;
  int? _opening;
  bool _recovering = false;
  late int _session;
  @override
  void initState() {
    super.initState();
    _state = context.read<NotificationsState>();
    _session = _state.sessionVersion;
    _state.addListener(_sessionChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final session = _state.sessionVersion;
      await _state.refresh();
      if (!mounted ||
          session != _state.sessionVersion ||
          widget.initialNotificationId == null) {
        return;
      }
      final row = await _state.resolvePush(widget.initialNotificationId!);
      if (!mounted || session != _state.sessionVersion) return;
      if (row == null) {
        _message('This notification is unavailable or has been removed.');
      } else {
        await _open(row);
      }
    });
  }

  void _sessionChanged() {
    if (_session == _state.sessionVersion) return;
    _session = _state.sessionVersion;
    if (mounted) {
      setState(() {
        _opening = null;
        _recovering = false;
      });
    }
  }

  @override
  void dispose() {
    _state.removeListener(_sessionChanged);
    super.dispose();
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _read(AppNotification notification, bool read) async {
    final session = _state.sessionVersion;
    final success = await _state.setRead(notification, read: read);
    if (!mounted ||
        session != _state.sessionVersion ||
        _state.isAccessBlocked) {
      return;
    }
    _message(success
        ? _state.error != null || _state.countError != null
            ? 'Read status saved. Refresh to update the inbox and unread count.'
            : read
                ? 'Notification marked read.'
                : 'Notification marked unread.'
        : _state.requiresRefresh(notification.id)
            ? 'Read status is uncertain. Refresh notifications before trying again.'
            : 'Could not confirm the update. Check the refreshed notification status.');
  }

  Future<void> _open(AppNotification notification) async {
    if (_opening != null ||
        _state.isAccessBlocked ||
        _state.isMutating(notification.id)) {
      return;
    }
    final session = _state.sessionVersion;
    setState(() => _opening = notification.id);
    try {
      if (notification.isUnread && !_state.requiresRefresh(notification.id)) {
        final saved = await _state.setRead(notification, read: true);
        if (!mounted ||
            session != _state.sessionVersion ||
            _state.isAccessBlocked) {
          return;
        }
        if (!saved) {
          _message(
              'Could not confirm read status. Opening the source does not change its status.');
        }
      }
      final message = await widget.onOpen(notification);
      if (mounted && session == _state.sessionVersion) {
        if (message != null) _message(message);
        await _state.refresh();
      }
    } catch (_) {
      if (mounted && session == _state.sessionVersion) {
        _message('Could not open this notification. Please try again.');
      }
    } finally {
      if (mounted && session == _state.sessionVersion) {
        setState(() => _opening = null);
      }
    }
  }

  Future<void> _recover({bool profile = false, bool retry = false}) async {
    if (_recovering) return;
    final session = _state.sessionVersion;
    setState(() => _recovering = true);
    try {
      if (retry) {
        await _state.retryAccess();
      } else if (profile) {
        await widget.onCompleteProfile();
        if (mounted && session == _state.sessionVersion) {
          await _state.retryAccess();
        }
      } else {
        await widget.onSignIn();
      }
    } catch (_) {
      if (mounted && session == _state.sessionVersion) {
        _message('Could not restore account access. Please try again.');
      }
    } finally {
      if (mounted && session == _state.sessionVersion) {
        setState(() => _recovering = false);
      }
    }
  }

  Widget _notice(String text, {bool retry = true}) => Card(
      color: AppColors.tealBg,
      child: Padding(
          padding: const EdgeInsets.all(14),
          child: Semantics(
              liveRegion: true,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(text),
                    if (retry)
                      TextButton.icon(
                          onPressed: _state.isLoading || _state.isCountLoading
                              ? null
                              : () => _state.refresh(),
                          icon: const Icon(Icons.refresh),
                          label: const Text('Refresh notifications')),
                  ]))));

  Future<void> _manage(String operation, {int? id}) async {
    final session = _state.sessionVersion;
    if (_state.isManaging) return;
    if (operation != 'read-all') {
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
                  title: Text(operation == 'delete'
                      ? 'Delete notification?'
                      : operation == 'clear-read'
                          ? 'Clear read notifications?'
                          : 'Clear all notifications?'),
                  content: const Text(
                      'This removes notifications from your inbox only. Emergency alert history and connection records are preserved. The selected filter applies.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialog, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => Navigator.pop(dialog, true),
                        child: const Text('Confirm'))
                  ]));
      if (!mounted || confirmed != true || session != _state.sessionVersion) {
        return;
      }
    }
    final success = await _state.manage(operation, id: id);
    if (mounted && session == _state.sessionVersion) {
      _message(success
          ? 'Notifications updated.'
          : 'Could not confirm the change. Refresh before trying again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<NotificationsState>();
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications'), actions: [
        PopupMenuButton<String>(
            tooltip: 'Manage notifications',
            onSelected: _manage,
            itemBuilder: (_) => [
                  PopupMenuItem(
                      value: 'read-all',
                      enabled: !state.isAccessBlocked && !state.isManaging,
                      child: const Text('Mark all as read')),
                  PopupMenuItem(
                      value: 'clear-read',
                      enabled: !state.isAccessBlocked && !state.isManaging,
                      child: const Text('Clear read notifications')),
                  PopupMenuItem(
                      value: 'clear-all',
                      enabled: !state.isAccessBlocked && !state.isManaging,
                      child: const Text('Clear all notifications'))
                ]),
        IconButton(
            tooltip: 'Refresh notifications',
            onPressed: state.isLoading || state.isCountLoading
                ? null
                : () => state.refresh(),
            icon: const Icon(Icons.refresh))
      ]),
      body: SafeArea(
          child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: RefreshIndicator(
                    onRefresh: () async {
                      await state.refresh();
                    },
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.all(16),
                      children: [
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          for (final (category, label) in [
                            (null, 'All'),
                            (
                              NotificationCategory.emergency,
                              'Emergency Alerts'
                            ),
                            (NotificationCategory.connection, 'Connections')
                          ])
                            ChoiceChip(
                                label: Text(label),
                                selected: state.category == category,
                                onSelected: (_) =>
                                    state.selectCategory(category)),
                        ]),
                        const SizedBox(height: 12),
                        if (state.isAccessBlocked) ...[
                          _notice(
                              state.needsAuthentication
                                  ? 'Sign in to view notifications.'
                                  : state.needsBackendProfile
                                      ? 'Complete or synchronize your SafeCircle profile to view notifications.'
                                      : 'Account access could not be refreshed. Retry when your connection is available.',
                              retry: false),
                          FilledButton(
                              onPressed: _recovering
                                  ? null
                                  : () => _recover(
                                      profile: state.needsBackendProfile,
                                      retry: !state.needsAuthentication &&
                                          !state.needsBackendProfile),
                              child: Text(state.needsAuthentication
                                  ? 'Sign in again'
                                  : state.needsBackendProfile
                                      ? 'Complete or sync profile'
                                      : 'Retry access')),
                          if (_recovering) const LinearProgressIndicator(),
                        ] else ...[
                          Text(
                              state.unreadCount == null
                                  ? 'Unread count unavailable'
                                  : '${state.unreadCount} unread notifications',
                              style: Theme.of(context).textTheme.titleMedium),
                          if (state.isLoading)
                            const LinearProgressIndicator(
                                semanticsLabel: 'Loading notifications'),
                          if (state.error != null)
                            _notice(
                                '${state.error!.message}${state.hasLoaded ? ' Previously loaded notifications are retained.' : ''}'),
                          if (state.countError != null)
                            _notice(
                                '${state.countError!.message} Unread count could not be refreshed.'),
                          if (state.hasLoaded &&
                              !state.isLoading &&
                              state.error == null &&
                              state.items.isEmpty)
                            const Padding(
                                padding: EdgeInsets.symmetric(vertical: 28),
                                child: Text('No notifications in this view.')),
                          for (final item in state.items) _card(item, state),
                          if (state.hasMore)
                            OutlinedButton(
                                onPressed:
                                    state.isLoading || state.isLoadingMore
                                        ? null
                                        : () => state.loadPage(more: true),
                                child: const Text('Load more')),
                          if (state.isLoadingMore)
                            const LinearProgressIndicator(
                                semanticsLabel: 'Loading more notifications'),
                        ],
                      ],
                    )),
              ))),
    );
  }

  Widget _card(AppNotification item, NotificationsState state) {
    final busy = state.isMutating(item.id) || _opening == item.id;
    return Card(
        key: ValueKey('notification-${item.id}'),
        child: InkWell(
          onTap: busy ? null : () => _open(item),
          borderRadius: BorderRadius.circular(18),
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(
                          item.category == NotificationCategory.emergency
                              ? Icons.warning_amber_rounded
                              : Icons.notifications_outlined,
                          color: AppColors.tealPrimary),
                      const SizedBox(width: 10),
                      Expanded(
                          child: Text(item.title,
                              style: Theme.of(context).textTheme.titleMedium))
                    ]),
                    const SizedBox(height: 8),
                    Text(item.message),
                    const SizedBox(height: 8),
                    Text(DateFormat('d MMM yyyy, HH:mm')
                        .format(item.createdAt.toLocal())),
                    Wrap(
                        spacing: 12,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Chip(label: Text(item.isUnread ? 'Unread' : 'Read')),
                          TextButton.icon(
                              onPressed: busy || state.requiresRefresh(item.id)
                                  ? null
                                  : () => _read(item, item.isUnread),
                              icon: Icon(item.isUnread
                                  ? Icons.mark_email_read_outlined
                                  : Icons.mark_email_unread_outlined),
                              label: Text(
                                  item.isUnread ? 'Mark read' : 'Mark unread')),
                          TextButton.icon(
                              onPressed: busy || state.isManaging
                                  ? null
                                  : () => _manage('delete', id: item.id),
                              icon: const Icon(Icons.delete_outline),
                              label: const Text('Delete')),
                        ]),
                    if (busy)
                      const LinearProgressIndicator(
                          semanticsLabel: 'Updating notification'),
                    if (state.requiresRefresh(item.id))
                      _notice(
                          'Read status is uncertain. Refresh before another update.')
                    else if (state.mutationError(item.id) != null)
                      Text(state.mutationError(item.id)!.message),
                  ])),
        ));
  }
}
