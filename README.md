# SafeCircle (Flutter)

A Flutter/Dart rebuild of the SafeCircle safety app, aligned with the
**6.2.1 Suggested Technology Stack**:

| Layer                     | Used here |
|----------------------------|-----------|
| Mobile UI                  | Flutter + Dart (this project) |
| Backend API                | `lib/services/api_service.dart` — stub calls, ready to point at a FastAPI backend |
| Authentication              | `lib/services/auth_service.dart` — stub wrapping Firebase Authentication |
| Database / geo queries      | Called from the backend (PostgreSQL + PostGIS), not from the app directly |
| Push notifications          | `lib/services/notification_service.dart` — stub wrapping Firebase Cloud Messaging |
| Maps & geolocation           | `lib/services/location_service.dart` — stub wrapping device GPS; see "Maps" note below |
| Hosting / DB hosting          | Azure App Service + Azure Database for PostgreSQL (deployment target, not part of this repo) |

All app data currently lives in memory (`lib/state/app_state.dart`), so the
app is fully clickable with **zero backend setup** — every screen from the
mockups is implemented and wired together. Each service stub documents
exactly what to fill in to connect the real backend later, without needing
to touch the screens themselves.

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

- Uncomment `google_maps_flutter`, `geolocator`, `firebase_core`,
  `firebase_auth`, `firebase_messaging`, and an HTTP client (e.g. `dio`) in
  `pubspec.yaml` as you wire each one in.
- Fill in the four files in `lib/services/` — each already documents the
  intended FastAPI endpoints / Firebase calls.
- Add Firebase config (`google-services.json` / `GoogleService-Info.plist`)
  once you've created a Firebase project for Authentication + Cloud
  Messaging.
- Point `ApiService.baseUrl` at your deployed Azure App Service URL.
