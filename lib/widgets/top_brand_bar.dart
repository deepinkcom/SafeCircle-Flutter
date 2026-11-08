import 'package:flutter/material.dart';
import 'safe_circle_mark.dart';
import 'notification_bell.dart';

class TopBrandBar extends StatelessWidget implements PreferredSizeWidget {
  const TopBrandBar(
      {super.key,
      this.showNotification = true,
      this.onBellTap,
      this.unreadCount,
      this.countUnavailable = false});

  final bool showNotification;
  final VoidCallback? onBellTap;
  final int? unreadCount;
  final bool countUnavailable;

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            const SafeCircleMark(size: 32),
            const SizedBox(width: 10),
            Text('SafeCircle', style: Theme.of(context).textTheme.titleLarge),
            const Spacer(),
            if (showNotification)
              NotificationBell(
                  onTap: onBellTap,
                  unreadCount: unreadCount,
                  countUnavailable: countUnavailable),
          ],
        ),
      ),
    );
  }
}
