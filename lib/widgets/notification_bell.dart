import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

class NotificationBell extends StatelessWidget {
  const NotificationBell(
      {super.key, this.onTap, this.unreadCount, this.countUnavailable = false});
  final VoidCallback? onTap;
  final int? unreadCount;
  final bool countUnavailable;
  @override
  Widget build(BuildContext context) => Badge(
        isLabelVisible: unreadCount != null && unreadCount! > 0,
        label: Text(unreadCount != null && unreadCount! > 99
            ? '99+'
            : '${unreadCount ?? 0}'),
        child: IconButton(
            onPressed: onTap,
            tooltip: countUnavailable
                ? 'Notifications (unread count unavailable)'
                : unreadCount == null
                    ? 'Notifications'
                    : 'Notifications, $unreadCount unread',
            icon: const Icon(Icons.notifications, color: AppColors.navyDark)),
      );
}
