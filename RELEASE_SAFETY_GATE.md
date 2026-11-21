> Current production status (22 November 2026): DEPLOYED AND VERIFIED.
> The recovery gate was satisfied, migration `a91b8c7d6e5f` completed, and the
> worker and API are healthy on the approved immutable image. See
> [the executed release report](docs/PRODUCTION_RELEASE_2026-11-22.md).
> Earlier NO-GO statements and preparation commands below are historical.

> Current combined results/source snapshot and commands: see COMBINED_RELEASE_PLAN.md. Production remains NO-GO. Historical results below are retained for traceability.

# Final production safety gate ? 2026-11-16

**NO-GO / BLOCKED: no evidence of a completed isolated database restore drill.**
This supersedes the prior code-readiness recommendation. Backup configuration does not prove recovery has been tested.
No production-changing command was executed. No backup containing production data was exported. No restore resource was created. No secrets were displayed.

## Observed Azure state

Subscription Azure for Students, Enabled, 44750d19-6609-4202-8ffd-316c51ba018c.
Resource group rg-safecircle-student in southafricanorth.
API revision safecircle-api--tm5ge9w and worker revision safecircle-push-worker--s4xcv7g: active, Healthy, one running replica each, containers ready, zero restarts at observation.
Both pinned to safecirclestudentacr.azurecr.io/safecircle-api@sha256:fcf5798d6fb2456afd114bab0588e3ae0933d6a521694e774f71150c9722fbb1.
ACR confirms that immutable manifest exists (created 2026-11-16T05:24:15.2309516Z).
API /health returned status=ok; /health/ready returned status=ready.
Both use existing cae-safecircle-student environment, UserAssigned identity, Single revision mode, min/max replicas 1/1. API HTTPS ingress port 8000; worker has no ingress and command python -m app.push_worker.
Both retain DATABASE_URL -> database-url and FIREBASE_SERVICE_ACCOUNT_JSON -> firebase-service-account-json references. Required secret names exist. No secret changes are needed.

PostgreSQL pg-safecircle-student.postgres.database.azure.com, version 16, Ready, South Africa North; public networking disabled, existing delegated subnet/private DNS.
Database safecircle_db was verified from the API's configured database connection, using SET TRANSACTION READ ONLY and a SELECT limited to current_database() and alembic_version.
Current revision e17d6a10bc25; target a91b8c7d6e5f.
No unexpected production configuration differences were found.

## Recovery evidence and unresolved gate

Azure reports backupRetentionDays=7, geoRedundantBackup=Disabled, earliestRestoreDate=2026-11-16T01:00:04.285598+00:00.
A timestamp after that earliest time and before the latest available recovery point is a candidate for recovery. The latest usable point and actual successful restore were not tested. Do not interpret seven-day retention as seven days of available history on this server.
No completed isolated restore drill, validated dump, recovery duration or recovery-point objective evidence was found in the repository or supplied session.
The production database is private: an existing approved network-access environment is required. Do not add public access or firewall exceptions.

The exact protected pg_dump/pg_restore procedure and migration commands are in RELEASE_READINESS.md. Those commands require operator-provisioned service definitions and a pre-existing isolated restore target; neither is established as available. Therefore they are a prepared procedure, not an executable verified recovery path yet.

To unblock: supply dated restore-drill evidence including source backup/time, isolated target identity, successful restore, schema/data validation, duration, RPO/RTO acceptance and protected artifact handling. Alternatively separately authorize an isolated recovery drill and any required temporary resources. Local synthetic migration tests do not meet this requirement.

Azure point-in-time restore creates a separate server. Compute, provisioned storage, retained backup storage and possible network usage may incur charges. No fixed currency estimate is asserted without selecting the target SKU/storage/runtime. No such resource is authorized here.
Official references:
- https://learn.microsoft.com/en-us/azure/postgresql/backup-restore/concepts-backup-restore
- https://learn.microsoft.com/en-us/cli/azure/postgres/flexible-server

## Source and verification evidence

Branch codex/azure-deployment-preparation; base commit 8afa786cf7b8c02e32307d243191b9499694bd92.
Source manifest release-source-manifest.json captures 305 tracked/untracked source paths and deletions, including the entire dirty tree. Documentation and manifest itself are excluded from the fingerprint.
Source snapshot SHA256: 09cf7820373be5bf647ab989f76dd17ae173be9ff74ed62e02def79c92b3935c.
This is a dirty source snapshot, not a committed release. Recompute/review it if any source changes before deployment.
Verified local image: safecircle-api:local-readiness-a91b8c7d6e5f, ID sha256:09e0700b127697552e249d78f29befe9ad16b4913caa65767f8df6bf63818d4a.
Every app/*.py and migrations/**/*.py byte hash in that image matches the current source. Previous comparison against the exact live immutable image found functional differences only in app/devices.py and app/models.py; app/test_notifications.py has BOM-only difference. Existing worker code is unchanged but its shared Device model requires the additive column.

