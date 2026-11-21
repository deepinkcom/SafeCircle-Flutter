# Google sign-in

Google sign-in is available on the Android login screen alongside email/password.
It exchanges a Google ID token for a Firebase session; API calls still use Firebase
ID tokens. Existing Firestore profiles are loaded without replacing their details.
New users get a profile with their Google name/email, then complete phone and city
through Personal Details and the existing backend synchronization flow.

Cancellation leaves the login screen open. Account conflicts direct the user to
their existing sign-in method; the app does not merge or relink accounts itself.
Logout retains the existing notification cleanup gate, signs out Firebase, and
clears the local Google session. Explicit Google sign-in permits account selection.
Logs contain stages/codes only, never credentials or provider exception details.

## Firebase Android configuration

The configuration was checked against project `deepinkapp-124a6`, Android package
`com.example.safecircle`, and the existing Firebase app ID before replacing
`android/app/google-services.json`. It includes the web OAuth client needed by the
Google sign-in plugin. On 2026-11-19, Firebase initially had no signing fingerprints
for this app. Following explicit user approval, the laptop's debug SHA-1 and
SHA-256 below were registered and independently verified. The Android configuration
was then downloaded again from Firebase and checked before use.

In Firebase Console > Project settings > Your apps > `com.example.safecircle`,
register the certificate fingerprints for each signing key used to distribute
the app. This laptop's current debug certificate is now registered with:

```text
SHA-1: 0C:13:1C:F8:8B:67:B0:46:1E:DE:68:BE:32:37:C9:4B:91:71:D0:24
SHA-256: EC:EE:A4:00:79:F4:E9:D1:B2:65:59:EF:F8:14:FA:BE:50:EF:C9:DB:25:8B:45:05:FC:5C:8B:A2:2E:A2:C7:95
```

Release currently uses the debug signing key. When production signing or Play App
Signing is introduced, register that certificate too. Download the configuration
again after future signing changes and rebuild. Do not change the application ID
or existing credentials to troubleshoot sign-in.

iOS/macOS Google login is not exposed; their Firebase/OAuth configuration remains
unconfigured. Web uses Firebase popup authentication but still requires a properly
configured web Firebase app and authorized domains.

## Verification

Flutter analysis passed with no issues. All 460 Flutter tests passed, including
10 new Google sign-in tests. The focused authentication/profile/device lifecycle
run passed all 54 tests. These use synthetic identities; they do not authenticate
real accounts or send notifications.

An ARM64 Android debug build also succeeded. It targets the existing Azure API
URL and was not installed or distributed. No backend deployment or migration was
performed.

On a phone, verify chooser cancellation, a new account followed by Personal Details
completion, an existing user's preserved profile, restart/session restoration,
and logout/account selection on the same installation. Actual device sign-in is
still pending. The backend release and migration subsequently completed; see
[the executed release report](PRODUCTION_RELEASE_2026-11-22.md).

References:
- https://firebase.google.com/docs/auth/flutter/federated-auth
- https://pub.dev/packages/google_sign_in
- https://pub.dev/packages/google_sign_in_android
