import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/mock_map.dart';
import '../widgets/safe_circle_mark.dart';

class EmergencyActiveScreen extends StatefulWidget {
  const EmergencyActiveScreen({super.key, required this.onBack, required this.onImSafe});

  final VoidCallback onBack;
  final VoidCallback onImSafe;

  @override
  State<EmergencyActiveScreen> createState() => _EmergencyActiveScreenState();
}

class _EmergencyActiveScreenState extends State<EmergencyActiveScreen> {
  int _elapsedSeconds = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _elapsedSeconds++);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final mm = _elapsedSeconds ~/ 60;
    final ss = _elapsedSeconds % 60;
    final timeLabel =
        '00:${mm.toString().padLeft(2, '0')}:${ss.toString().padLeft(2, '0')}';
    final usersAlerted = state.contacts.where((c) => c.enabled).length;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  IconButton(
                    onPressed: widget.onBack,
                    icon: const Icon(Icons.arrow_back, color: AppColors.navyDark),
                  ),
                  const SafeCircleMark(size: 26),
                  const SizedBox(width: 6),
                  Text('SafeCircle', style: Theme.of(context).textTheme.titleMedium),
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
                  const Row(
                    children: [
                      Icon(Icons.report_problem, color: AppColors.redAlert),
                      SizedBox(width: 8),
                      Text('Emergency Active',
                          style: TextStyle(
                              color: AppColors.redAlert,
                              fontWeight: FontWeight.w800,
                              fontSize: 24)),
                    ],
                  ),
                  const Text("We've alerted your trusted contacts.",
                      style: TextStyle(color: AppColors.textMuted, fontSize: 14)),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.tealBg,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _Dot(),
                        SizedBox(width: 6),
                        Text('Live location sharing on',
                            style: TextStyle(color: AppColors.tealPrimary, fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    color: const Color(0xFFE7EEF1),
                    child: const Stack(
                      children: [
                        Positioned.fill(child: MockRouteMap()),
                        Positioned(
                          top: 14,
                          right: 14,
                          child: Column(
                            children: [
                              _MapFab(icon: Icons.gps_fixed),
                              SizedBox(height: 10),
                              _MapFab(icon: Icons.layers),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Card(
              margin: EdgeInsets.zero,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration:
                              const BoxDecoration(color: AppColors.tealBg, shape: BoxShape.circle),
                          alignment: Alignment.center,
                          child: const Icon(Icons.location_on, color: AppColors.tealPrimary, size: 18),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Current Location',
                                  style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
                              Text(state.currentLocation,
                                  style: Theme.of(context).textTheme.titleMedium),
                            ],
                          ),
                        ),
                        Container(
                          width: 32,
                          height: 32,
                          decoration:
                              const BoxDecoration(color: AppColors.tealBg, shape: BoxShape.circle),
                          alignment: Alignment.center,
                          child: const Icon(Icons.verified_user, color: AppColors.tealPrimary, size: 16),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Elapsed Time',
                                  style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
                              Text(timeLabel,
                                  style: const TextStyle(
                                      color: AppColors.redAlert,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 18)),
                            ],
                          ),
                        ),
                        Container(width: 1, height: 36, color: AppColors.divider),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Users Alerted',
                                  style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
                              Text('$usersAlerted',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 18,
                                      color: AppColors.navyDark)),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: ElevatedButton.icon(
                        onPressed: widget.onImSafe,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.redAlert,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                        ),
                        icon: const Icon(Icons.verified_user, size: 18),
                        label: const Text("I'm Safe",
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: OutlinedButton.icon(
                        onPressed: () {},
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: AppColors.tealPrimary),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                        ),
                        icon: const Icon(Icons.campaign, color: AppColors.tealPrimary, size: 18),
                        label: const Text('Share Update',
                            style: TextStyle(
                                color: AppColors.tealPrimary,
                                fontSize: 16,
                                fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot();
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: const BoxDecoration(color: AppColors.tealPrimary, shape: BoxShape.circle),
    );
  }
}

class _MapFab extends StatelessWidget {
  const _MapFab({required this.icon});
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Icon(icon, color: AppColors.navyDark, size: 18),
    );
  }
}
