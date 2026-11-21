> Current production status (22 November 2026): DEPLOYED AND VERIFIED.
> The recovery gate was satisfied, migration `a91b8c7d6e5f` completed, and the
> worker and API are healthy on the approved immutable image. See
> [the executed release report](docs/PRODUCTION_RELEASE_2026-11-22.md).
> Earlier NO-GO statements and preparation commands below are historical.

# SafeCircle coordinated release ? local verification and demonstration

Decision: NO-GO for production until the recovery gate is satisfied. Neither physical phone is claimed fixed. This document supersedes old verification counts/source fingerprints once final results are recorded below.

## Findings and completed local work

Phone A: the new installation-scoped client requires DELETE /devices/installation, absent on the current Azure image. The legacy generic Google Play/connection error still needs a phone trace to identify its exact original exception. Cleanup never bypasses backend confirmation. A stable secure random installation ID, authenticated installation ownership, token rotation, same-installation cleanup, cancellation of pending/sending deliveries, other-phone isolation and idempotency are implemented. Missing endpoint errors explicitly require a server update.

Final review fixed a retry gap: a unique-token insert conflict rolls back an installation claim; the retry now reclaims ownership BEFORE taking the device-token lock. PostgreSQL and SQLite regression cases cover same-owner winners and foreign-account winners. Foreign ownership remains rejected, without token transfer.

Phone B: the exact supplied login text identifies Firebase Auth network-request-failed before profile and API access. It does not establish DNS/TLS/Google-service cause. Android application ID com.example.safecircle, Android client app ID, project deepinkapp-124a6, bucket reference and API key agree between Dart/native configuration/firebase.json; no credential values are logged in the check. Internet permission is present; no custom network-security override was found. Do not change credentials or enable cleartext/weak TLS.

New safe diagnostics distinguish Firebase initialization, Firebase sign-in (including invalid credentials vs network failure), Firestore profile loading, backend profile status and FCM/backend registration. Startup no longer prints raw Firebase exceptions/stack traces, and background notifications no longer log message IDs. Codes/statuses/stages are logged, not user identities, tokens, passwords or coordinates.

Profile photo: image picker limits input to 8 MiB, validates/normalizes to PNG <=2 MiB and strips metadata. Immutable randomized owner paths are stored via Firestore compare-and-set, with authenticated private byte retrieval; no public URL or backend photo upload is introduced. Session guards reject another owner's path before storage access. Storage failures now distinguish auth/rules, missing bucket, quota, timeout, checksum and missing object, and diagnostics identify selection/download/upload/profile-reference stage.
Local Storage and Firestore photo rules are explicitly draft/undeployed; production bucket provisioning and rule permissions were not verified. A configured bucket STRING does not prove a provisioned authorized bucket. No paid service, Firebase rule, bucket or credential changed. Required evidence: actual upload Firebase exception CODE and stage; administrator read-only confirmation of bucket/rules and owner photoStoragePath write access. Do not claim photo upload works until select/upload/restart/download succeeds on a phone.

## Current cloud and recovery gate

Subscription Azure for Students 44750d19-6609-4202-8ffd-316c51ba018c; rg-safecircle-student, South Africa North.
Read-only refresh: API safecircle-api--tm5ge9w and worker safecircle-push-worker--s4xcv7g are Healthy with one replica each. /health=ok; /health/ready=ready. Both images and existing ACR rollback manifest:
safecirclestudentacr.azurecr.io/safecircle-api@sha256:fcf5798d6fb2456afd114bab0588e3ae0933d6a521694e774f71150c9722fbb1.
SELECT-only transaction confirms database safecircle_db at e17d6a10bc25. Target is a91b8c7d6e5f.

Migration is additive: installation ownership table, nullable device installation ID, composite lookup index; legacy rows remain intact/unattributed. No backfill, deletion or production migration occurred. Old API/worker tolerate the added schema; new shared Device ORM requires it first. Backend rollback keeps schema; never automatically downgrade it. Old APK device requests remain accepted; new APK needs the new endpoint. Unknown historical tokens cannot safely be attributed solely from a new installation ID.

