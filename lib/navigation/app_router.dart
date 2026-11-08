import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../screens/activate_panic_screen.dart';
import '../screens/alert_history_screen.dart';
import '../screens/contacts_screen.dart';
import '../screens/contact_links_screen.dart';
import '../screens/invite_contact_screen.dart';
import '../screens/notifications_screen.dart';
import '../models/app_notification.dart';
import '../services/api_failure.dart';
import '../services/location_service.dart';
import '../screens/create_account_screen.dart';
import '../screens/emergency_active_screen.dart';
import '../screens/emergency_nearby_screen.dart';
import '../screens/home_screen.dart';
import '../screens/login_screen.dart';
import '../screens/profile_screen.dart';
import '../screens/welcome_screen.dart';
import '../state/app_state.dart';
import '../services/notification_service.dart';
import '../firebase_bootstrap.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/bottom_nav.dart';
import '../widgets/top_brand_bar.dart';
import '../widgets/real_map.dart';

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
  bool _notificationRegistrationAttempted = false;
  String? _registeredNotificationUser;
  int? _pendingNotification;

  Future<void>? _initialData;
  final NotificationService _notificationService = NotificationService();

  Future<void> _registerNotificationsSafely() async {
    final uid = context.read<AppState>().userProfile.uid;
    if (_registeredNotificationUser != uid) {
      _notificationRegistrationAttempted = false;
      _registeredNotificationUser = uid;
    }
    _notificationService.bindUser(uid);
    _notificationService.onInboxChanged = () {
      if (mounted) context.read<AppState>().notifications.refresh();
    };
    _notificationService.onNotificationTap = (id) {
      if (mounted) setState(() => _pendingNotification = id);
    };
    if (!FirebaseBootstrap.isReady) {
      debugPrint('Firebase not ready; notification setup skipped.');
      return;
    }

    try {
      await _notificationService.startForegroundListener();
      await _notificationService.handleNotificationTaps();
      debugPrint('Notification listeners started.');
    } catch (error) {
      debugPrint('Notification listener setup skipped: $error');
    }

    if (_notificationRegistrationAttempted) return;
    _notificationRegistrationAttempted = true;

    try {
      final settings = await _notificationService.requestPermission();
      final status = settings.authorizationStatus;

      if (status != AuthorizationStatus.authorized &&
          status != AuthorizationStatus.provisional) {
        debugPrint('Notifications not enabled; device registration skipped.');
        return;
      }

      await _notificationService.registerDevice();
      debugPrint('Notification device registration completed.');
    } catch (error) {
      // Backend registration failures must not block notification setup.
      debugPrint('Notification registration skipped: $error');
    }
  }

  _AuthScreen _screen = _AuthScreen.welcome;

  void _enterMain() {
    if (!mounted) return;
    _initialData = _loadContacts();
    setState(() => _screen = _AuthScreen.loggedIn);
  }

  Future<void> _leaveMain({bool signInAgain = false}) async {
    _notificationService.bindUser(null);
    await _notificationService.detachDevice();
    if (!mounted) return;
    _pendingNotification = null;
    _notificationRegistrationAttempted = false;
    await context.read<AppState>().logOut();
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    Navigator.of(context).popUntil((route) => route.isFirst);
    setState(
        () => _screen = signInAgain ? _AuthScreen.login : _AuthScreen.welcome);
  }

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  Future<void> _restoreSession() async {
    final restored = await context.read<AppState>().restoreSession();
    if (!mounted || !restored) return;
    await _registerNotificationsSafely();
    if (!mounted) return;
    _enterMain();
  }

  Future<void> _loadContacts() async {
    final appState = context.read<AppState>();

    try {
      await appState.loadContacts();
    } catch (error, stackTrace) {
      debugPrint('Failed to load contacts: $error');
      debugPrint('$stackTrace');
    }

    try {
      await appState.loadAlertHistory();
    } catch (error, stackTrace) {
      debugPrint('Failed to load alert history: $error');
      debugPrint('$stackTrace');
    }

    try {
      await appState.loadCurrentLocation();
    } catch (error, stackTrace) {
      debugPrint('Failed to load current location: $error');
      debugPrint('$stackTrace');
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (_screen) {
      case _AuthScreen.welcome:
        return WelcomeScreen(
          onGetStarted: () =>
              setState(() => _screen = _AuthScreen.createAccount),
          onLogIn: () => setState(() => _screen = _AuthScreen.login),
        );
      case _AuthScreen.login:
        return LoginScreen(
          onLogIn: (email, password) async {
            final error = await context.read<AppState>().logIn(
                  email: email,
                  password: password,
                );
            if (!mounted || error != null) return error;
            await _registerNotificationsSafely();
            _enterMain();
            return null;
          },
          onCreateAccount: () =>
              setState(() => _screen = _AuthScreen.createAccount),
        );
      case _AuthScreen.createAccount:
        return CreateAccountScreen(
          onBack: () => setState(() => _screen = _AuthScreen.welcome),
          onCreateAccount: ({
            required String fullName,
            required String email,
            required String phone,
            required String password,
          }) async {
            final error = await context.read<AppState>().signUp(
                  fullName: fullName,
                  email: email,
                  phone: phone,
                  password: password,
                );
            if (!mounted || error != null) return error;
            await _registerNotificationsSafely();
            _enterMain();
            return null;
          },
          onLogIn: () => setState(() => _screen = _AuthScreen.login),
        );

      case _AuthScreen.loggedIn:
        debugPrint('AUTH: loggedIn screen reached');

        return FutureBuilder<void>(
          future: _initialData,
          builder: (context, snapshot) {
            return _MainShell(
              notificationService: _notificationService,
              pendingNotification: _pendingNotification,
              onNotificationHandled: () {
                if (mounted) setState(() => _pendingNotification = null);
              },
              onLogOut: () => _leaveMain(),
              onSignInAgain: () => _leaveMain(signInAgain: true),
            );
          },
        );
    }
  }
}

