> Current production status (22 November 2026): DEPLOYED AND VERIFIED.
> The recovery gate was satisfied, migration `a91b8c7d6e5f` completed, and the
> worker and API are healthy on the approved immutable image. See
> [the executed release report](docs/PRODUCTION_RELEASE_2026-11-22.md).
> Earlier NO-GO statements and preparation commands below are historical.

> Current combined results/source snapshot and commands: see COMBINED_RELEASE_PLAN.md. Production remains NO-GO. Historical results below are retained for traceability.

# Installation cleanup release readiness ? 2026-11-16

## Verification

BLOCKED / NO-GO at the final production safety gate: a tested recovery procedure has not been evidenced. Local code verification passes. See RELEASE_SAFETY_GATE.md. Nothing deployed or pushed.
Full backend suite with both local PostgreSQL flags: 404 passed, zero skipped.
Previously skipped suites: 34 passed; new PostgreSQL installation cases: 2 passed.
Flutter baseline: 441 passed and analysis clean from prior verification; no Flutter changes in this verification.
Local Docker build and API/worker imports succeeded with a synthetic in-memory URL.
Local image: safecircle-api:local-readiness-a91b8c7d6e5f
Manifest list: sha256:09e0700b127697552e249d78f29befe9ad16b4913caa65767f8df6bf63818d4a

Tests use two loopback-only PostGIS 16 containers, synthetic accounts, disposable schemas, and no production connection.
Updated historical PostgreSQL fixtures to match the current ORM and full worker schema; migration-specific tests still explicitly exercise historical revisions.
Added PostgreSQL coverage for parent-to-head migration, preservation of legacy rows, ownership foreign key, composite index, token rotation, other-phone preservation, idempotent cleanup, queued emergency cancellation and guarded downgrade.

## Current Azure references (read-only observation)

API ready revision: safecircle-api--tm5ge9w
Worker ready revision: safecircle-push-worker--s4xcv7g
Both provisioning states: Succeeded.
Both images: safecirclestudentacr.azurecr.io/safecircle-api@sha256:fcf5798d6fb2456afd114bab0588e3ae0933d6a521694e774f71150c9722fbb1
Reverify images, active revision health, subscription and readiness immediately before deployment.
The exact locally available rollback image has Alembic head e17d6a10bc25.
Normalized source comparison: only app/devices.py and app/models.py change functionally.
app/test_notifications.py differs only by its leading UTF-8 BOM. Emergency/worker changes in Git are already in this deployed image.
Final read-only production probe confirmed database safecircle_db at e17d6a10bc25. Reverify immediately before an approved migration.

## Migration assessment

Revision a91b8c7d6e5f adds device_installations with a primary key and nullable owner foreign key (ON DELETE SET NULL), nullable devices.installation_id and index (user_id, installation_id).
It does not backfill, delete, or rewrite existing registrations. The installation field intentionally has no device-to-installation foreign key; ownership is enforced transactionally by the API. Lowercase 64-hex validation is at API level, not a database CHECK.
Old API and worker ignore the additive schema. New API and worker require it before starting because their shared Device ORM includes the new column.
Index creation and ALTER TABLE take locks; use lock_timeout to fail instead of waiting indefinitely. Real table size and lock duration were not measured on production.
Downgrade refuses any ownership rows or attributed devices. Roll back images and KEEP the expanded database schema.
Old APK POST /devices and DELETE /devices remain supported; deprecated GET /devices/cleanup-status remains authenticated and boolean-only. New APK uses DELETE /devices/installation.
Legacy registrations remain NULL until an authenticated owner presents that exact token. Unknown legacy rows are preserved. Token unavailable plus unattributed rows can still block logout; no safe attribution is possible from the installation ID alone.
Current-token reconciliation does not prove ownership of every historical token from another account. Such orphaned rows require explicit, separately approved recovery; no production cleanup is included.

## Backup and recovery ? PREPARE ONLY

Use an approved operator session with network access already available, PostgreSQL 16 client tools, TLS verify-full, and a protected pg_service.conf/pgpass configuration. Do not print credentials or put them on the command line.
Configure service safecircle-production and service safecircle-restore-drill through the existing secret process. The drill must point to an isolated non-production database; verify its identity before restoring.
Choose an encrypted, access-restricted backup directory outside the repository. Database dumps contain private user data. Do not attach them to logs or source control.

