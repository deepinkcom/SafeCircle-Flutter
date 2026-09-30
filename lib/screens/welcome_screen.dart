import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../widgets/safe_circle_mark.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key, required this.onGetStarted, required this.onLogIn});

  final VoidCallback onGetStarted;
  final VoidCallback onLogIn;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const SizedBox(height: 32),
              const SafeCircleMark(size: 96),
              const SizedBox(height: 16),
              Text('SafeCircle', style: textTheme.headlineLarge?.copyWith(fontSize: 32)),
              const SizedBox(height: 20),
              Text('Welcome to SafeCircle',
                  style: textTheme.headlineMedium, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(
                'Together, we help nearby people stay safe when it matters most.',
                style: textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),
              Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                child: Column(
                  children: const [
                    _WelcomeRow(
                      icon: Icons.person_add_alt,
                      title: 'Create an account',
                      subtitle: 'Quick and easy sign up to get started.',
                    ),
                    Divider(height: 1, color: AppColors.divider),
                    _WelcomeRow(
                      icon: Icons.location_on,
                      title: 'Enable location',
                      subtitle: 'Helps us connect you with nearby help.',
                    ),
                    Divider(height: 1, color: AppColors.divider),
                    _WelcomeRow(
                      icon: Icons.notifications_active,
                      title: 'Get nearby emergency alerts',
                      subtitle: 'Receive real-time alerts and updates.',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Card(
                color: AppColors.tealBg,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                elevation: 0,
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.verified_user, color: AppColors.tealPrimary),
                          const SizedBox(width: 10),
                          Text('Your safety, our priority', style: textTheme.titleMedium),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Your location is only shared during emergencies to connect you with people who can help.',
                        style: textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: const [
                          Icon(Icons.lock, color: AppColors.tealPrimary, size: 16),
                          SizedBox(width: 6),
                          Text(
                            'Secure. Private. Only when needed.',
                            style: TextStyle(
                              color: AppColors.tealPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton.icon(
                  onPressed: onGetStarted,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.navyDark,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                  ),
                  icon: const Icon(Icons.shield, size: 18),
                  label: const Text('Get Started',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('Already have an account? ',
                      style: const TextStyle(color: AppColors.textMuted, fontSize: 14)),
                  GestureDetector(
                    onTap: onLogIn,
                    child: const Text(
                      'Log In',
                      style: TextStyle(
                        color: AppColors.tealPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

class _WelcomeRow extends StatelessWidget {
  const _WelcomeRow({required this.icon, required this.title, required this.subtitle});

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: const BoxDecoration(color: AppColors.tealBg, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Icon(icon, color: AppColors.tealPrimary),
          ),
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
          const Icon(Icons.chevron_right, color: AppColors.textMuted),
        ],
      ),
    );
  }
}
