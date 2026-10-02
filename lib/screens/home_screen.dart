import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/mock_map.dart';
import '../widgets/top_brand_bar.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.onActivatePanic,
    required this.onOpenContacts,
    required this.onOpenAlerts,
  });

  final VoidCallback onActivatePanic;
  final VoidCallback onOpenContacts;
  final VoidCallback onOpenAlerts;

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final firstName = state.userProfile.name.split(' ').first;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: const TopBrandBar(),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${_greeting()}, $firstName',
                      style: textTheme.headlineMedium?.copyWith(fontSize: 26)),
                  const SizedBox(height: 6),
                  const Row(
                    children: [
                      Icon(Icons.verified_user, color: AppColors.tealPrimary, size: 18),
                      SizedBox(width: 6),
                      Text('You are currently safe',
                          style: TextStyle(
                              color: AppColors.tealPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 14)),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Card(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        children: [
                          const MiniLocationPreview(),
                          const SizedBox(width: 14),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Your current location', style: textTheme.bodyMedium),
                              Text(state.currentLocation, style: textTheme.titleMedium),
                              const SizedBox(height: 4),
                              const Row(
                                children: [
                                  Icon(Icons.gps_fixed, color: AppColors.tealPrimary, size: 14),
                                  SizedBox(width: 4),
                                  Text('Accuracy: High',
                                      style: TextStyle(color: AppColors.tealPrimary, fontSize: 12)),
                                ],
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                ],
              ),
            ),
            Column(
              children: [
                _PanicButton(onTap: onActivatePanic),
                const SizedBox(height: 12),
                const Text('Press and hold for 3 seconds',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
              ],
            ),
            const SizedBox(height: 28),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Expanded(
                    child: _QuickAction(
                      icon: Icons.near_me,
                      label: 'Share Live\nLocation',
                      onTap: () {},
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _QuickAction(
                      icon: Icons.groups,
                      label: 'Emergency\nContacts',
                      onTap: onOpenContacts,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _QuickAction(
                      icon: Icons.notifications_active,
                      label: 'Nearby\nAlerts',
                      onTap: onOpenAlerts,
                    ),
                  ),
                ],
              ),
            ),
            const Spacer(),
          ],
        ),
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
          child: Column(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: const BoxDecoration(color: AppColors.tealBg, shape: BoxShape.circle),
                alignment: Alignment.center,
                child: Icon(icon, color: AppColors.tealPrimary, size: 20),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.navyDark),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PanicButton extends StatelessWidget {
  const _PanicButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 220,
        height: 220,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 220,
              height: 220,
              decoration: BoxDecoration(
                color: AppColors.redAlert.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
            ),
            Container(
              width: 180,
              height: 180,
              decoration: const BoxDecoration(color: AppColors.redAlert, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.warning_rounded, color: Colors.white, size: 36),
                  SizedBox(height: 4),
                  Text('PANIC',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w800, fontSize: 22)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
