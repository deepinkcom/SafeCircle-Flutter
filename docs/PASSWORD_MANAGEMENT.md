# Password management

The login screen's Forgot Password control opens Reset Password with the login
email prefilled. It validates the email and calls Firebase Authentication's
`sendPasswordResetEmail`. The user follows Firebase's emailed link to its hosted
password reset page, chooses a new password, then returns to SafeCircle to log in.
No custom action URL or deep-link setup is required by this implementation.

Confirmation deliberately does not disclose account existence. Firebase
`user-not-found` receives the same confirmation as an accepted request. Network
and rate-limit errors remain retryable. Duplicate taps are blocked while pending;
a completed form directs the user back to login rather than repeatedly sending.
Google-only users are directed to manage their password in their Google Account.

Profile & Settings > Change Password opens a dedicated screen. Email/password
users enter their current password, new password, and matching confirmation.
The app reauthenticates with the current password, checks that the Firebase user
and application session are unchanged, then calls `updatePassword` on that user.
The local minimum is six characters; Firebase enforces the configured password
policy and stronger-policy failures receive guidance. Passwords are not trimmed.
Google-only accounts get guidance instead of a password form; no password
credential is silently added to those accounts.

The operation is scoped to the signed-in UID. It does not write to Firestore or
the backend database, change contacts or notification registrations, or introduce
password logging/storage. Password controllers are cleared after a confirmed
update and disposed when the screen closes. No new dependencies are needed.

## Verification

Tests use fake Firebase users and synthetic passwords, covering reset validation,
unknown-address privacy, errors, reauthentication order, wrong current password,
Google-only accounts, Firebase password-policy rejection, session/account changes,
duplicate submissions, navigation, matching confirmation, and success states.
Flutter analysis passed with no issues, the focused checks passed all 39 tests,
and the complete Flutter suite passed all 476 tests (including 16 new password
flow tests).

On 2026-11-19, the user separately authorized one live reset-email request to a
provided test address. Firebase accepted that request (HTTP 200), and the user
confirmed receiving the email. Completion of the reset link and an in-app password
change on a phone remain unverified. No real password was collected or changed by
the agent.

Reference: https://firebase.google.com/docs/auth/flutter/manage-users
