import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import 'safe_circle_mark.dart';

class TopBrandBar extends StatelessWidget implements PreferredSizeWidget {
  const TopBrandBar({super.key, this.showNotification = true, this.onBellTap});

  final bool showNotification;
  final VoidCallback? onBellTap;

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
              Stack(
                clipBehavior: Clip.none,
                children: [
                  IconButton(
                    onPressed: onBellTap,
                    icon: const Icon(Icons.notifications, color: AppColors.navyDark),
                  ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: AppColors.redAlert,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