Recovery remains BLOCKED under RELEASE_SAFETY_GATE.md and RECOVERY_VERIFICATION_PLAN.md. Seven-day configured backup retention/PITR metadata is not a verified restore. No approved private bulk-export client/transport, encryption/retention evidence, unused transfer allowance or real recovery drill was established. No export/restore/migration is executed. A logical production backup plus verified isolated local restore is the lowest-resource candidate, but needs separate explicit export approval and a proven zero-incremental-cost path (or separately approved charges). Azure PITR would create a paid server and remains prohibited.

## Verification and release snapshot

Final results are appended after the running suites complete. Full application source is frozen during final testing. Final source manifest is release-source-manifest.json; it captures the dirty tree, not just base commit 8afa786cf7b8c02e32307d243191b9499694bd92. No commit/reset/discard operation was used.
Backend build: safecircle-api:combined-local-verification, local manifest-list ID sha256:3af46d3238ee8d7713230c257b84705930e67fad1fa1aae6379f98aa3723e3c7. API/worker imports succeed with a synthetic in-memory database URL, migration head a91b8c7d6e5f and installation endpoint present. Nothing pushed.
Docker context remains backend with explicit COPY of app/, migrations/, requirements.txt, alembic.ini and bootstrap SQL. .env/tests are excluded. Firebase client JSON is outside this context. No private-key markers were found in earlier source review; final scan/snapshot is refreshed after tests.

Previous unrelated dirty work is preserved: My Connections/manual-contact UI removal, real emergency names and GPS, privacy/authorization, acknowledgements, history details/bell, dialler, Profile menu, photo diagnostics, dependency lock and generated desktop registrants. These will be included in a new APK. Previous deployed-image comparison found only devices/models functional backend differences, plus BOM-only test-notification difference; existing emergency backend/worker code already matches deployed image. New retry fix is part of devices.py.

## Exact coordinated release sequence ? commands PREPARED, NOT AUTHORIZED TO EXECUTE

Use RELEASE_SAFETY_GATE.md's exact read-only preflight commands immediately before any future release; require the expected subscription, group, individual image digests, ready replicas, secret references and database parent revision. Read-only probes must not print configuration values or user records.

1. Satisfy the recovery gate first: execute RECOVERY_VERIFICATION_PLAN.md's exact pg_dump/local Docker restore and integrity procedure ONLY after separate production export approval, protected private access and cost verification. Require archive checksum, same-snapshot table contents, constraints/indexes/sequences, Alembic revision and accepted RPO/RTO evidence. No test event or production write.
2. Use the following build/push/migration/deployment commands only after explicit deployment approval AND accepted recovery evidence. Secrets stay in existing protected operator environment; never print them.

```powershell
$ErrorActionPreference = 'Stop'
$rg = 'rg-safecircle-student'
$registry = 'safecirclestudentacr'
$expectedSubscription = '44750d19-6609-4202-8ffd-316c51ba018c'
$account = az account show -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $account.id -ne $expectedSubscription) { throw 'Wrong subscription' }
$expectedRollback = 'safecirclestudentacr.azurecr.io/safecircle-api@sha256:fcf5798d6fb2456afd114bab0588e3ae0933d6a521694e774f71150c9722fbb1'
$apiBefore = az containerapp show -n safecircle-api -g $rg -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'API preflight failed' }
$workerBefore = az containerapp show -n safecircle-push-worker -g $rg -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Worker preflight failed' }
$apiRollback = $apiBefore.properties.template.containers[0].image
$workerRollback = $workerBefore.properties.template.containers[0].image
if ($apiRollback -ne $expectedRollback -or $workerRollback -ne $expectedRollback) { throw 'Unexpected rollback state' }
$tag = 'release-' + (git rev-parse --short HEAD).Trim() + '-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$image = "${registry}.azurecr.io/safecircle-api:$tag"
docker build -f backend/Dockerfile -t $image backend
if ($LASTEXITCODE -ne 0) { throw 'Build failed' }
$login = az acr login --name $registry --expose-token -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'ACR login failed' }
$login.accessToken | docker login "${registry}.azurecr.io" --username 00000000-0000-0000-0000-000000000000 --password-stdin
if ($LASTEXITCODE -ne 0) { throw 'Docker login failed' }
$login = $null
docker push $image
if ($LASTEXITCODE -ne 0) { throw 'Push failed' }
$digest = az acr repository show -n $registry --image "safecircle-api:$tag" --query digest -o tsv
if ($LASTEXITCODE -ne 0 -or $digest -notmatch '^sha256:[0-9a-f]{64}$') { throw 'Manifest verification failed' }
$pinned = "${registry}.azurecr.io/safecircle-api@$digest"
```

