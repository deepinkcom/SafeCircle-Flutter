# SafeCircle (Flutter)

A Flutter/Dart rebuild of the SafeCircle safety app, aligned with the
**6.2.1 Suggested Technology Stack**:

| Layer                     | Used here |
|----------------------------|-----------|
| Mobile UI                  | Flutter + Dart (this project) |
| Backend API                | `lib/services/api_service.dart` — stub calls, ready to point at a FastAPI backend |
| Authentication              | `lib/services/auth_service.dart` — Firebase Authentication (email/password) |
| User profiles               | Cloud Firestore `users/{uid}` via `lib/services/user_repository.dart` |
| Database / geo queries      | Called from the backend (PostgreSQL + PostGIS), not from the app directly |
| Push notifications          | `lib/services/notification_service.dart` — stub wrapping Firebase Cloud Messaging |
| Maps & geolocation           | `lib/services/location_service.dart` — stub wrapping device GPS; see "Maps" note below |
| Hosting / DB hosting          | Azure App Service + Azure Database for PostgreSQL (deployment target, not part of this repo) |

Sign-up, sign-in, and profile edits are stored in Firebase (Authentication
for the password, Cloud Firestore for name, email, phone, and city).
Contacts, alerts, and location still go through the other services in
`lib/services/`.

## Screens included

Welcome · Log In · Create Account · Home (press-to-activate Panic button) ·
Activate Panic Alert (hold-to-confirm countdown ring) · Emergency Active
(live route map + "I'm Safe") · Emergency Nearby (another user's alert) ·
Emergency Contacts (add/edit/toggle) · Alert History (All/Sent/Received) ·
Profile & Settings.

## About the map

The stack calls for the `google_maps_flutter` package, which needs a Google
Maps API key to render real tiles. To keep this project runnable with no
external setup, `lib/widgets/mock_map.dart` draws a lightweight
street-grid-and-route mock instead (same visual idea as the design mockups).
Swap it for a real `GoogleMap` widget once you have a key — see the comment
at the top of `mock_map.dart` and `location_service.dart`.

## Setup

1. **Install the Flutter SDK** (stable channel) if it isn't already on your
   machine/VM: https://docs.flutter.dev/get-started/install
   Run `flutter doctor` and resolve anything it flags.
2. **Extract this project**, then from its root run:
   ```
   flutter create .
   ```
   This project ships only `pubspec.yaml` + `lib/` (the portable, reviewable
   part) — running `flutter create .` once adds the `android/`, `ios/`, and
   `web/` platform folders for your installed Flutter/Android SDK versions
   without touching anything in `lib/`. This is the standard way to add
   platforms to an existing Dart-only Flutter package.
3. **Get packages**:
   ```
   flutter pub get
   ```
4. **Open in Android Studio** (with the Flutter/Dart plugins installed) or
   VS Code, and run on an emulator or device — `flutter run`, or the Run
   button.

## Next steps for a production build

- Create a Firebase project, enable Email/Password sign-in and Cloud
  Firestore, then from this folder run `flutterfire configure`. That
  replaces `lib/firebase_options.dart` and adds the platform config files.
- Publish `firestore.rules` (`firebase deploy --only firestore:rules`) so
  each user can read and write only their own `users/{uid}` document.
- Uncomment `google_maps_flutter` and `firebase_messaging` in `pubspec.yaml`
  when maps and push notifications are ready.
- Point `ApiService.baseUrl` at your deployed Azure App Service URL.
