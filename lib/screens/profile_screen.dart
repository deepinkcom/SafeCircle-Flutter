import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/top_brand_bar.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, required this.onOpenContacts, required this.onLogOut});

  final VoidCallback onOpenContacts;
  final VoidCallback onLogOut;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool _notificationsEnabled = true;

  @override
  Widget build(BuildContext context) {
    final profile = context.watch<AppState>().userProfile;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: const TopBrandBar(),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          children: [
            Text('Profile & Settings', style: textTheme.headlineMedium?.copyWith(fontSize: 26)),
            const Text('Manage your account and preferences',
                style: TextStyle(color: AppColors.textMuted)),
            const SizedBox(height: 16),
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: const BoxDecoration(color: AppColors.tealBg, shape: BoxShape.circle),
                      alignment: Alignment.center,
                      child: const Icon(Icons.person, color: AppColors.tealPrimary, size: 32),
                    ),
                    const SizedBox(width: 14),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(profile.name, style: textTheme.titleLarge),
                        Row(
                          children: [
                            const Icon(Icons.location_on, color: AppColors.textMuted, size: 14),
                            const SizedBox(width: 3),
                            Text(profile.city,
                                style: const TextStyle(color: AppColors.textMuted, fontSize: 13)),
                          ],
                        ),
                        const SizedBox(height: 2),
                        const Row(
                          children: [
                            Icon(Icons.verified_user, color: AppColors.tealPrimary, size: 14),
                            SizedBox(width: 3),
                            Text('Safety community member',
                                style: TextStyle(
                                    color: AppColors.tealPrimary,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            _SettingsRow(
              icon: Icons.person,
              title: 'Personal Details',
              subtitle: 'Update your name, email and phone',
              onTap: () {},
            ),
            _SettingsRow(
              icon: Icons.shield,
              title: 'Privacy & Location',
              subtitle: 'Manage location sharing and privacy',
              onTap: () {},
            ),
            _SettingsToggleRow(
              icon: Icons.notifications,
              title: 'Notifications',
              subtitle: 'Manage your alert and app notifications',
              value: _notificationsEnabled,
              onChanged: (v) => setState(() => _notificationsEnabled = v),
            ),
            _SettingsRow(
              icon: Icons.groups,
              title: 'Emergency Contacts',
              subtitle: 'View and manage your contacts',
              onTap: widget.onOpenContacts,
            ),
            _SettingsRow(
              icon: Icons.help_outline,
              title: 'Help & Support',
              subtitle: 'Get help and view FAQs',
              onTap: () {},
            ),
            _SettingsRow(
              icon: Icons.logout,
              title: 'Log Out',
              subtitle: 'Sign out of your SafeCircle account',
              danger: true,
              onTap: widget.onLogOut,
            ),
            const SizedBox(height: 14),
            Card(
              color: AppColors.tealBg,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                      alignment: Alignment.center,
                      child: const Icon(Icons.verified_user, color: AppColors.tealPrimary, size: 18),
                    ),
                    const SizedBox(width: 10),
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("Together, we're building",
                            style: TextStyle(color: AppColors.navyDark, fontSize: 13)),
                        Text('safer communities.',
                            style: TextStyle(
                                color: AppColors.tealPrimary,
                                fontWeight: FontWeight.w700,
                                fontSize: 14)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final tint = danger ? AppColors.redAlert : AppColors.tealPrimary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(icon, color: tint, size: 22),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(color: danger ? AppColors.redAlert : AppColors.navyDark)),
                      Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
                    ],
                  ),
                ),
                Icon(danger ? Icons.arrow_forward : Icons.chevron_right, color: tint),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsToggleRow extends StatelessWidget {
  const _SettingsToggleRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Icon(Icons.notifications, color: AppColors.tealPrimary, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
                  ],
                ),
              ),
              Switch(value: value, onChanged: onChanged),
            ],
          ),
        ),
      ),
    );
  }
}
