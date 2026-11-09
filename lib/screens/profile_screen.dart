import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/top_brand_bar.dart';
import '../widgets/backend_profile_banner.dart';
import '../widgets/profile_photo_avatar.dart';
import '../widgets/profile_photo_editor.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen(
      {super.key,
      required this.onOpenContacts,
      required this.onLogOut,
      this.onOpenNotifications,
      this.onNotificationSettings});

  final VoidCallback onOpenContacts;
  final VoidCallback onLogOut;
  final VoidCallback? onOpenNotifications;
  final VoidCallback? onNotificationSettings;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Future<void> _editProfilePicture() async {
    final app = context.read<AppState>();
    final uid = app.userProfile.uid;
    final session = app.photoSessionVersion;
    final saved = await showProfilePhotoEditor(context);
    if (!mounted || saved != true || app.userProfile.uid != uid || app.photoSessionVersion != session) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(app.photoError ?? 'Your profile picture was updated.'),
    ));
  }

  Future<void> _editPersonalDetails() async {
    final profile = context.read<AppState>().userProfile;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => _PersonalDetailsDialog(profile: profile),
    );
    if (!mounted || saved != true) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Your details were saved.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = context.watch<AppState>().userProfile;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: TopBrandBar(
          onBellTap: widget.onOpenNotifications,
          unreadCount: context.watch<AppState>().notifications.unreadCount,
          countUnavailable:
              context.watch<AppState>().notifications.countError != null),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          children: [
            BackendProfileBanner(
                onCompleteProfile: _editPersonalDetails,
                onSignIn: widget.onLogOut),
            if (context.watch<AppState>().backendProfile?.id != null)
              Text(
                  'SafeCircle account #${context.watch<AppState>().backendProfile!.id}'),
            Text('Profile & Settings',
                style: textTheme.headlineMedium?.copyWith(fontSize: 26)),
            const Text('Manage your account and preferences',
                style: TextStyle(color: AppColors.textMuted)),
            const SizedBox(height: 16),
            Card(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    ProfilePhotoAvatar(ownerUid: profile.uid,
                      onTap: profile.isSignedIn ? _editProfilePicture : null),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              profile.name.isEmpty
                                  ? 'SafeCircle member'
                                  : profile.name,
                              style: textTheme.titleLarge),
                          if (profile.email.isNotEmpty)
                            Text(profile.email,
                                style: const TextStyle(
                                    color: AppColors.textMuted, fontSize: 13)),
                          if (profile.phone.isNotEmpty)
                            Text(profile.phone,
                                style: const TextStyle(
                                    color: AppColors.textMuted, fontSize: 13)),
                          if (profile.city.isNotEmpty)
                            Row(
                              children: [
                                const Icon(Icons.location_on,
                                    color: AppColors.textMuted, size: 14),
                                const SizedBox(width: 3),
                                Flexible(
                                  child: Text(profile.city,
                                      style: const TextStyle(
                                          color: AppColors.textMuted,
                                          fontSize: 13)),
                                ),
                              ],
                            ),
                          const SizedBox(height: 2),
                          const Row(
                            children: [
                              Icon(Icons.verified_user,
                                  color: AppColors.tealPrimary, size: 14),
                              SizedBox(width: 3),
                              Flexible(
                                child: Text('Safety community member',
                                    style: TextStyle(
                                        color: AppColors.tealPrimary,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600)),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: profile.isSignedIn ? _editProfilePicture : null,
              icon: const Icon(Icons.add_a_photo_outlined),
              label: const Text('Change profile picture'),
            ),
            if (context.watch<AppState>().photoError != null)
              Text(context.watch<AppState>().photoError!,
                style: const TextStyle(color: AppColors.redAlert)),
            _SettingsRow(
              icon: Icons.person,
              title: 'Personal Details',
              subtitle: 'Update your name, phone and city',
              onTap: _editPersonalDetails,
            ),
            _SettingsRow(
              icon: Icons.shield,
              title: 'Privacy & Location',
              subtitle: 'Manage location sharing and privacy',
              onTap: () {},
            ),
            _SettingsRow(
                icon: Icons.notifications,
                title: 'Notification permissions',
                subtitle:
                    'Device permission only; no account-wide preference is configured.',
                onTap: widget.onNotificationSettings ?? () {}),
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
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: const BoxDecoration(
                          color: Colors.white, shape: BoxShape.circle),
                      alignment: Alignment.center,
                      child: const Icon(Icons.verified_user,
                          color: AppColors.tealPrimary, size: 18),
                    ),
                    const SizedBox(width: 10),
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("Together, we're building",
                            style: TextStyle(
                                color: AppColors.navyDark, fontSize: 13)),
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
                              ?.copyWith(
                                  color: danger
                                      ? AppColors.redAlert
                                      : AppColors.navyDark)),
                      Text(subtitle,
                          style: Theme.of(context).textTheme.bodyMedium),
                    ],
                  ),
                ),
                Icon(danger ? Icons.arrow_forward : Icons.chevron_right,
                    color: tint),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PersonalDetailsDialog extends StatefulWidget {
  const _PersonalDetailsDialog({required this.profile});

  final UserProfile profile;

  @override
  State<_PersonalDetailsDialog> createState() => _PersonalDetailsDialogState();
}

class _PersonalDetailsDialogState extends State<_PersonalDetailsDialog> {
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _city;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.profile.name);
    _phone = TextEditingController(text: widget.profile.phone);
    _city = TextEditingController(text: widget.profile.city);
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _city.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (context.read<AppState>().userProfile.uid != widget.profile.uid) return;
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Enter your name.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await context.read<AppState>().updateProfile(
          name: _name.text,
          phone: _phone.text,
          city: _city.text,
        );
    if (!mounted) return;
    if (context.read<AppState>().userProfile.uid != widget.profile.uid) return;
    if (error != null) {
      setState(() {
        _busy = false;
        _error = error;
      });
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    if (context.watch<AppState>().userProfile.uid != widget.profile.uid) {
      return AlertDialog(
        title: const Text('Account changed'),
        content: const Text(
            'Close this dialog and open Personal Details for the current account.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'))
        ],
      );
    }
    return AlertDialog(
      title: const Text('Personal Details'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ProfilePhotoAvatar(ownerUid: widget.profile.uid, size: 80,
              onTap: _busy ? null : () => showProfilePhotoEditor(context)),
            TextButton(onPressed: _busy ? null : () => showProfilePhotoEditor(context),
              child: const Text('Change profile picture')),
            const Text(
                'Name, phone and city are required for SafeCircle Connections. Save to synchronize only your signed-in account.'),
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Full name'),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                widget.profile.email.isEmpty
                    ? 'Email is your sign-in address'
                    : widget.profile.email,
                style:
                    const TextStyle(color: AppColors.textMuted, fontSize: 13),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Phone'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _city,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'City'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!,
                  style:
                      const TextStyle(color: AppColors.redAlert, fontSize: 13)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}
