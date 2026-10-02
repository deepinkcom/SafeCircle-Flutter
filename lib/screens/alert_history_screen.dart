import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/top_brand_bar.dart';

enum _HistoryFilter { all, sent, received }

class AlertHistoryScreen extends StatefulWidget {
  const AlertHistoryScreen({super.key});

  @override
  State<AlertHistoryScreen> createState() => _AlertHistoryScreenState();
}

class _AlertHistoryScreenState extends State<AlertHistoryScreen> {
  _HistoryFilter _filter = _HistoryFilter.all;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final filtered = state.alertHistory.where((e) {
      switch (_filter) {
        case _HistoryFilter.all:
          return true;
        case _HistoryFilter.sent:
          return e.kind == AlertKind.emergencySent || e.kind == AlertKind.testSent;
        case _HistoryFilter.received:
          return e.kind == AlertKind.nearbyReceived;
      }
    }).toList();

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
                  Text('Alert History',
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontSize: 26)),
                  const Text('Your alerts and activity history',
                      style: TextStyle(color: AppColors.textMuted)),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  _FilterPill(
                    label: 'All',
                    selected: _filter == _HistoryFilter.all,
                    onTap: () => setState(() => _filter = _HistoryFilter.all),
                  ),
                  const SizedBox(width: 10),
                  _FilterPill(
                    label: 'Sent',
                    icon: Icons.send,
                    selected: _filter == _HistoryFilter.sent,
                    onTap: () => setState(() => _filter = _HistoryFilter.sent),
                  ),
                  const SizedBox(width: 10),
                  _FilterPill(
                    label: 'Received',
                    icon: Icons.groups,
                    selected: _filter == _HistoryFilter.received,
                    onTap: () => setState(() => _filter = _HistoryFilter.received),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemCount: filtered.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, index) => _AlertCard(event: filtered[index]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterPill extends StatelessWidget {
  const _FilterPill({required this.label, required this.selected, required this.onTap, this.icon});

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.tealPrimary : AppColors.cardWhite,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: selected ? null : Border.all(color: AppColors.divider),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: selected ? Colors.white : AppColors.textMuted),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                style: TextStyle(
                  color: selected ? Colors.white : AppColors.textMuted,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AlertCard extends StatelessWidget {
  const _AlertCard({required this.event});

  final AlertEvent event;

  @override
  Widget build(BuildContext context) {
    late IconData icon;
    late Color iconBg;
    late Color iconTint;
    switch (event.kind) {
      case AlertKind.emergencySent:
        icon = Icons.report_problem;
        iconBg = AppColors.redAlert;
        iconTint = Colors.white;
        break;
      case AlertKind.nearbyReceived:
        icon = Icons.groups;
        iconBg = AppColors.tealBg;
        iconTint = AppColors.tealPrimary;
        break;
      case AlertKind.testSent:
        icon = Icons.send;
        iconBg = AppColors.blueAccent;
        iconTint = Colors.white;
        break;
    }

    late String statusLabel;
    late Color statusColor;
    late Color statusBg;
    switch (event.status) {
      case AlertStatus.active:
        statusLabel = 'Active';
        statusColor = AppColors.redAlert;
        statusBg = AppColors.redAlertLight;
        break;
      case AlertStatus.resolved:
        statusLabel = 'Resolved';
        statusColor = AppColors.tealPrimary;
        statusBg = AppColors.tealBg;
        break;
      case AlertStatus.cancelled:
        statusLabel = 'Cancelled';
        statusColor = AppColors.textMuted;
        statusBg = const Color(0xFFEDEFF2);
        break;
    }

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: iconBg, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: Icon(icon, color: iconTint, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(event.title, style: Theme.of(context).textTheme.titleMedium),
                  Text(event.timeLabel, style: Theme.of(context).textTheme.bodyMedium),
                  Row(
                    children: [
                      const Icon(Icons.location_on, color: AppColors.textMuted, size: 12),
                      const SizedBox(width: 3),
                      Text(event.locationLabel,
                          style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
                    ],
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: statusBg, borderRadius: BorderRadius.circular(12)),
                  child: Text(statusLabel,
                      style: TextStyle(
                          color: statusColor, fontSize: 12, fontWeight: FontWeight.w600)),
                ),
                if (event.status == AlertStatus.resolved) ...[
                  const SizedBox(height: 4),
                  const Row(
                    children: [
                      Icon(Icons.check_circle, color: AppColors.tealPrimary, size: 12),
                      SizedBox(width: 3),
                      Text('Resolved', style: TextStyle(color: AppColors.tealPrimary, fontSize: 11)),
                    ],
                  ),
                ],
              ],
            ),
            const Icon(Icons.chevron_right, color: AppColors.textMuted),
          ],
        ),
      ),
    );
  }
}