From an approved existing private-access operator environment, with the release source and existing protected DATABASE_URL injected, after backup recovery acceptance:

```powershell
Push-Location backend
$env:PGOPTIONS = '-c lock_timeout=5s -c statement_timeout=60s'
python -m alembic current
if ($LASTEXITCODE -ne 0) { throw 'Revision check failed' }
# Require actual database revision e17d6a10bc25 before proceeding.
python -m alembic upgrade a91b8c7d6e5f
if ($LASTEXITCODE -ne 0) { throw 'Migration failed: leave apps unchanged' }
python -m alembic current
if ($LASTEXITCODE -ne 0) { throw 'Migration verification failed' }
# Require a91b8c7d6e5f.
Remove-Item Env:PGOPTIONS
Pop-Location
az containerapp update -n safecircle-push-worker -g $rg --image $pinned --query properties.latestRevisionName -o tsv
if ($LASTEXITCODE -ne 0) { throw 'Worker update failed; restore worker' }
az containerapp revision list -n safecircle-push-worker -g $rg --query '[?properties.active].{name:name,health:properties.healthState,replicas:properties.replicas}' -o json
# STOP until new worker revision is Healthy/ready and sanitized startup logs show no errors.
# Use replica/log checks in RELEASE_SAFETY_GATE.md. Never print raw personal/token log data.
az containerapp update -n safecircle-api -g $rg --image $pinned --query properties.latestRevisionName -o tsv
if ($LASTEXITCODE -ne 0) { throw 'API update failed; restore API then worker' }
az containerapp revision list -n safecircle-api -g $rg --query '[?properties.active].{name:name,health:properties.healthState,replicas:properties.replicas}' -o json
$base = 'https://safecircle-api.nicerock-dbadcbd7.southafricanorth.azurecontainerapps.io'
Invoke-RestMethod "$base/health"
Invoke-RestMethod "$base/health/ready"
# Require HTTP 200, exact same $pinned in both ready revisions, unchanged environment/identity/scaling/network/secrets/worker command.
```

Rollback individually recorded images, API first when API was updated; worker only if it alone failed. Leave database schema expanded:

```powershell
az containerapp update -n safecircle-api -g $rg --image $apiRollback --query properties.latestRevisionName -o tsv
if ($LASTEXITCODE -ne 0) { throw 'API rollback failed' }
az containerapp update -n safecircle-push-worker -g $rg --image $workerRollback --query properties.latestRevisionName -o tsv
if ($LASTEXITCODE -ne 0) { throw 'Worker rollback failed' }
az containerapp revision list -n safecircle-api -g $rg -o table
az containerapp revision list -n safecircle-push-worker -g $rg -o table
Invoke-RestMethod "$base/health"
Invoke-RestMethod "$base/health/ready"
# Verify actual restored images and ready replicas; CLI success alone is insufficient.
```

3. Only after backend readiness and release authorization, build ONE APK for both phones:

```powershell
flutter build apk --release --dart-define=SAFECIRCLE_API_BASE_URL=https://safecircle-api.nicerock-dbadcbd7.southafricanorth.azurecontainerapps.io
```

Do not distribute that APK if the backend is rolled back; its cleanup endpoint will be unavailable. Do not rebuild repeatedly to guess Firebase network or bucket provisioning causes. Collect the precise device stage/code first and resolve any separately approved cloud configuration before declaring demonstration ready.

## Physical demonstration acceptance (not executed)

