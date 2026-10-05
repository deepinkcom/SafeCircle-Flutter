import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/mock_map.dart';
import '../widgets/safe_circle_mark.dart';

class EmergencyNearbyScreen extends StatefulWidget {
  const EmergencyNearbyScreen({super.key, required this.onBack, required this.onImOnMyWay});

  final VoidCallback onBack;
  final VoidCallback onImOnMyWay;

    @override
  State<EmergencyNearbyScreen> createState() => _EmergencyNearbyScreenState();
  }

class _EmergencyNearbyScreenState extends State<EmergencyNearbyScreen> {
  @override
  void initState() {
    super.initState();
    context.read<AppState>().loadNearbyAlert();
  }

  @override
  Widget build(BuildContext context) {
    final person = context.watch<AppState>().nearbyPerson;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: IconButton(
                    onPressed: widget.onBack,
                    icon: const Icon(Icons.arrow_back),
                    color: AppColors.navyDark,
                  ),
                ),
              Container(
                width: double.infinity,
                color: AppColors.redAlert,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: const Row(
                  children: [
                    Icon(Icons.report_problem, color: Colors.white),
                    SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Emergency Nearby',
                            style: TextStyle(
                                color: Colors.white, fontWeight: FontWeight.w700, fontSize: 18)),
                        Text('Someone near you needs help',
                            style: TextStyle(color: Colors.white70, fontSize: 13)),
                      ],
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                child: Row(
                  children: [
                    const SafeCircleMark(size: 28),
                    const SizedBox(width: 8),
                    Text('SafeCircle', style: textTheme.titleMedium),
                    const Spacer(),
                    const Icon(Icons.notifications, color: AppColors.navyDark),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Someone nearby\nneeds your help',
                        style: textTheme.headlineMedium?.copyWith(fontSize: 26)),
                    const SizedBox(height: 6),
                    const Text('Your help can make a difference.',
                        style: TextStyle(color: AppColors.textMuted)),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Card(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: Container(
                            height: 150,
                            color: const Color(0xFFE7EEF1),
                            child: const MockPulseMap(),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: const BoxDecoration(
                                  color: AppColors.redAlertLight, shape: BoxShape.circle),
                              alignment: Alignment.center,
                              child: const Icon(Icons.person, color: AppColors.redAlert),
                            ),
                            const SizedBox(width: 10),
                            Text(person.name, style: textTheme.titleLarge),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: _InfoLine(
                              icon: Icons.location_on,
                              text: person.distanceLabel,
                              color: AppColors.tealPrimary),
                        ),
                        const SizedBox(height: 6),
                        const Align(
                          alignment: Alignment.centerLeft,
                          child: _InfoLine(
                              icon: Icons.verified_user,
                              text: 'Live location active',
                              color: AppColors.tealPrimary),
                        ),
                        const SizedBox(height: 6),
                        const Align(
                          alignment: Alignment.centerLeft,
                          child: _InfoLine(
                              icon: Icons.access_time, text: 'Just now', color: AppColors.textMuted),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: [
                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: ElevatedButton.icon(
                        onPressed: () {},
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.navyDark,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                        ),
                        icon: const Icon(Icons.location_on, size: 18),
                        label: const Text('View Live Location',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: ElevatedButton.icon(
                        onPressed: () {},
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.redAlert,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                        ),
                        icon: const Icon(Icons.call, size: 18),
                        label: const Text('Call Emergency Services',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: OutlinedButton.icon(
                        onPressed: widget.onImOnMyWay,
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: AppColors.tealPrimary),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                        ),
                        icon: const Icon(Icons.near_me, color: AppColors.tealPrimary, size: 18),
                        label: const Text("I'm On My Way",
                            style: TextStyle(
                                color: AppColors.tealPrimary,
                                fontSize: 16,
                                fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Icon(Icons.verified_user, color: AppColors.tealPrimary, size: 18),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text('Your location is only shared during emergencies.',
                          style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
                    ),
                    Text('Learn more',
                        style: TextStyle(
                            color: AppColors.tealPrimary,
                            fontWeight: FontWeight.w600,
                            fontSize: 13)),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.icon, required this.text, required this.color});

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 16),
        const SizedBox(width: 6),
        Text(text, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w500)),
      ],
    );
  }
}
