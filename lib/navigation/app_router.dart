import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../screens/activate_panic_screen.dart';
import '../screens/alert_history_screen.dart';
import '../screens/contacts_screen.dart';
import '../screens/create_account_screen.dart';
import '../screens/emergency_active_screen.dart';
import '../screens/emergency_nearby_screen.dart';
import '../screens/home_screen.dart';
import '../screens/login_screen.dart';
import '../screens/profile_screen.dart';
import '../screens/welcome_screen.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/bottom_nav.dart';
import '../widgets/mock_map.dart';
import '../widgets/top_brand_bar.dart';

/// Top-level app flow. Auth screens (welcome/login/create account) push on
/// top of a root [Navigator]; once "logged in", [_MainShell] takes over and
/// owns its own bottom-tab navigation plus the emergency flow.
class SafeCircleApp extends StatelessWidget {
  const SafeCircleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SafeCircle',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      home: const _AuthFlow(),
    );
  }
}

class _AuthFlow extends StatefulWidget {
  const _AuthFlow();

  @override
  State<_AuthFlow> createState() => _AuthFlowState();
}

enum _AuthScreen { welcome, login, createAccount, loggedIn }

class _AuthFlowState extends State<_AuthFlow> {
  _AuthScreen _screen = _AuthScreen.welcome;

  @override
  Widget build(BuildContext context) {
    switch (_screen) {
      case _AuthScreen.welcome:
        return WelcomeScreen(
          onGetStarted: () => setState(() => _screen = _AuthScreen.createAccount),
          onLogIn: () => setState(() => _screen = _AuthScreen.login),
        );
      case _AuthScreen.login:
        return LoginScreen(
          onLogIn: () => setState(() => _screen = _AuthScreen.loggedIn),
          onCreateAccount: () => setState(() => _screen = _AuthScreen.createAccount),
        );
      case _AuthScreen.createAccount:
        return CreateAccountScreen(
          onBack: () => setState(() => _screen = _AuthScreen.welcome),
          onCreateAccount: (name) {
            context.read<AppState>().setName(name);
            setState(() => _screen = _AuthScreen.loggedIn);
          },
          onLogIn: () => setState(() => _screen = _AuthScreen.login),
        );
      case _AuthScreen.loggedIn:
        return _MainShell(onLogOut: () => setState(() => _screen = _AuthScreen.welcome));
    }
  }
}

class _MapTab extends StatelessWidget {
  const _MapTab({required this.onActivatePanic});

  final VoidCallback onActivatePanic;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.isEmergencyActive) {
      return EmergencyActiveScreen(
        onBack: () {},
        onImSafe: () => context.read<AppState>().resolveEmergency(),
      );
    }
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
                  Text('Map', style: Theme.of(context).textTheme.headlineMedium),
                  const Text('No active emergency right now.',
                      style: TextStyle(color: AppColors.textMuted)),
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
                    child: const MockRouteMap(),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton.icon(
                  onPressed: onActivatePanic,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.redAlert,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                  ),
                  icon: const Icon(Icons.warning_rounded, size: 18),
                  label: const Text('Activate Panic Alert',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
class _MainShell extends StatefulWidget {
  const _MainShell({required this.onLogOut});

  final VoidCallback onLogOut;

  @override
  State<_MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<_MainShell> {
  int _tabIndex = 0;

  void _openActivatePanic() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ActivatePanicScreen(
          onBack: () => Navigator.of(context).pop(),
          onAlertSent: () async {
            final state = context.read<AppState>();
            await state.startEmergency();
            if (!mounted) return;
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (_) => EmergencyActiveScreen(
                  onBack: () => Navigator.of(context).pop(),
                  onImSafe: () async {
                    await context.read<AppState>().resolveEmergency();
                    if (!mounted) return;
                    Navigator.of(context).popUntil((route) => route.isFirst);
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  void _openEmergencyNearby() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EmergencyNearbyScreen(
          onBack: () => Navigator.of(context).pop(),
          onImOnMyWay: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  void _openContacts() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ContactsScreen(onBack: () => Navigator.of(context).pop()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabs = <Widget>[
      HomeScreen(
        onActivatePanic: _openActivatePanic,
        onOpenContacts: _openContacts,
        onOpenAlerts: _openEmergencyNearby,
      ),
      EmergencyNearbyScreen(
        onBack: () => setState(() => _tabIndex = 0),
        onImOnMyWay: () => setState(() => _tabIndex = 0),
      ),
      _MapTab(onActivatePanic: _openActivatePanic),
      const AlertHistoryScreen(),
      ProfileScreen(onOpenContacts: _openContacts, onLogOut: widget.onLogOut),
    ];

    return Scaffold(
      body: IndexedStack(index: _tabIndex, children: tabs),
      bottomNavigationBar: SafeCircleBottomNav(
        currentIndex: _tabIndex,
        onTap: (i) => setState(() => _tabIndex = i),
      ),
    );
  }
}