Reused, not rerun in this turn: 404 backend tests with local PostgreSQL enabled (zero skipped), Flutter 441 tests, clean Flutter analysis, migration upgrade/downgrade tests and successful backend Docker build. Current changes are documentation/manifest only. Fresh checks: Azure preflight, database read-only revision, image/source matching, Git status/diff review and git diff --check.
No private-key markers were found in tracked/untracked source files scanned. Only android/app/google-services.json matched configuration filenames; this is Firebase client configuration and is outside the backend build context. A private-key-marker scan is not a universal proof that no arbitrary secret exists; preserve the explicit Docker COPY allowlist and review any future added files.

Backend Docker context is backend with COPY of requirements.txt, app/, migrations/, alembic.ini and scripts/bootstrap_postgres.sql; .env and tests excluded. No credentials need to enter the image.
The entire dirty-tree inventory and release contents are in RELEASE_READINESS.md and the manifest. Unrelated prior changes include My Connections, emergency owner/GPS/location privacy, acknowledgement push notifications, history screens, dialler, Profile menu/photo diagnostics, dependency lockfile and desktop registrants. Backend emergency functionality already matches live image; a future APK packages all local Flutter changes.
Old APKs remain supported by optional installation_id and retained token DELETE/status endpoints. New APK requires the new installation endpoint. Release backend before distributing APK. Image rollback leaves additive schema in place; the new APK may fail closed on logout if rolled back API lacks its endpoint.

## Commands: read-only final verification

Run in PowerShell. Stop on any mismatch or nonzero exit. Do not run later production-changing sections while this gate is blocked.

```powershell
$ErrorActionPreference = 'Stop'
$subscription = '44750d19-6609-4202-8ffd-316c51ba018c'
$rg = 'rg-safecircle-student'
$server = 'pg-safecircle-student'
$rollback = 'safecirclestudentacr.azurecr.io/safecircle-api@sha256:fcf5798d6fb2456afd114bab0588e3ae0933d6a521694e774f71150c9722fbb1'
$account = az account show -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $account.id -ne $subscription -or $account.state -ne 'Enabled') { throw 'Wrong Azure subscription' }
az group show -n $rg --query '{name:name,location:location}' -o json
az acr repository show -n safecirclestudentacr --image 'safecircle-api@sha256:fcf5798d6fb2456afd114bab0588e3ae0933d6a521694e774f71150c9722fbb1' --query digest -o tsv
foreach ($app in @('safecircle-api','safecircle-push-worker')) {
  $state = az containerapp show -n $app -g $rg -o json | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0 -or $state.properties.template.containers[0].image -ne $rollback) { throw 'Unexpected image; stop' }
  az containerapp revision list -n $app -g $rg --query '[?properties.active].{name:name,health:properties.healthState,replicas:properties.replicas}' -o json
  az containerapp replica list -n $app -g $rg --revision $state.properties.latestReadyRevisionName --query '[].{running:properties.runningState,containers:properties.containers[].{name:name,ready:ready,restarts:restartCount}}' -o json
}
az postgres flexible-server show -g $rg -n $server --query '{name:name,state:state,backup:backup,network:network}' -o json
az postgres flexible-server db list -g $rg -s $server --query '[].name' -o json
$base = 'https://safecircle-api.nicerock-dbadcbd7.southafricanorth.azurecontainerapps.io'
Invoke-RestMethod "$base/health"
Invoke-RestMethod "$base/health/ready"
# From existing protected PostgreSQL service, read only migration metadata:
psql 'service=safecircle-production' -X -v ON_ERROR_STOP=1 -c 'BEGIN READ ONLY; SET LOCAL statement_timeout=5000; SELECT current_database(), version_num FROM alembic_version; ROLLBACK;'
if ($LASTEXITCODE -ne 0) { throw 'Read-only database verification failed' }
```

## Commands: recovery drill ? NOT AUTHORIZED TO EXECUTE

Protected dump and pre-existing isolated restore-target commands are in RELEASE_READINESS.md. If Azure PITR is separately approved instead, the exact CLI shape is below. It CREATES A BILLABLE SERVER and remains prohibited under current authorization:

