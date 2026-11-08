import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import '../services/location_service.dart';
import '../services/notification_service.dart';
import '../theme/app_colors.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen(
      {super.key,
      required this.onGetStarted,
      required this.onLogIn,
      this.locationService,
      this.notificationService});

  final VoidCallback onGetStarted;
  final VoidCallback onLogIn;
  final LocationService? locationService;
  final NotificationService? notificationService;

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  late final LocationService _location;
  late final NotificationService _notifications;
  bool _busy = false;
  String? _locationMessage;
  String? _notificationMessage;
  LocationAccess? _locationAccess;
  bool _notificationDenied = false;
  String? _settingsError;

  @override
  void initState() {
    super.initState();
    _location = widget.locationService ?? LocationService();
    _notifications = widget.notificationService ?? NotificationService();
  }

  Future<void> _enableLocation() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _settingsError = null;
    });
    try {
      final access = await _location.requestPermission();
      if (!mounted) return;
      setState(() {
        _locationAccess = access;
        _locationMessage = switch (access) {
          LocationAccess.granted => 'Location permission is enabled.',
          LocationAccess.denied =>
            'Location permission was denied. Tap Enable location to try again.',
          LocationAccess.deniedForever =>
            'Location permission is blocked. Enable it in app settings, then try again.',
          LocationAccess.servicesDisabled =>
            'Location services are off. Turn them on, then tap Enable location again.',
        };
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _locationAccess = null;
          _locationMessage =
              'Could not request location permission. Please try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _enableNotifications() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _settingsError = null;
    });
    try {
      // Only request permission: no device registration, listeners or delivery changes.
      final settings = await _notifications.requestPermission();
      if (!mounted) return;
      setState(() {
        _notificationDenied =
            settings.authorizationStatus == AuthorizationStatus.denied ||
                settings.authorizationStatus ==
                    AuthorizationStatus.deniedPermanently;
        _notificationMessage = switch (settings.authorizationStatus) {
          AuthorizationStatus.authorized =>
            'Notification permission is enabled.',
          AuthorizationStatus.provisional =>
            'Quiet notification permission is enabled.',
          AuthorizationStatus.denied ||
          AuthorizationStatus.deniedPermanently =>
            'Notification permission was denied. You can enable it in app settings.',
          AuthorizationStatus.notDetermined =>
            'Notification permission has not been granted. You can try again.',
        };
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _notificationDenied = false;
          _notificationMessage =
              'Could not request notification permission. Please try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openSettings({required bool location}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _settingsError = null;
    });
    try {
      final opened = await (location
          ? _location.openLocationSettings()
          : _location.openAppSettings());
      if (!opened && mounted) {
        setState(() => _settingsError =
            'Could not open settings. Open your device settings manually, then try again.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _settingsError =
            'Could not open settings. Open your device settings manually, then try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

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
              Image.asset('assets/branding/neon_guardian_shield_original.png',
                  width: 96,
                  height: 96,
                  fit: BoxFit.contain,
                  semanticLabel: 'SafeCircle logo'),
              const SizedBox(height: 16),
              Text('SafeCircle',
                  style: textTheme.headlineLarge?.copyWith(fontSize: 32)),
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
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20)),
                child: Column(
                  children: [
                    _WelcomeRow(
                      icon: Icons.person_add_alt,
                      title: 'Create an account',
                      subtitle: 'Quick and easy sign up to get started.',
                      onTap: widget.onGetStarted,
                    ),
                    const Divider(height: 1, color: AppColors.divider),
                    _WelcomeRow(
                      icon: Icons.location_on,
                      title: 'Enable location',
                      subtitle: 'Helps us connect you with nearby help.',
                      onTap: _busy ? null : _enableLocation,
                    ),
                    if (_locationMessage != null)
                      _permissionFeedback(_locationMessage!,
                          settingsLabel: switch (_locationAccess) {
                            LocationAccess.servicesDisabled =>
                              'Open location settings',
                            LocationAccess.deniedForever => 'Open app settings',
                            _ => null,
                          },
                          locationSettings: _locationAccess ==
                              LocationAccess.servicesDisabled),
                    const Divider(height: 1, color: AppColors.divider),
                    _WelcomeRow(
                      icon: Icons.notifications_active,
                      title: 'Get nearby emergency alerts',
                      subtitle: 'Allow notifications on this device.',
                      onTap: _busy ? null : _enableNotifications,
                    ),
                    const Padding(
                        padding: EdgeInsets.fromLTRB(16, 0, 16, 14),
                        child: Text(
                            'Enabling notification permission does not automatically activate nearby emergency push delivery.')),
                    if (_notificationMessage != null)
                      _permissionFeedback(_notificationMessage!,
                          settingsLabel:
                              _notificationDenied ? 'Open app settings' : null),
                    if (_busy)
                      const Padding(
                          padding: EdgeInsets.all(16),
                          child: LinearProgressIndicator(
                              semanticsLabel:
                                  'Requesting permission or opening settings')),
                    if (_settingsError != null)
                      _permissionFeedback(_settingsError!),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Card(
                color: AppColors.tealBg,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                elevation: 0,
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.verified_user,
                              color: AppColors.tealPrimary),
                          const SizedBox(width: 10),
                          Expanded(
                              child: Text('Your safety, our priority',
                                  style: textTheme.titleMedium)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Your location is only shared during emergencies to connect you with people who can help.',
                        style: textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 8),
                      const Row(
                        children: [
                          Icon(Icons.lock,
                              color: AppColors.tealPrimary, size: 16),
                          SizedBox(width: 6),
                          Expanded(
                              child: Text(
                            'Secure. Private. Only when needed.',
                            style: TextStyle(
                              color: AppColors.tealPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          )),
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
                  onPressed: widget.onGetStarted,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.navyDark,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28)),
                  ),
                  icon: const Icon(Icons.shield, size: 18),
                  label: const Text('Get Started',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('Already have an account? ',
                      style:
                          TextStyle(color: AppColors.textMuted, fontSize: 14)),
                  GestureDetector(
                    onTap: widget.onLogIn,
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

  Widget _permissionFeedback(String message,
          {String? settingsLabel, bool locationSettings = false}) =>
      Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          child: Semantics(
              liveRegion: true,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(message),
                    if (settingsLabel != null)
                      TextButton(
                          onPressed: _busy
                              ? null
                              : () => _openSettings(location: locationSettings),
                          child: Text(settingsLabel)),
                  ])));
}

class _WelcomeRow extends StatelessWidget {
  const _WelcomeRow(
      {required this.icon,
      required this.title,
      required this.subtitle,
      required this.onTap});

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
        button: true,
        enabled: onTap != null,
        child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: const BoxDecoration(
                        color: AppColors.tealBg, shape: BoxShape.circle),
                    alignment: Alignment.center,
                    child: Icon(icon, color: AppColors.tealPrimary),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style: Theme.of(context).textTheme.titleMedium),
                        Text(subtitle,
                            style: Theme.of(context).textTheme.bodyMedium),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, color: AppColors.textMuted),
                ],
              ),
            )));
  }
}