class _MapTab extends StatelessWidget {
  const _MapTab({
    required this.onActivatePanic,
  });

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
                  Text('Map',
                      style: Theme.of(context).textTheme.headlineMedium),
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
                    child: const RealMap(),
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
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28)),
                  ),
                  icon: const Icon(Icons.warning_rounded, size: 18),
                  label: const Text('Activate Panic Alert',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
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
  const _MainShell(
      {required this.onLogOut,
      required this.onSignInAgain,
      required this.notificationService,
      this.pendingNotification,
      required this.onNotificationHandled});
  final NotificationService notificationService;
  final int? pendingNotification;
  final VoidCallback onNotificationHandled;

  final VoidCallback onLogOut;
  final Future<void> Function() onSignInAgain;

  @override
  State<_MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<_MainShell> with WidgetsBindingObserver {
  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<AppState>().notifications.refreshCount();
        _consumePush();
      }
    });
  }

  @override
  void didUpdateWidget(covariant _MainShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pendingNotification != null &&
        widget.pendingNotification != oldWidget.pendingNotification) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _consumePush();
      });
    }
  }

  void _consumePush() {
    final id = widget.pendingNotification;
    if (id == null) return;
    widget.onNotificationHandled();
    _openNotifications(notificationId: id);
  }

  Future<void> _notificationSettings() async {
    try {
      final allowed = await widget.notificationService.permissionGranted();
      if (!mounted) return;
      final enable = await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
                  title: const Text('Device notification permission'),
                  content: Text(allowed
                      ? 'Android allows notifications. Change this permission in Android app settings. This is not an account-wide notification preference.'
                      : 'Android notification permission is not granted. You can request permission or change it in app settings.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialog, false),
                        child: const Text('Open app settings')),
                    FilledButton(
                        onPressed: () => Navigator.pop(dialog, true),
                        child: const Text('Request permission'))
                  ]));
      if (enable == true) {
        await widget.notificationService.requestPermission();
        if (await widget.notificationService.permissionGranted()) {
          await widget.notificationService.registerDevice();
        }
      } else if (enable == false) {
        await LocationService().openAppSettings();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Could not update notification permission. Please try again.')));
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      context.read<AppState>().notifications.refreshCount();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _openNotifications({int? notificationId}) async {
    final state = context.read<AppState>().notifications;
    final session = state.sessionVersion;
    await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (originContext) => ChangeNotifierProvider.value(
            value: state,
            child: NotificationsScreen(
                initialNotificationId: notificationId,
                onOpen: (item) => _openNotificationSource(item,
                    originIsCurrent: () =>
                        originContext.mounted &&
                        (ModalRoute.of(originContext)?.isCurrent ?? false)),
                onSignIn: widget.onSignInAgain,
                onCompleteProfile: _openConnectionProfile))));
    if (mounted && state.sessionVersion == session) await state.refreshCount();
  }

  Future<String?> _openNotificationSource(AppNotification item,
      {required bool Function() originIsCurrent}) async {
    final navigator = Navigator.of(context);
    final app = context.read<AppState>();
    final state = app.notifications;
    final session = state.sessionVersion;
    var resolving = true;
    bool current() =>
        mounted &&
        state.sessionVersion == session &&
        !state.isAccessBlocked &&
        (!resolving || originIsCurrent());
    try {
      if (item.category == NotificationCategory.connection) {
        final links = app.contactLinks;
        final refreshed = await links.refresh();
        if (!current()) return null;
        if (!refreshed.succeeded) {
          if (refreshed.error != null) {
            state.reportAccessFailure(refreshed.error!);
          }
          return refreshed.error?.message ??
              'Could not check this invitation. Refresh and try again.';
        }
        final received = links.incoming.items.any((n) => n.id == item.sourceId);
        final accepted = links.accepted.items.any((n) => n.id == item.sourceId);
        final sent = links.outgoing.items.any((n) => n.id == item.sourceId);
        resolving = false;
        await navigator.push<void>(MaterialPageRoute(
            builder: (_) => ChangeNotifierProvider.value(
                value: links,
                child: ContactLinksScreen(
                    initialView: received
                        ? 1
                        : accepted
                            ? 0
                            : sent
                                ? 2
                                : 0,
                    notice: received || accepted || sent
                        ? null
                        : 'This invitation is no longer available. Current connections are shown.',
                    onInvite: _openInvite,
                    onSignIn: widget.onSignInAgain,
                    onCompleteProfile: _openConnectionProfile))));
      } else if (item.category == NotificationCategory.emergency) {
        final history = await app.loadNotificationAlertHistory(item.sourceId);
        if (!current()) return null;
        if (history) {
          resolving = false;
          await navigator.push<void>(MaterialPageRoute(
              builder: (_) =>
                  AlertHistoryScreen(notificationSession: session)));
        } else {
          final alert = await app.findNotificationNearbyAlert(item.sourceId);
          if (!current()) return null;
          if (alert == null) {
            return 'This emergency alert is unavailable, resolved, or outside your accessible nearby alerts.';
          }
          resolving = false;
          await navigator.push<void>(MaterialPageRoute(
              builder: (destinationContext) => EmergencyNearbyScreen(
                  notificationAlert: alert,
                  notificationSession: session,
                  onBack: () => navigator.pop(),
                  onImOnMyWay: () async {
                    if (!current() ||
                        !destinationContext.mounted ||
                        !(ModalRoute.of(destinationContext)?.isCurrent ??
                            false)) {
                      return;
                    }
                    await app.acknowledgeNearbyAlert(
                        notificationAlert: alert, notificationSession: session);
                    if (current() &&
                        destinationContext.mounted &&
                        (ModalRoute.of(destinationContext)?.isCurrent ??
                            false)) {
                      navigator.pop();
                    }
                  })));
        }
      } else {
        return 'This notification type is not supported yet.';
      }
      return null;
    } on ApiFailure catch (failure) {
      if (!current()) return null;
      state.reportAccessFailure(failure);
      return failure.message;
    } catch (_) {
      return current()
          ? 'Could not check this notification source. Check your connection and location permission, then try again.'
          : null;
    }
  }

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
          onImOnMyWay: () async {
            await context.read<AppState>().acknowledgeNearbyAlert();
            if (!mounted) return;
            Navigator.of(context).pop();
          },
        ),
      ),
    );
  }

  void _openContacts() {
    context.read<AppState>().notifications.refreshCount();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ContactsScreen(
            onBack: () => Navigator.of(context).pop(),
            onOpenNotifications: _openNotifications,
            onOpenConnections: _openConnections),
      ),
    );
  }

  Future<void> _openConnectionProfile() async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('Account recovery')),
        body: ProfileScreen(
            onOpenContacts: _openContacts,
            onLogOut: widget.onLogOut,
            onOpenNotifications: _openNotifications,
            onNotificationSettings: _notificationSettings),
      ),
    ));
  }

  Future<void> _openInvite() async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => ChangeNotifierProvider.value(
        value: context.read<AppState>().contactLinks,
        child: InviteContactScreen(
            onSignIn: widget.onSignInAgain,
            onCompleteProfile: _openConnectionProfile),
      ),
    ));
  }

  void _openConnections() {
    Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => ChangeNotifierProvider.value(
        value: context.read<AppState>().contactLinks,
        child: ContactLinksScreen(
            onInvite: _openInvite,
            onSignIn: widget.onSignInAgain,
            onCompleteProfile: _openConnectionProfile),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final tabs = <Widget>[
      HomeScreen(
        onActivatePanic: _openActivatePanic,
        onOpenContacts: _openContacts,
        onOpenAlerts: _openEmergencyNearby,
        onOpenNotifications: _openNotifications,
      ),
      EmergencyNearbyScreen(
        onBack: () => setState(() => _tabIndex = 0),
        onImOnMyWay: () async {
          await context.read<AppState>().acknowledgeNearbyAlert();
          if (!mounted) return;
          setState(() => _tabIndex = 0);
        },
      ),
      _MapTab(
        onActivatePanic: _openActivatePanic,
      ),
      const AlertHistoryScreen(),
      ProfileScreen(
          onOpenContacts: _openContacts,
          onLogOut: widget.onLogOut,
          onOpenNotifications: _openNotifications,
          onNotificationSettings: _notificationSettings),
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
