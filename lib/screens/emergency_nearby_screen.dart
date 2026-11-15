import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../models/models.dart';
import '../theme/app_colors.dart';
import '../widgets/real_map.dart';
import '../widgets/safe_circle_mark.dart';

enum _AcknowledgementAccess { allowed, denied, owner, checking, unavailable }

class EmergencyNearbyScreen extends StatefulWidget {
  const EmergencyNearbyScreen({
    super.key,
    required this.onBack,
    required this.onImOnMyWay,
    this.notificationAlert,
    this.notificationSession,
  });

  final VoidCallback onBack;
  final Future<void> Function() onImOnMyWay;
  final NearbyPerson? notificationAlert;
  final int? notificationSession;

  @override
  State<EmergencyNearbyScreen> createState() => _EmergencyNearbyScreenState();
}

class _EmergencyNearbyScreenState extends State<EmergencyNearbyScreen> {
  String? _relationshipsForUid;
  int? _relationshipsForSession;

  @override
  void initState() {
    super.initState();
    if (widget.notificationAlert == null) {
      context.read<AppState>().loadNearbyAlert();
    }
    _ensureAcceptedRelationships(context.read<AppState>());
  }

  void _ensureAcceptedRelationships(AppState state) {
    final uid = state.userProfile.isSignedIn ? state.userProfile.uid : null;
    final links = state.contactLinks;
    final profile = state.backendProfile;
    if (uid == null ||
        links.userId != uid ||
        profile?.profileReady != true ||
        profile?.id == null) {
      return;
    }
    final session = links.sessionVersion;
    if (_relationshipsForUid == uid && _relationshipsForSession == session) {
      return;
    }
    _relationshipsForUid = uid;
    _relationshipsForSession = session;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final current = context.read<AppState>();
      if (current.userProfile.uid != uid ||
          current.contactLinks.sessionVersion != session ||
          current.contactLinks.userId != uid) {
        return;
      }
      current.contactLinks.loadAcceptedRelationships();
    });
  }

  _AcknowledgementAccess _acknowledgementAccess(
      AppState state, NearbyPerson person) {
    final uid = state.userProfile.isSignedIn ? state.userProfile.uid : null;
    final links = state.contactLinks;
    final profile = state.backendProfile;
    if (uid == null || links.userId != uid) {
      return state.checkingBackendProfile
          ? _AcknowledgementAccess.checking
          : _AcknowledgementAccess.unavailable;
    }
    if (profile == null) {
      return state.checkingBackendProfile || state.backendProfileError == null
          ? _AcknowledgementAccess.checking
          : _AcknowledgementAccess.unavailable;
    }
    if (!profile.profileReady || profile.id == null) {
      return _AcknowledgementAccess.unavailable;
    }
    final ownerUserId = person.ownerUserId;
    if (ownerUserId == null || ownerUserId <= 0) {
      return _AcknowledgementAccess.unavailable;
    }
    if (ownerUserId == profile.id) return _AcknowledgementAccess.owner;

    final accepted = links.accepted;
    if (accepted.error != null || links.isAccessBlocked) {
      return _AcknowledgementAccess.unavailable;
    }
    if (accepted.isLoading || !accepted.hasLoaded) {
      return _AcknowledgementAccess.checking;
    }
    return accepted.items
            .any((link) => link.isAccepted && link.otherUserId == ownerUserId)
        ? _AcknowledgementAccess.allowed
        : _AcknowledgementAccess.denied;
  }

  Future<void> _retryRelationshipCheck() async {
    final links = context.read<AppState>().contactLinks;
    if (links.isAccessBlocked) {
      await links.retryAccess();
    } else {
      await links.loadAcceptedRelationships();
    }
  }

  Widget _acknowledgementControl(
      AppState state, _AcknowledgementAccess access) {
    if (access == _AcknowledgementAccess.allowed) {
      return SizedBox(
        width: double.infinity,
        height: 54,
        child: OutlinedButton.icon(
          onPressed: widget.onImOnMyWay,
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: AppColors.tealPrimary),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(28),
            ),
          ),
          icon:
              const Icon(Icons.near_me, color: AppColors.tealPrimary, size: 18),
          label: const Text(
            "I'm On My Way",
            style: TextStyle(
              color: AppColors.tealPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }

    final message = switch (access) {
      _AcknowledgementAccess.owner =>
        'You cannot acknowledge your own emergency alert.',
      _AcknowledgementAccess.denied =>
        'Only accepted emergency contacts can acknowledge this alert.',
      _AcknowledgementAccess.checking =>
        'Checking emergency-contact authorization…',
      _AcknowledgementAccess.unavailable => state
              .contactLinks.needsAuthentication
          ? 'Your session expired. Sign in again to verify access.'
          : state.contactLinks.needsBackendProfile
              ? 'Complete your SafeCircle profile to verify access.'
              : 'We could not verify your emergency-contact access. Please retry.',
      _AcknowledgementAccess.allowed => '',
    };
    return Column(
      children: [
        Text(message, textAlign: TextAlign.center),
        if (access == _AcknowledgementAccess.unavailable &&
            !state.contactLinks.needsAuthentication)
          TextButton(
            onPressed: _retryRelationshipCheck,
            child: const Text('Retry access check'),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    _ensureAcceptedRelationships(state);
    final person = widget.notificationAlert == null
        ? state.nearbyPerson
        : state.notifications.sessionVersion == widget.notificationSession
            ? widget.notificationAlert
            : null;
    final textTheme = Theme.of(context).textTheme;

    if (person == null) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.check_circle_outline,
                    color: AppColors.tealPrimary,
                    size: 72,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    widget.notificationAlert != null
                        ? 'This emergency alert is unavailable'
                        : 'No nearby emergencies detected',
                    textAlign: TextAlign.center,
                    style: textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    widget.notificationAlert != null
                        ? 'It may have been resolved or you may no longer have access.'
                        : 'There are no active emergency alerts '
                            'near your current location.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: widget.onBack,
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('Back to Home'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

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

              // Emergency alert banner
              Container(
                width: double.infinity,
                color: AppColors.redAlert,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 16,
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.report_problem,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.notificationAlert == null
                              ? 'Emergency Nearby'
                              : 'Connection Emergency',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 18,
                          ),
                        ),
                        Text(
                          widget.notificationAlert == null
                              ? 'Someone near you needs help'
                              : 'Your connection needs help',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // SafeCircle branding
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    const SafeCircleMark(size: 28),
                    const SizedBox(width: 8),
                    Text(
                      'SafeCircle',
                      style: textTheme.titleMedium,
                    ),
                    const Spacer(),
                    const Icon(
                      Icons.notifications,
                      color: AppColors.navyDark,
                    ),
                  ],
                ),
              ),

              // Emergency heading
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.notificationAlert == null
                          ? 'Someone nearby\nneeds your help'
                          : 'Your SafeCircle connection\nneeds your help',
                      style: textTheme.headlineMedium?.copyWith(
                        fontSize: 26,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Your help can make a difference.',
                      style: TextStyle(
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 18),

              // Emergency location card
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: Container(
                            height: 150,
                            color: const Color(0xFFE7EEF1),

                            // Real GPS map
                            child: RealMap(
                              nearbyPerson: person,
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: const BoxDecoration(
                                color: AppColors.redAlertLight,
                                shape: BoxShape.circle,
                              ),
                              alignment: Alignment.center,
                              child: const Icon(
                                Icons.person,
                                color: AppColors.redAlert,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                person.name,
                                style: textTheme.titleLarge,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: _InfoLine(
                            icon: Icons.location_on,
                            text: person.distanceLabel,
                            color: AppColors.tealPrimary,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: _InfoLine(
                            icon: person.hasValidLocation
                                ? Icons.check_circle
                                : Icons.location_off,
                            text: person.hasValidLocation
                                ? 'Emergency location available'
                                : 'Emergency location unavailable',
                            color: person.hasValidLocation
                                ? AppColors.tealPrimary
                                : AppColors.redAlert,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: _InfoLine(
                            icon: Icons.access_time,
                            text: 'Reported: '
                                '${MaterialLocalizations.of(context).formatTimeOfDay(
                              TimeOfDay.fromDateTime(
                                person.createdAt.toLocal(),
                              ),
                            )}',
                            color: AppColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // Action buttons
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: [
                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          if (!person.hasValidLocation) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Emergency location is '
                                  'not available yet.',
                                ),
                              ),
                            );
                            return;
                          }

                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (context) => Scaffold(
                                appBar: AppBar(
                                  title: const Text(
                                    'Emergency Location',
                                  ),
                                ),
                                body: SafeArea(
                                  child: RealMap(
                                    nearbyPerson: person,
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.navyDark,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(28),
                          ),
                        ),
                        icon: const Icon(
                          Icons.location_on,
                          size: 18,
                        ),
                        label: const Text(
                          'View Live Location',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
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
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(28),
                          ),
                        ),
                        icon: const Icon(
                          Icons.call,
                          size: 18,
                        ),
                        label: const Text(
                          'Call Emergency Services',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    _acknowledgementControl(
                      state,
                      _acknowledgementAccess(state, person),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 18),

              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Icon(
                      Icons.verified_user,
                      color: AppColors.tealPrimary,
                      size: 18,
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Your location is only shared '
                        'during emergencies.',
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    Text(
                      'Learn more',
                      style: TextStyle(
                        color: AppColors.tealPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
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
  const _InfoLine({
    required this.icon,
    required this.text,
    required this.color,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          color: color,
          size: 16,
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}
