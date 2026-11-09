import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_failure.dart';
import '../state/app_state.dart';

/// Setup/recovery is explicit; checking readiness never creates a profile.
class BackendProfileBanner extends StatelessWidget {
  const BackendProfileBanner(
      {super.key, required this.onCompleteProfile, required this.onSignIn});
  final VoidCallback onCompleteProfile;
  final VoidCallback onSignIn;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    if (!app.userProfile.isSignedIn ||
        (app.backendProfile?.profileReady == true &&
            app.backendProfileError == null &&
            !app.checkingBackendProfile)) {
      return const SizedBox.shrink();
    }
    final error = app.backendProfileError;
    final errorMessage = error?.kind == ApiFailureKind.conflict
        ? 'Your sign-in identity conflicts with its linked SafeCircle profile. Contact support; no accounts were relinked.'
        : error?.message;
    final missing = app.backendProfile?.profileReady == false;
    return Card(
        margin: const EdgeInsets.all(12),
        child: Padding(
            padding: const EdgeInsets.all(12),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(app.checkingBackendProfile
                  ? 'Checking your SafeCircle account…'
                  : error != null
                      ? 'Account check failed. $errorMessage'
                      : missing
                          ? 'Complete Personal Details, including your city, to finish SafeCircle setup and use Connections.'
                          : 'Check your SafeCircle account setup.'),
              if (app.checkingBackendProfile)
                const LinearProgressIndicator(
                    semanticsLabel: 'Checking account')
              else
                Wrap(spacing: 8, children: [
                  if (error?.kind == ApiFailureKind.authentication)
                    TextButton(
                        onPressed: onSignIn, child: const Text('Sign in again'))
                  else ...[
                    if (missing)
                      TextButton(
                          onPressed: onCompleteProfile,
                          child: const Text('Complete Personal Details')),
                    TextButton(
                        onPressed: app.checkBackendProfile,
                        child: const Text('Retry account check')),
                  ]
                ]),
            ])));
  }
}
