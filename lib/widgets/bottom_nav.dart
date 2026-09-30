import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

class SafeCircleBottomNav extends StatelessWidget {
  const SafeCircleBottomNav({super.key, required this.currentIndex, required this.onTap});

  final int currentIndex;
  final ValueChanged<int> onTap;

  static const _items = [
    (icon: Icons.home_rounded, label: 'Home'),
    (icon: Icons.shield_rounded, label: 'Alerts'),
    (icon: Icons.map_rounded, label: 'Map'),
    (icon: Icons.history_rounded, label: 'History'),
    (icon: Icons.person_rounded, label: 'Profile'),
  ];

  @override
  Widget build(BuildContext context) {
    return BottomNavigationBar(
      type: BottomNavigationBarType.fixed,
      backgroundColor: AppColors.cardWhite,
      currentIndex: currentIndex,
      onTap: onTap,
      selectedItemColor: AppColors.tealPrimary,
      unselectedItemColor: AppColors.textMuted,
      selectedLabelStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
      unselectedLabelStyle: const TextStyle(fontSize: 11),
      items: [
        for (final item in _items)
          BottomNavigationBarItem(icon: Icon(item.icon), label: item.label),
      ],
    );
  }
}
