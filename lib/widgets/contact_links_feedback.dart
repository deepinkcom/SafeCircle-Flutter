import 'package:flutter/material.dart';

import '../services/api_failure.dart';
import '../state/contact_links_state.dart';
import '../theme/app_colors.dart';

/// Shared presentation only: all relationship data and requests remain in state.
class ContactLinksNotice extends StatelessWidget {
  const ContactLinksNotice({
    super.key,
    required this.message,
    this.onRefresh,
    this.isError = false,
    this.actionLabel = 'Refresh connections',
  });

  final String message;
  final VoidCallback? onRefresh;
  final bool isError;
  final String actionLabel;

  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        child: Card(
          color: isError ? AppColors.redAlertLight : AppColors.tealBg,
          elevation: 0,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(message),
              if (onRefresh != null)
                TextButton.icon(
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh),
                  label: Text(actionLabel),
                ),
            ]),
          ),
        ),
      );
}

class ContactLinksAccessPanel extends StatefulWidget {
  const ContactLinksAccessPanel({
    super.key,
    required this.state,
    required this.onSignIn,
    required this.onCompleteProfile,
  });

  final ContactLinksState state;
  final Future<void> Function() onSignIn;
  final Future<void> Function() onCompleteProfile;

  @override
  State<ContactLinksAccessPanel> createState() =>
      _ContactLinksAccessPanelState();
}

class _ContactLinksAccessPanelState extends State<ContactLinksAccessPanel> {
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(() =>
            _error = 'Could not complete account recovery. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _profile() async {
    final session = widget.state.sessionVersion;
    await widget.onCompleteProfile();
    if (mounted && widget.state.sessionVersion == session) {
      await widget.state.retryAccess();
    }
  }

  Future<void> _retry() async {
    await widget.state.retryAccess();
  }

  @override
  Widget build(BuildContext context) {
    final signIn = widget.state.needsAuthentication;
    final profile = widget.state.needsBackendProfile;
    final readError = widget.state.incoming.error ??
        widget.state.outgoing.error ??
        widget.state.accepted.error;
    return Card(
      color: AppColors.tealBg,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
              signIn
                  ? 'Sign in to manage connections'
                  : profile
                      ? 'Check your SafeCircle profile'
                      : 'Restore connection access',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(signIn
              ? 'Your session needs attention. Sign in again to continue.'
              : profile
                  ? 'Complete your name, phone and city in Profile > Personal Details, then save to synchronize your account. Return here after saving.'
                  : readError?.message ??
                      'Checking account access. Retry if the connection was interrupted.'),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy
                ? null
                : () => _run(signIn
                    ? widget.onSignIn
                    : profile
                        ? _profile
                        : _retry),
            child: Text(signIn
                ? 'Sign in again'
                : profile
                    ? 'Complete or sync profile'
                    : 'Retry access'),
          ),
          if (profile && !signIn)
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                        await widget.state.retryAccess();
                      }),
              child: const Text('Retry access'),
            ),
          if (_busy)
            const LinearProgressIndicator(
                semanticsLabel: 'Recovering account access'),
          if (_error != null)
            Text(_error!, style: const TextStyle(color: AppColors.redAlert)),
        ]),
      ),
    );
  }
}

String? contactLinkActionMessage(
        ContactLinkMutationResult result, String success) =>
    switch (result.outcome) {
      ContactLinkMutationOutcome.stale => null,
      ContactLinkMutationOutcome.succeeded => result.refreshError != null
          ? '$success Could not refresh all lists. Refresh to update.'
          : !result.refreshSucceeded
              ? '$success Refresh to get the latest updates.'
              : success,
      ContactLinkMutationOutcome.uncertain => result.refreshSucceeded
          ? 'The request outcome was uncertain. Connections were refreshed; check their status before trying again.'
          : 'The request outcome is uncertain. Refresh connections before trying again.',
      ContactLinkMutationOutcome.blocked => result.error?.kind ==
              ApiFailureKind.conflict
          ? 'An invitation or connection already exists, or its status has changed. Refresh to check.'
          : 'An action is pending. Wait or refresh connections before trying again.',
      ContactLinkMutationOutcome.failed => result.error?.message ??
          'Could not update this connection. Please try again.',
    };

String? contactLinkMutationWarning(ContactLinkMutationState state) {
  if (state.requiresRefresh) {
    return 'The request outcome is uncertain. Refresh connections before trying again.';
  }
  if (state.error != null) return state.error!.message;
  if (state.refreshError != null) {
    return 'Your change was saved, but the lists could not be refreshed.';
  }
  return null;
}