```powershell
$env:PGSERVICE = 'safecircle-production'
$backup = Join-Path $env:SAFECIRCLE_BACKUP_DIRECTORY ('safecircle-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '.dump')
pg_dump --format=custom --no-owner --no-acl --file=$backup
if ($LASTEXITCODE -ne 0) { throw 'Backup failed' }
pg_restore --list $backup
if ($LASTEXITCODE -ne 0) { throw 'Backup archive validation failed' }
Get-FileHash -Algorithm SHA256 -LiteralPath $backup
# Verify restore-drill service points to an isolated database before executing:
pg_restore --dbname='service=safecircle-restore-drill' --no-owner --no-acl --exit-on-error $backup
if ($LASTEXITCODE -ne 0) { throw 'Restore drill failed' }
```

Also confirm existing Azure PostgreSQL point-in-time recovery retention and recoverable time before release. Do not change settings or create a recovery server without separate approval. Full restore to production overwrites newer data; it is disaster recovery, never normal code rollback.
Gate: do not migrate until backup and isolated restore verification succeed.

## Exact release commands ? NOT EXECUTED

Run from the repository in PowerShell after explicit approval. Stop on every nonzero exit. Independently compare each app's digest with the recorded values; do not rely on a tag. Preserve each app's settings and worker command.

```powershell
$ErrorActionPreference = 'Stop'
$rg = 'rg-safecircle-student'
$registry = 'safecirclestudentacr'
$repo = 'safecircle-api'
$apiBefore = (az containerapp show -n safecircle-api -g $rg -o json | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0) { throw 'API snapshot failed' }
$workerBefore = (az containerapp show -n safecircle-push-worker -g $rg -o json | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0) { throw 'Worker snapshot failed' }
$apiRollback = $apiBefore.properties.template.containers[0].image
$workerRollback = $workerBefore.properties.template.containers[0].image
if ($apiRollback -notmatch '@sha256:' -or $workerRollback -notmatch '@sha256:') { throw 'Resolve each live digest first' }
# Keep snapshots only in protected operator memory/storage; never print secret configuration.
az account show --query '{name:name,id:id}' -o json
if ($LASTEXITCODE -ne 0) { throw 'Subscription check failed' }
# Operator confirms Azure for Students before continuing.
$tag = 'release-' + (git rev-parse --short HEAD).Trim() + '-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$image = "$registry.azurecr.io/${repo}:$tag"
docker build -f backend/Dockerfile -t $image backend
if ($LASTEXITCODE -ne 0) { throw 'Build failed' }
# Authenticate without printing the exposed token; Docker uses its existing credential storage.
$login = az acr login --name $registry --expose-token -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'ACR authentication failed' }
$login.accessToken | docker login "$registry.azurecr.io" --username 00000000-0000-0000-0000-000000000000 --password-stdin
if ($LASTEXITCODE -ne 0) { throw 'Docker authentication failed' }
$login = $null
docker push $image
if ($LASTEXITCODE -ne 0) { throw 'Push failed' }
$digest = az acr repository show -n $registry --image "${repo}:$tag" --query digest -o tsv
if ($LASTEXITCODE -ne 0 -or $digest -notmatch '^sha256:[0-9a-f]{64}$') { throw 'Digest verification failed' }
$pinned = "$registry.azurecr.io/${repo}@$digest"
```

After backup, run migration from an approved existing database-access environment with the new source/image available and the existing protected DATABASE_URL injected. No Container App startup migration and no new Azure Job/resource:

