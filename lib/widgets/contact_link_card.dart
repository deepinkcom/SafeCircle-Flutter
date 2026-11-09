import 'package:flutter/material.dart';

import '../models/contact_link.dart';
import '../theme/app_colors.dart';

class ContactLinkCard extends StatelessWidget {
  const ContactLinkCard({
    super.key,
    required this.link,
    this.actions = const [],
    this.isBusy = false,
    this.feedback,
  });

  final ContactLink link;
  final List<Widget> actions;
  final bool isBusy;
  final Widget? feedback;

  @override
  Widget build(BuildContext context) {
    final identity = link.otherUser;
    final name = identity == null
        ? 'Member unavailable'
        : identity.name.trim().isEmpty
            ? 'SafeCircle member'
            : identity.name;
    final label = switch (link.status) {
      ContactLinkStatus.pending => 'Pending',
      ContactLinkStatus.accepted => 'Accepted',
      ContactLinkStatus.rejected => 'Rejected',
      ContactLinkStatus.revoked => 'Revoked',
      ContactLinkStatus.unknown => 'Unknown status',
    };
    final color = switch (link.status) {
      ContactLinkStatus.accepted => AppColors.tealPrimary,
      ContactLinkStatus.rejected => AppColors.redAlert,
      _ => AppColors.navyDark,
    };
    return Semantics(
      container: true,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const CircleAvatar(
                  backgroundColor: AppColors.tealBg,
                  child: Icon(Icons.person_outline, color: AppColors.navyDark),
                ),
                const SizedBox(width: 12),
                Expanded(
                    child: Text(name,
                        style: Theme.of(context).textTheme.titleMedium)),
              ]),
              if (identity != null) ...[
                const SizedBox(height: 8),
                Text(identity.email),
              ],
              const SizedBox(height: 8),
              Chip(
                label: Text(label, style: TextStyle(color: color)),
                backgroundColor: color.withValues(alpha: 0.08),
                side: BorderSide.none,
              ),
              if (isBusy) ...[
                const SizedBox(height: 8),
                const LinearProgressIndicator(
                    semanticsLabel: 'Updating relationship'),
              ],
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: actions),
              ],
              if (feedback != null) ...[const SizedBox(height: 8), feedback!],
            ],
          ),
        ),
      ),
    );
  }
}