- Phone A: upgrade in place only after backend readiness. Register Account A, restart, logout, login B, confirm A inbox/emergency state cleared and no A pushes reach B. Then B logout and A login; repeat logout to verify idempotency.
- Phone B: Firebase login, Firestore profile loading and backend profile-ready status; register notifications, view My Connections, restart and logout. If sign-in fails, capture only safe Firebase stage/code, UTC timestamp, Android/Play-services versions and network type. Automatic date/time and another trusted network are checks, not proven remedies.
- Both on A: logout Phone A while Phone B remains registered; verify harmless test delivery still reaches B. Both on separate accounts: verify isolation and accepted relationships.
- Connections: invite/accept/remove using intended test accounts; pending/removed users must not see private alert information or acknowledge. Do not mutate production relationships merely for deployment health checks; obtain test authorization.
- Location/map: granted, denied, unavailable GPS and reconnect states; no stale point labelled live. Use local synthetic/resolved history to exercise emergency authorization without activating real alerts.
- Harmless notifications only through an approved path; production development-only /test-notifications/me may be disabled. Do not enable flags or trigger panic alerts. Verify foreground/background behavior and acknowledgement notification authorization in local tests; any device acknowledgement scenario needs a separately approved synthetic environment/event.
- Profile photo: select a small PNG/JPEG, preview, upload, restart, reload; compare owner-only visibility and attempt no cross-account reads. On failure record code and stage ONLY, no filename, path, token or private image. Bucket/rule provisioning is a separate approval dependency if diagnosed.
- Restart/network reconnection: no duplicate registrations/deliveries, no prior account details, no unverified cleanup bypass. FCM deliveries already submitted cannot be recalled. Reinstall/clear-data is not routine recovery for unknown legacy rows.
- Safe diagnostics from a future updated APK may be filtered locally with adb logcat for safe_circle_login, safe_circle_firebase_initialization, safe_circle_backend_profile, safe_circle_logout_cleanup and Profile photo Firebase operation failed. Do not upload raw logcat.

## Stop conditions

Recovery evidence absent => NO-GO. Unexpected image/subscription/revision => stop. Any build/push/migration/worker failure => no API update. API failure => rollback API then worker and verify. Missing production photo rules/bucket or persistent Firebase network failure => demonstration feature remains unconfirmed; no paid service/rule change implied. Physical claims require actual phone results.

## Final executed results

Flutter analyze: no issues. Full Flutter suite: 450 passed, zero failed/skipped. Full FastAPI suite with both isolated PostgreSQL suites enabled: 408 passed, zero failed/skipped, including Alembic migration tests and the two new real PostgreSQL conflict cases. Docker backend build/import/head checks passed. git diff --check passed. Test containers were stopped and disposable pytest directories removed. Earlier test failures were resolved before this final run.

## Files changed in this combined session

backend/app/devices.py; backend/tests/test_device_registration_concurrency.py; backend/tests/test_installation_postgres.py; lib/main.dart; lib/state/app_state.dart; lib/services/auth_service.dart; lib/services/notification_service.dart; lib/services/profile_photo_service.dart; test/auth_login_diagnostics_test.dart; test/profile_photo_diagnostics_test.dart; release-source-manifest.json; COMBINED_RELEASE_PLAN.md; RELEASE_READINESS.md; RELEASE_SAFETY_GATE.md. Other existing dirty files were preserved.

Final source fingerprint: cb49dc40d4221b3a495057bf25bff5ecc9a7d3927a6664545167730177fdb1f4. Manifest covers 294 tracked/untracked source paths/deletions; excludes Markdown documentation and the manifest itself. Private-key-marker scan passed; Firebase client configuration remains existing public client config, not Admin credentials. No .env/private key files appear in the source inventory. This scan is not a substitute for future source review.

## Complete working-tree release inventory