```powershell
Push-Location backend
$env:PGOPTIONS = '-c lock_timeout=5s -c statement_timeout=60s'
python -m alembic current
if ($LASTEXITCODE -ne 0) { throw 'Revision check failed' }
# Confirm actual revision is e17d6a10bc25 before next command.
python -m alembic upgrade a91b8c7d6e5f
if ($LASTEXITCODE -ne 0) { throw 'Migration failed; do not update apps' }
python -m alembic current
if ($LASTEXITCODE -ne 0) { throw 'Migration verification failed' }
Remove-Item Env:PGOPTIONS
Pop-Location
az containerapp update -n safecircle-push-worker -g $rg --image $pinned --query properties.latestRevisionName -o tsv
if ($LASTEXITCODE -ne 0) { throw 'Worker update failed; roll back worker' }
az containerapp revision list -n safecircle-push-worker -g $rg --query '[].{name:name,active:properties.active,health:properties.healthState,running:properties.runningState}' -o json
# Wait until new worker revision is healthy; inspect sanitized startup logs before API update.
az containerapp update -n safecircle-api -g $rg --image $pinned --query properties.latestRevisionName -o tsv
if ($LASTEXITCODE -ne 0) { throw 'API update failed; roll back API then worker' }
az containerapp revision list -n safecircle-api -g $rg --query '[].{name:name,active:properties.active,health:properties.healthState,running:properties.runningState}' -o json
$base = 'https://safecircle-api.nicerock-dbadcbd7.southafricanorth.azurecontainerapps.io'
Invoke-RestMethod "$base/health"
Invoke-RestMethod "$base/health/ready"
# Require HTTP 200, healthy revisions, identical pinned images, and compare all non-image settings against snapshots.
# Verify authenticated installation endpoint appears in OpenAPI; do not invoke it against production user data as a health check.
```

Rollback uses individually captured digests, API first if API was updated, worker second. Do not downgrade the database:

```powershell
az containerapp update -n safecircle-api -g $rg --image $apiRollback --query properties.latestRevisionName -o tsv
if ($LASTEXITCODE -ne 0) { throw 'API rollback failed' }
az containerapp update -n safecircle-push-worker -g $rg --image $workerRollback --query properties.latestRevisionName -o tsv
if ($LASTEXITCODE -ne 0) { throw 'Worker rollback failed' }
az containerapp revision list -n safecircle-api -g $rg -o table
az containerapp revision list -n safecircle-push-worker -g $rg -o table
Invoke-RestMethod "$base/health"
Invoke-RestMethod "$base/health/ready"
```

If worker fails before API deployment, restore only worker. Confirm actual ready revision images and health after rollback. A new APK needs the new API; if backend rollback becomes necessary, pause APK distribution and document that installation cleanup will fail closed until API recovery.

After backend readiness, build separately approved APK (not built here):

```powershell
flutter build apk --release --dart-define=SAFECIRCLE_API_BASE_URL=https://safecircle-api.nicerock-dbadcbd7.southafricanorth.azurecontainerapps.io
```

No new cloud resources are needed. Existing compute, registry storage and image transfer may incur normal usage charges. Local test containers are stopped after verification.

## Release contents

Backend build includes app/, migrations/, requirements.txt, alembic.ini and bootstrap_postgres.sql only. Tests/docs/Flutter do not enter the runtime image. No Dockerfile or dependency changes were made in this verification.
The dirty Git tree also contains My Connections, emergency names/GPS/location privacy, acknowledgement pushes, history navigation, emergency dialler, profile/support/photo diagnostics, dependencies and generated plugins. These are outside the logout-only scope and are preserved. Most backend emergency changes already match the deployed image, as described above. A new APK includes ALL local Flutter changes below, not just logout.

### Working tree snapshot

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
 M backend/tests/test_emergency_notification_events.py
 M backend/tests/test_emergency_notification_postgres.py
 M backend/tests/test_emergency_push_copy.py
 M backend/tests/test_notifications_migration.py
 M backend/tests/test_push_management.py
 M backend/tests/test_push_retention_postgres.py
 M backend/tests/test_push_submission.py
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
?? RELEASE_READINESS.md
?? android/app/src/main/res/xml/
?? backend/migrations/versions/a91b8c7d6e5f_scope_devices_to_installation.py
?? backend/tests/test_device_installation_migration.py
?? backend/tests/test_installation_postgres.py
?? lib/services/emergency_call_service.dart
?? lib/services/installation_identity.dart
?? test/alert_history_details_test.dart
?? test/emergency_call_service_test.dart
?? test/installation_identity_test.dart
```

## Physical verification after approval

Upgrade Phone 1 in place with Account A; confirm registration, then logout and sign in as B. Phone 2 stays on A throughout; verify its registration survives. Repeat Phone 1 A ? B ? A and both phones on A. Confirm repeated logout is safe, network failures retain the session, no old account inbox/emergency state appears, and no push is submitted to revoked registrations. Real FCM testing requires separately approved test events; never create panic alerts as deployment checks. Already submitted FCM deliveries cannot be recalled. Secure-storage backup/restore behavior still requires device testing across supported Android vendors.
