import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';

class ContactsScreen extends StatelessWidget {
  const ContactsScreen({super.key, required this.onBack});

  final VoidCallback onBack;

  void _showEditContactDialog(
  BuildContext context,
  EmergencyContact contact,
) {
  final nameCtrl = TextEditingController(text: contact.name);
  final relCtrl = TextEditingController(text: contact.relationship);
  final phoneCtrl = TextEditingController(text: contact.phone);

  showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        title: const Text(
          'Edit Contact',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Full name'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: relCtrl,
              decoration: const InputDecoration(labelText: 'Relationship'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: phoneCtrl,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Phone number'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppColors.textMuted),
            ),
          ),
          TextButton(
            onPressed: () async {
              if (nameCtrl.text.trim().isEmpty) return;

              await context.read<AppState>().editContact(
                    contact.id,
                    nameCtrl.text.trim(),
                    relCtrl.text.trim().isEmpty
                        ? 'Contact'
                        : relCtrl.text.trim(),
                    phoneCtrl.text.trim(),
                  );

              if (!dialogContext.mounted) return;
              Navigator.of(dialogContext).pop();
            },
            child: const Text(
              'Save',
              style: TextStyle(
                color: AppColors.tealPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      );
    },
  );
}

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  IconButton(
                      onPressed: onBack,
                      icon: const Icon(Icons.arrow_back, color: AppColors.navyDark),
                    ),
                  const Spacer(),
                  const Icon(Icons.notifications, color: AppColors.navyDark),
                  const SizedBox(width: 12),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Emergency Contacts',
                      style: textTheme.headlineMedium?.copyWith(fontSize: 26)),
                  const Text('People we can notify quickly',
                      style: TextStyle(color: AppColors.textMuted)),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: [
                  for (final contact in state.contacts) ...[
                    _ContactCard(
                      contact: contact,
                      onEdit: () => _showEditContactDialog(context, contact),
                    ),
                    const SizedBox(height: 12),
                  ],
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: ElevatedButton.icon(
                      onPressed: () => _showAddContactDialog(context),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.navyDark,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                      ),
                      icon: const Icon(Icons.add),
                      label: const Text('Add Contact',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    color: AppColors.tealBg,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    child: const Padding(
                      padding: EdgeInsets.all(14),
                      child: Row(
                        children: [
                          Icon(Icons.verified_user, color: AppColors.tealPrimary),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'These contacts can be notified during an active emergency.',
                              style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showAddContactDialog(BuildContext context) {
    final nameCtrl = TextEditingController();
    final relCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();

    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Add Contact', style: TextStyle(fontWeight: FontWeight.w700)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Full name')),
              const SizedBox(height: 10),
              TextField(controller: relCtrl, decoration: const InputDecoration(labelText: 'Relationship')),
              const SizedBox(height: 10),
              TextField(
                controller: phoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Phone number'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel', style: TextStyle(color: AppColors.textMuted)),
            ),
            TextButton(
              onPressed: () async {
                  if (nameCtrl.text.trim().isNotEmpty) {
                    await context.read<AppState>().addContact(
                          nameCtrl.text.trim(),
                          relCtrl.text.trim().isEmpty ? 'Contact' : relCtrl.text.trim(),
                          phoneCtrl.text.trim(),
                        );

                    if (!dialogContext.mounted) return;
                    Navigator.of(dialogContext).pop();
              }
            },
              child: const Text('Add',
                  style: TextStyle(color: AppColors.tealPrimary, fontWeight: FontWeight.w600)),
            ),
          ],
        );
      },
    );
  }
}

class _ContactCard extends StatelessWidget {
  const _ContactCard({
  required this.contact,
  required this.onEdit,
});

final EmergencyContact contact;
final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(color: contact.avatarColor, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: Text(contact.initials,
                  style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.navyDark)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(contact.name, style: Theme.of(context).textTheme.titleMedium),
                  Text(contact.relationship, style: Theme.of(context).textTheme.bodyMedium),
                  Row(
                    children: [
                      const Icon(Icons.call, color: AppColors.textMuted, size: 13),
                      const SizedBox(width: 4),
                      Text(contact.phone,
                          style: const TextStyle(color: AppColors.textMuted, fontSize: 13)),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: onEdit,
              icon: const Icon(Icons.edit, color: AppColors.textMuted),
            ),
            Switch(
              value: contact.enabled,
              onChanged: (_) async {
                  await context.read<AppState>().toggleContact(contact.id);
                },
            ),
          ],
        ),
      ),
    );
  }
}