```text
 M android/app/src/main/AndroidManifest.xml
 M backend/app/alerts.py
 M backend/app/devices.py
 M backend/app/models.py
 M backend/app/notification_events.py
 M backend/app/notification_service.py
 M backend/app/push_submission.py
 M backend/app/push_worker.py
 M backend/tests/test_alerts_notification_regressions.py
 M backend/tests/test_contact_links.py
 M backend/tests/test_contact_links_migration.py
 M backend/tests/test_device_registration_concurrency.py
 M backend/tests/test_emergency_notification_events.py
 M backend/tests/test_emergency_notification_postgres.py
 M backend/tests/test_emergency_push_copy.py
 M backend/tests/test_notifications_migration.py
 M backend/tests/test_push_management.py
 M backend/tests/test_push_retention_postgres.py
 M backend/tests/test_push_submission.py
 M lib/main.dart
 M lib/models/models.dart
 M lib/navigation/app_router.dart
 M lib/screens/activate_panic_screen.dart
 M lib/screens/alert_history_screen.dart
 M lib/screens/contact_links_screen.dart
 D lib/screens/contacts_screen.dart
 M lib/screens/emergency_active_screen.dart
 M lib/screens/emergency_nearby_screen.dart
 M lib/screens/home_screen.dart
 M lib/screens/profile_screen.dart
 M lib/services/api_service.dart
 M lib/services/auth_service.dart
 M lib/services/location_service.dart
 M lib/services/notification_service.dart
 M lib/services/profile_photo_service.dart
 M lib/state/app_state.dart
 M lib/widgets/real_map.dart
 M linux/flutter/generated_plugin_registrant.cc
 M linux/flutter/generated_plugin_registrant.h
 M linux/flutter/generated_plugins.cmake
 M macos/Flutter/GeneratedPluginRegistrant.swift
 M pubspec.lock
 M pubspec.yaml
 M test/api_service_test.dart
 M test/app_state_test.dart
 M test/backend_profile_ui_test.dart
 M test/contact_links_navigation_test.dart
 M test/device_registration_lifecycle_test.dart
 M test/emergency_ack_authorization_test.dart
 M test/notification_management_push_test.dart
 M test/notifications_state_test.dart
 M test/notifications_ui_test.dart
 M test/support/contact_links_fakes.dart
 M windows/flutter/generated_plugin_registrant.cc
 M windows/flutter/generated_plugin_registrant.h
 M windows/flutter/generated_plugins.cmake
?? ANDROID_AUTH_INVESTIGATION.md
?? COMBINED_RELEASE_PLAN.md
?? RECOVERY_VERIFICATION_PLAN.md
?? RELEASE_READINESS.md
?? RELEASE_SAFETY_GATE.md
?? android/app/src/main/res/xml/
?? backend/migrations/versions/a91b8c7d6e5f_scope_devices_to_installation.py
?? backend/tests/test_device_installation_migration.py
?? backend/tests/test_installation_postgres.py
?? lib/services/emergency_call_service.dart
?? lib/services/installation_identity.dart
?? release-source-manifest.json
?? test/alert_history_details_test.dart
?? test/auth_login_diagnostics_test.dart
?? test/emergency_call_service_test.dart
?? test/installation_identity_test.dart
?? test/profile_photo_diagnostics_test.dart
?? tools/recovery/
```

## Recovery investigation addendum - 2026-11-19

Decision: NO-GO. This addendum supplements the historical release
verification above; it does not supersede the recorded test results.

### Confirmed recovery observations

- Azure PostgreSQL Flexible Server remains PostgreSQL 16 with private
  networking and public network access disabled.
- Four Azure-managed full backups were observed, dated 2026-11-16
  through 2026-11-19. Managed backups do not establish a verified
  portable logical backup or isolated restore.
- No verified Windows VPN, private route, or approved private-access
  PostgreSQL client environment was identified.
- The four checked standard PostgreSQL service/password file paths
  under APPDATA and HOME were absent. Custom paths were not excluded.
- The existing safecircle-db-init Container Apps job is an
  initialization/migration job, not a production backup job.
  It was not started.
- The snapshot-consistent recovery procedure and
  tools/recovery/prepare_logical_backup.py were reviewed but not run.
- Sixty targeted local tests passed during the investigation:
  25 Flutter lifecycle, 5 backend devices API,
  26 backend push management, and 4 PostgreSQL migration integration.
  These are separate observations and are not added to historical
  full-suite totals because test overlap has not been established.

### Outstanding authorization and recovery gate

- No production logical backup was exported.
- No production data was restored into an isolated local target.
- No production migration, deployment, database write, public-network
  change, Azure resource creation, or recovery job execution occurred.
- Before deployment, obtain explicit production-export approval,
  an authorized private-access client, protected encrypted backup
  handling and transport, and accepted cost constraints.
- Produce a consistent PostgreSQL 16 logical backup with same-snapshot
  validation, then verify its restore into an isolated PostgreSQL 16
  PostGIS environment. Record integrity, schema, data, and RPO/RTO
  evidence before requesting separate deployment authorization.

Production deployment remains NO-GO. Phone A logout, Phone B Firebase
authentication, and profile photo functionality remain unresolved
until their respective deployment and physical verification gates pass.
