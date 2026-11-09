# Stage 3C.1 / 3D implementation status — 8 November 2026

## Delivered scope

- Login reuses the existing circular branding PNG, preserving proportions.
- Home, Emergency Contacts and Profile bells open the same inbox and use its authenticated unread count.
- Authenticated inbox management: filtered mark-all-read, delete one, clear read and clear all. Destructive bulk operations require confirmation. PostgreSQL soft deletion preserves audit/event uniqueness and never deletes the source relationship or emergency history.
- Connection notification producers enqueue a unique per-device delivery job in the SAME transaction as the relationship and persistent notification. FCM never runs inside that transaction.
- An explicitly started worker leases jobs, sends generic lock-screen text with recipient UID/notification ID, retries transient failures up to five attempts and removes invalid/unregistered tokens. Multiple registered devices are supported. Deleted inbox events are suppressed; they are never recreated by a push.
- Flutter validates the authenticated recipient, refreshes authoritative history/counts, deduplicates foreground alerts and routes taps through the existing protected inbox/source navigation. Notification taps do not accept invitations. Device deregistration/token deletion is attempted before logout; callbacks/session state reject late cross-account results.
- Profile settings expose actual device permission controls, rather than a cosmetic account-wide notification switch. No backend account-wide preference is claimed.

## Explicitly incomplete / not verified

- Profile-photo selection, upload, secure storage and removal are NOT implemented. No existing secure photo infrastructure or image-picker dependency was available; introducing and verifying it safely was deferred. Default avatars remain unchanged.
- Emergency push delivery is NOT implemented. Existing nearby queries do not define a persistent, authorized delivery recipient list. Connection acceptance does not add emergency recipients. Worker explicitly refuses emergency jobs.
- New FCM delivery has NOT been verified on a physical device. Foreground/background/terminated behavior, Android settings denial/re-enable, token renewal, logout/offline account switching and multiple-device delivery require real-device verification.
- Local-notification cold-launch routing remains unverified. Remote FCM initial-message routing is wired after authenticated restoration.
- Delivery is at least once: a crash after provider acceptance can resend a job. Stable Android tags and foreground notification-ID deduplication limit duplicate presentation; exact-once provider delivery is not claimed.
- Offline foreground pushes are not fabricated locally; persistent inbox history remains authoritative and available on the next successful refresh.
- Worker leases/locking require PostgreSQL integration verification; SQLite tests do not establish concurrent PostgreSQL behavior. No Docker containers or development records were touched.

## API extension (Firebase bearer authentication required)

Existing GET list/count and PATCH read endpoints remain compatible.

- `GET /notifications/{id}`: existing notification response or 404 for unavailable/deleted/other-recipient records.
- `POST /notifications/mark-all-read?category=connection`: optional emergency/connection filter; returns `{"affected": 2}`.
- `DELETE /notifications/{id}`: soft delete owned inbox entry; returns `{"affected": 1}`; missing/deleted/other-recipient returns 404.
- `DELETE /notifications?scope=read&category=connection`: required scope read/all; optional category; returns affected count.
- `DELETE /devices` with JSON `{"fcm_token":"synthetic-example-only"}` unregisters only the authenticated user's matching device; idempotent success. No token is returned.

## Deployment prerequisite — separate migration approval required

New Alembic revision `c7f0a3e5b921`, parent `b6e9c2d4f810`, adds nullable notification `deleted_at`, a unique FCM-token index and a durable `push_deliveries` table. Existing history is retained. The applied b6 migration is not edited.

DO NOT deploy the changed backend against the old schema. Back up and rehearse the upgrade on an approved isolated PostgreSQL database; check for duplicate device-token rows privately before migration. The migration fails rather than deleting/reassigning conflicting tokens. Obtain separate approval before applying it to development. No live migration was run here.

After approved migration and compatible backend deployment, start from backend directory:

```powershell
python -m app.push_worker
```

Use the existing Firebase Admin credential mechanism and process supervision; never store service-account keys in source. No worker was started in this session and no real push was sent. Existing history is not backfilled into push jobs. New events enqueue only currently registered devices; offline history remains available regardless of delivery. Downgrading drops delivery state and the soft-delete column; it can make hidden rows visible and requires explicit backup/rollback approval.

The existing backend accepts FCM registration tokens. Targeted SDK deprecation suppressions retain that protocol; switching to installation IDs requires a separate protocol migration.

## Verification

Results are recorded in the implementation report. Backend automated tests use isolated SQLite fixtures and synthetic identities/senders, not the development database. Android builds and Flutter tooling use the existing installed SDK. Preserved Stage 3A–3C source, documentation, tests and launcher assets are included in the feature-branch submission; no merge or deployment is performed.


## Fresh automated results

- `flutter analyze --no-pub`: no issues.
- Full `flutter test --no-pub --reporter expanded --concurrency=1`: 369 passed.
- Changed Dart formatting check: 26 files, zero formatting differences.
- Backend `python -m pytest tests -q -p no:cacheprovider`: 269 passed, 688 deprecation warnings (Starlette/httpx and legacy UTC defaults).
- Android ARM64 debug build succeeded: `build/app/outputs/flutter-apk/app-debug.apk` (113,340,595 bytes). Gradle reported existing Kotlin-plugin/native-access/SDK-version compatibility warnings.
- Git whitespace check passed. Changed-file credential/private-key pattern scan reported no matches. No live migration, development data write or real Firebase delivery was performed.

## Files added or changed by this session, relative to the inspected dirty baseline

- `backend/app/devices.py`
- `backend/app/models.py`
- `backend/app/notification_service.py`
- `backend/tests/test_contact_links.py`
- `backend/tests/test_contact_links_migration.py`
- `backend/tests/test_user_search.py`
- `lib/navigation/app_router.dart`
- `lib/screens/login_screen.dart`
- `lib/screens/profile_screen.dart`
- `lib/services/api_service.dart`
- `lib/services/notification_service.dart`
- `backend/NOTIFICATIONS.md`
- `backend/app/notification_events.py`
- `backend/app/notifications.py`
- `backend/app/push_worker.py`
- `backend/migrations/versions/c7f0a3e5b921_notification_management_push.py`
- `backend/tests/test_notifications_migration.py`
- `backend/tests/test_push_management.py`
- `docs/STAGE_3C1_3D_STATUS.md`
- `lib/screens/notifications_screen.dart`
- `lib/state/notifications_state.dart`
- `test/notification_api_test.dart`
- `test/notification_management_push_test.dart`

## Push-delivery retention follow-up

See [Push-delivery retention](PUSH_DELIVERY_RETENTION.md). Revision d9a4f6b2c730
follows c7f0a3e5b921 and preserves delivery rows when registrations are deleted.
The nullable SET NULL device FK, atomic cancellation, generation-fenced worker and
bounded subprocess submission passed 326 backend tests, including 21 PostgreSQL
cases. The approved local migration and compatible API/worker restart were verified
without changing existing application rows. Other environments need separate approval.
Physical Android account-isolation and real FCM retesting are postponed and pending.
Existing emergency policy, Firebase configuration and Flutter routing are unchanged.