```powershell
$sourceServerId = '/subscriptions/44750d19-6609-4202-8ffd-316c51ba018c/resourceGroups/rg-safecircle-student/providers/Microsoft.DBforPostgreSQL/flexibleServers/pg-safecircle-student'
$restoreTime = Read-Host 'Approved UTC recovery timestamp within verified recovery window'
$restoreName = Read-Host 'Separately approved unique isolated recovery server name'
az postgres flexible-server restore --subscription $subscription --resource-group $rg --name $restoreName --source-server $sourceServerId --restore-time $restoreTime
if ($LASTEXITCODE -ne 0) { throw 'Restore failed' }
```

Verify restored server identity and TLS/network access, Alembic revision, expected application tables, constraints and approved aggregate validation in a read-only drill. Do not connect apps to it or expose user records. Record recovery timing and validation evidence securely. Any cleanup of a restore resource requires approval too.

## Commands: approved future release and rollback

RELEASE_READINESS.md contains the exact build/tag, exposed-token ACR login, push, digest resolution, migration, worker-first update, API update and rollback commands. They are not executed. Keep the backup/restore gate first, then backup, approved migration, healthy worker, healthy API and APK distribution.
Use the same immutable digest for both updates. Update only --image; preserve all configuration. Re-read both digests immediately before rollback, using each individually recorded predeployment image even though both currently match.

Additional worker health/log gate, after a future authorized update:

```powershell
$worker = az containerapp show -n safecircle-push-worker -g $rg -o json | ConvertFrom-Json
$revision = $worker.properties.latestRevisionName
az containerapp revision show -n safecircle-push-worker -g $rg --revision $revision --query '{health:properties.healthState,running:properties.runningState}' -o json
az containerapp replica list -n safecircle-push-worker -g $rg --revision $revision --query '[].{running:properties.runningState,containers:properties.containers[].{name:name,ready:ready,restarts:restartCount}}' -o json
# Capture platform system logs in memory; print only error counts, no raw log/user data.
$logs = az containerapp logs show -n safecircle-push-worker -g $rg --type system --tail 50 --format json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Worker log inspection failed' }
$errors = @($logs | Where-Object { $_.Log -match 'error|failed|crash|backoff' })
if ($errors.Count -gt 0) { throw 'Worker system logs require private sanitized review; stop before API update' }
# Separately inspect application startup in a protected operator view, redact credentials/user content, and require no startup errors.
```

Healthy worker revision/ready replica and sanitized application startup must be confirmed before the API update. Do not trigger real emergency events for verification. All native CLI exit statuses must be checked; health observations must be fresh, not inherited from an earlier revision.

Exact rollback with the currently confirmed digest, only after separate deployment authorization:

```powershell
az containerapp update -n safecircle-api -g $rg --image $rollback --query properties.latestRevisionName -o tsv
if ($LASTEXITCODE -ne 0) { throw 'API rollback failed' }
az containerapp update -n safecircle-push-worker -g $rg --image $rollback --query properties.latestRevisionName -o tsv
if ($LASTEXITCODE -ne 0) { throw 'Worker rollback failed' }
# Require both images, ready replicas and revision health to match expectations; then:
Invoke-RestMethod "$base/health"
Invoke-RestMethod "$base/health/ready"
# Never run alembic downgrade during image rollback.
```

Exact APK build command, prepared only and prohibited under current scope:

```powershell
flutter build apk --release --dart-define=SAFECIRCLE_API_BASE_URL=https://safecircle-api.nicerock-dbadcbd7.southafricanorth.azurecontainerapps.io
```

## Physical Android verification after approval

1. Upgrade Phone 1 in place. Login Account A, allow registration to complete, logout; login B and verify no A inbox/emergency state appears. Return B to A and repeat logout.
2. Keep Phone 2 logged into A during Phone 1 logout. Verify Phone 2 registration and harmless test delivery remain functional.
3. With both phones logged into A, logout Phone 1 repeatedly and verify only its installation is revoked. Then test each phone on a distinct account.
4. Test accepted connections, invitation state, profile loading, map/location permission failures and account switching; no account may see the other's private information. Use existing historical/resolved screens or local tests for emergency map behavior; do not create real panic alerts.
5. Use a separately authorized harmless notification path. Existing /test-notifications/me is development-gated; do not enable production feature flags as part of deployment. If no approved production test channel exists, leave actual FCM delivery unverified and record it.
6. Record safe cleanup stages/statuses, token lookup availability and backend confirmation without tokens, credentials, personal data or coordinates. A delivery already submitted to Firebase cannot be recalled. Legacy orphan attribution and OEM secure-storage restore behavior remain physical verification risks.

Final decision: NO-GO until tested recovery evidence is accepted. All production-changing actions require new explicit authorization after the gate is satisfied.
