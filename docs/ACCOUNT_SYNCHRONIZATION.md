# Firebase / PostgreSQL account readiness and synchronization

Firebase Authentication verifies identity. Firestore stores the existing Flutter profile. PostgreSQL supplies backend user IDs, connections, devices and inbox records. A Firebase account alone is not a discoverable backend profile.

## Authenticated readiness contract

`GET /users/me` uses the existing Firebase bearer mechanism. It verifies the token UID/email and queries that UID only. It performs no writes and returns `Cache-Control: no-store`.

Linked and complete (synthetic example):

```json
{"id":42,"profile_ready":true,"missing_fields":[]}
```

Authenticated but not yet linked:

```json
{"id":null,"profile_ready":false,"missing_fields":["name","phone","city"]}
```

An existing incomplete profile retains its integer ID and lists its missing fields. `401` means missing/invalid identity claims; `409` means the linked profile's email conflicts with the verified identity. Responses contain no email, phone, Firebase UID or unrelated account details.

## Registration, login and restoration

After Firebase authentication and Firestore profile loading, AppState checks readiness. These checks never create a PostgreSQL account or overwrite a linked profile. A missing/incomplete profile gets explicit guidance to Profile > Personal Details, including the required city. Read failures provide retry and expired-session recovery. Profile & Settings shows the authenticated backend account number when available.

Personal Details pre-fills the existing Firestore profile. The user explicitly supplies/validates name, phone and city, then saves via the existing `POST /users/me` contract:

```json
{"name":"Example Member","phone":"0000000000","city":"Example City"}
```

The backend obtains UID and normalized email exclusively from verified token claims; supplying UID/email as JSON is rejected. It does not infer identity from phone/email matching or import Firebase users. It retains the existing response fields (`id`, `firebase_uid`, `name`, `email`, `city`, `phone`) for compatibility.

Existing profiles update only through explicit Personal Details saves. GET checks do not replay possibly stale Firestore fields over PostgreSQL. UID/email conflicts return `409` without relinking. New creation commits transactionally; unique UID/email constraints prevent duplicates. If another request creates the same verified identity first, the losing request returns the winner without overwriting its fields. Existing-profile updates acquire a row lock on PostgreSQL.

After a confirmed save, Flutter checks readiness again. Failed or uncertain sync retains the Firebase session and offers safe account checks and an explicit save retry. Saving is guarded against duplicate submissions. Requests/cache state are versioned by account/session, newer checks supersede older checks, and late completions after logout/account changes/disposal are ignored. A Personal Details dialog opened for a prior account hides its fields and cannot submit them for the new account. Newly completed profiles can retry device registration through the existing notification service; no new push system is introduced.

Firestore and PostgreSQL do not share a distributed transaction: Firestore can save successfully while the API call fails. The UI reports this and retains an explicit retry; it does not claim both stores were committed atomically.

## Discovery and preservation

Search remains an authenticated complete-email lookup, with self-exclusion, one-result limit and fail-closed ambiguity checks. A caller needs a complete backend profile. Targets with missing name/phone/city are not returned or accepted as invitation targets. Existing connections and pending invitations still block duplicate invitations rather than hide search matches.

No migration is needed. The applied migration chain, existing profiles/IDs, connections, notifications, devices, phone contacts, branding and emergency recipient rules are preserved. Tests use synthetic identities and disposable SQLite databases. They cover real unique-constraint conflicts and parallel API requests; they do not establish PostgreSQL lock timing under contention. No live profile is created/updated as part of automated verification.

## Relevant checks

From backend, using the existing test environment and an accessible unique pytest temporary directory:

```powershell
..\.venv-backend-test\Scripts\python.exe -m pytest tests -q -p no:cacheprovider --basetemp <new-temporary-directory>
```

From repository root:

```powershell
flutter analyze --no-pub
flutter test --no-pub --reporter expanded --concurrency=1
flutter build apk --debug --no-pub --target-platform android-arm64
```

Physical-device confirmation of the account-completion flow and subsequent FCM delivery remains a separate manual verification. The development push worker is kept running, and this change does not create fabricated notification events.

## Verified implementation results

- Full Flutter suite: **390 passed** (`flutter test --no-pub --reporter expanded --concurrency=1`).
- Flutter analyzer: **No issues found** (`flutter analyze --no-pub`).
- Dart formatting: **9 changed/new Dart files, zero differences** in the final check.
- Full backend suite: **289 passed**, 713 deprecation warnings (Starlette/httpx and UTC defaults), using isolated SQLite fixtures and synthetic Firebase identities.
- Android ARM64 debug build: **succeeded**, `build/app/outputs/flutter-apk/app-debug.apk`; 113,350,455 bytes. Existing Gradle native-access/Kotlin-plugin compatibility warnings remain.
- Git whitespace check passed; changed-file credential/private-key pattern scan found no matches.
- Read-only comparison to the pre-migration fingerprints confirmed all original field values unchanged for 2 users, 3 connections, 1 registered device and 2 notifications (legacy contacts table remains empty). Development revision remains c7f0a3e5b921.
- Existing push worker remained running and connected, with an empty error log. No worker restart, migration, bulk import, live profile sync, commit, push or deployment was performed.

Changed existing files:

- `backend/app/users.py`
- `backend/app/contact_links.py`
- `lib/services/api_service.dart`
- `lib/state/app_state.dart`
- `lib/navigation/app_router.dart`
- `lib/screens/profile_screen.dart`
- `test/support/contact_links_fakes.dart`

Created files:

- `backend/tests/test_profile_readiness.py`
- `lib/models/backend_profile_status.dart`
- `lib/widgets/backend_profile_banner.dart`
- `test/backend_profile_state_test.dart`
- `test/backend_profile_ui_test.dart`
- `docs/ACCOUNT_SYNCHRONIZATION.md`

The four Firebase-only accounts are deliberately not provisioned by this work. Each account must sign in and explicitly complete Personal Details. Real-device validation of that flow and renewed FCM delivery remains pending review/installation of the new APK. Test databases establish behavior and uniqueness recovery, not production PostgreSQL contention timing.
