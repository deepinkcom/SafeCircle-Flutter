> Current production status (22 November 2026): DEPLOYED AND VERIFIED.
> The recovery gate was satisfied, migration `a91b8c7d6e5f` completed, and the
> worker and API are healthy on the approved immutable image. See
> [the executed release report](docs/PRODUCTION_RELEASE_2026-11-22.md).
> Earlier NO-GO statements and preparation commands below are historical.

# Cost-safe recovery verification plan (preparation only)

Decision: NO-GO pending separately authorized production export and a successful local restore drill. No export, restore, migration, deployment or paid operation has been performed.

## Preferred method and cost boundary

Prefer a consistent logical pg_dump of safecircle_db, with a same-snapshot private content baseline, restored to an isolated local PostgreSQL 16/PostGIS Docker container. This adds no Azure server, disk, storage account, backup vault or restore resource.
This is the lowest-resource supported approach, conditional on an EXISTING private access path and sufficient unused free outbound transfer allowance. It is not an unconditional zero-charge promise: Azure egress, any existing VPN/relay service and existing server CPU/IO usage must be assessed first. No new Azure access path is approved.
The Azure bandwidth page advertises the first 100 GB/month free; actual remaining allowance/subscription terms were not verified. Do not assume all of it is still available. If zero incremental charges cannot be confirmed, STOP before export and request a cost decision.
The production server is Standard_B1ms (Burstable), PostgreSQL 16, 32 GiB Premium_LRS P4, IOPS 120, Ready. Avoid parallel dumps/fingerprints; use timeouts and abort on load concerns. The configured 32 GiB is provisioned storage, not measured database/dump size.

## Refreshed read-only evidence

Azure for Students, Enabled, subscription 44750d19-6609-4202-8ffd-316c51ba018c; rg-safecircle-student.
Server pg-safecircle-student: public network disabled; existing snet-postgres/private DNS.
Backup retention 7 days; earliest restore 2026-11-16T01:00:04.285598+00:00; geoRedundantBackup Disabled.
The previous safety-gate read-only probe confirmed safecircle_db at e17d6a10bc25. No production rows or counts were read in this preparation.
Native pg_dump/pg_restore/psql were not found on this workstation PATH. Local Docker and cached PostGIS 16 image exist, with previous synthetic test containers stopped.
No VM or VNet gateway exists in this resource group. This does not exclude connectivity managed elsewhere. Existing container exec is not a verified secure bulk backup transport. Do not pipe binary dumps through Azure interactive exec or install tooling in the running production container.
A named approved private-access client, secure file transfer path and PostgreSQL 16 tooling remain prerequisites. If none exists, local production restore is not yet feasible under current restrictions. Do not open public access or provision a VPN/VM/Bastion as a shortcut.

## Comparison

| Method | Validates | Cost/resource consequence | Limitation |
| --- | --- | --- | --- |
| Synthetic local migration tests (already passed) | Schema behavior and code paths | Local only | Does not validate a real backup or recovery |
| Authorized logical dump + local restore (preferred) | Real database logical schema/data recovery from a consistent snapshot | No new Azure resources; possible egress/access usage | Does not validate Azure managed backups, WAL replay, server roles/network or Azure failover |
| Azure point-in-time restore | Azure backup/WAL recovery to an isolated managed server | Creates another server with compute/storage and potential backup/network charges | Prohibited here; needs separate resource and spending approval |

Managed Azure PITR backup files cannot be downloaded for local restoration. A separately authorized pg_dump is required for a local drill. PITR always creates a new server, rather than overwriting the source. Source configuration is generally inherited; a small source does not make a restored server free.

## Approval and prerequisites before executing any commands below

1. Explicit approval to READ and EXPORT production safecircle_db, including users, accounts, connections, alerts, device tokens, notifications and acknowledgements, to one named encrypted private location.
2. Approve the named existing private-access client and encrypted transfer route, verify zero incremental Azure spending or stop for separate cost approval.
3. Use least-privilege existing source access sufficient for a complete dump; missing privileges must fail, not silently omit tables. No production grants or secret changes are authorized.
4. Install/locate PostgreSQL 16 client tools on that existing client and psycopg2 for the prepared helper. Configure protected libpq service and password files outside the repository, service safecircle-production, host pg-safecircle-student.postgres.database.azure.com, dbname safecircle_db, sslmode verify-full and an appropriate trusted CA. Do not print credentials, embed them in command lines or commit them.
5. Provision an access-restricted encrypted local backup root outside this repository and cloud-sync folders. Verify Docker's data disk is encrypted too. Set retention/secure deletion policy and authorized operators. Do not send dumps or baseline files to chat, Git, telemetry or public CI.
6. Record planned snapshot time, maximum allowed load, RPO/RTO targets and recovery owner. A full logical restore is disaster recovery: using it in production loses changes newer than the snapshot and requires a separately approved outage/recovery plan.

## Exact PowerShell procedure ? prepared, NOT executed

Run export steps only on the approved existing private-access client, after the above approval. Metadata and fingerprints are private recovery artifacts too.

```powershell
$ErrorActionPreference = 'Stop'
$env:PGSERVICE = 'safecircle-production'
pg_dump --version
if ($LASTEXITCODE -ne 0) { throw 'PostgreSQL 16 tools unavailable' }
psql -X -v ON_ERROR_STOP=1 -c 'BEGIN READ ONLY; SELECT current_database(), version_num FROM alembic_version; SELECT extname,extversion FROM pg_extension ORDER BY extname; SELECT pg_database_size(current_database()); ROLLBACK;'
if ($LASTEXITCODE -ne 0) { throw 'Identity/extension/size check failed' }
# Require safecircle_db, e17d6a10bc25, supported local extensions, sufficient disk and confirmed transfer cost allowance.
$drillRoot = Join-Path $env:SAFECIRCLE_BACKUP_DIRECTORY ('drill-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))
# Parent must already be encrypted and restricted; helper creates a NEW child and never overwrites.
python tools/recovery/prepare_logical_backup.py --service safecircle-production --output $drillRoot --approved-production-export
if ($LASTEXITCODE -ne 0) { throw 'Dump/baseline failed; do not claim recovery verified' }
pg_restore --list (Join-Path $drillRoot 'safecircle.dump') | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Invalid archive' }
Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $drillRoot 'safecircle.dump')
```

The helper is prepared and syntax-checked only. It uses a read-only REPEATABLE READ transaction and pg_export_snapshot; pg_dump and all table counts/content digests refer to the SAME snapshot. It includes every ordinary/partitioned public application table, including legacy contacts and devices, and excludes extension-owned reference tables from content comparison. The dump itself covers the entire database. Timeouts bound lock waits and query duration; failed commands retain artifacts for protected review and never produce success evidence.
Large-table fingerprinting sorts row digests and can consume server CPU/memory; approve this only after the size/load check. A 60-second timeout may intentionally abort it. Do not increase limits automatically.

Transfer the entire folder through the separately approved encrypted route to the encrypted local root if the export client is remote. Verify archive SHA256 against evidence.json and separately protect the evidence/verification SQL from tampering. This transfer is not implemented by container exec. Reassign $drillRoot to the local folder below.

```powershell
$evidence = Get-Content -LiteralPath (Join-Path $drillRoot 'evidence.json') -Raw | ConvertFrom-Json
if ((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $drillRoot 'safecircle.dump')).Hash.ToLowerInvariant() -ne $evidence.archive_sha256) { throw 'Backup checksum mismatch' }
# Use already cached local image, preventing an accidental pull/network operation.
$image = 'sha256:44126d872ac91993766c341e369c539e8196614321765d36a6f1bab0419a5fa5'
docker image inspect $image --format '{{.Id}}'
if ($LASTEXITCODE -ne 0) { throw 'Approved local PostGIS image unavailable' }
$container = 'safecircle-restore-drill-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
# No network, published ports, Firebase credentials, app containers or push worker.
# Trust applies only to this disconnected local test container; never production.
docker run --detach --pull never --network none --name $container --env POSTGRES_HOST_AUTH_METHOD=trust --mount "type=bind,source=$drillRoot,target=/recovery,readonly" $image
if ($LASTEXITCODE -ne 0) { throw 'Local isolated container failed' }
$ready = $false
for ($attempt=0; $attempt -lt 30; $attempt++) {
  docker exec $container pg_isready -U postgres *> $null
  if ($LASTEXITCODE -eq 0) { $ready=$true; break }
  Start-Sleep -Seconds 1
}
if (-not $ready) { throw 'Local PostgreSQL not ready' }
docker exec $container createdb -U postgres --template=template0 safecircle_restore_drill
if ($LASTEXITCODE -ne 0) { throw 'Local target creation failed' }
$started = Get-Date
# Keep raw errors inside protected recovery storage, never terminal/chat logs.
docker exec $container pg_restore -U postgres --dbname=safecircle_restore_drill --no-owner --no-acl --exit-on-error --single-transaction /recovery/safecircle.dump *> (Join-Path $drillRoot 'restore-private.log')
if ($LASTEXITCODE -ne 0) { throw 'Restore failed; inspect restricted local log' }
docker exec $container psql -U postgres -d safecircle_restore_drill -X -v ON_ERROR_STOP=1 --single-transaction -f /recovery/verify_restore.sql *> (Join-Path $drillRoot 'validation-private.log')
if ($LASTEXITCODE -ne 0) { throw 'Restored table content or Alembic revision mismatch' }
$elapsed = (Get-Date) - $started
Write-Output ('Local restore and snapshot-content validation succeeded; seconds=' + [Math]::Round($elapsed.TotalSeconds))
# Check constraints/extensions/sequences privately as described below, before declaring gate satisfied.
docker stop $container
if ($LASTEXITCODE -ne 0) { throw 'Local container did not stop' }
```

Keep the stopped container/data volume protected pending the agreed retention/deletion decision. No removal or production restore is authorized by this document. Anonymous Docker data volumes remain after a stopped container; include them in the approved secure-disposal plan.

## Recovery success criteria

- Dump and restore return zero; archive SHA256 matches the protected source evidence; no missing extensions, tables or skipped post-data objects.
- Restored database must be safecircle_restore_drill, never safecircle_db on the production host. Verification asserts exact parent revision e17d6a10bc25, not the new head. No migration is run.
- Every application table count AND sorted row-content digest matches the source snapshot. This covers complete users, trusted-contact links and statuses, legacy manual contacts, alerts/coordinates/statuses, acknowledgements, device registrations/FCM tokens, persistent notifications and push jobs without printing their contents. JSON formatting is pinned to UTC/ISO on both sides.
- pg_restore completes post-data constraints, indexes and sequence restoration without error. Privately compare constraints/indexes and sequence metadata with the snapshot before export approval is closed; flag pre-existing unvalidated constraints explicitly. Role ownership/ACLs intentionally are not restored locally and require an existing production role/grant recovery inventory for disaster recovery.
- For an approved local-only integrity report, use the following query in both the source snapshot and restored database; compare name/type/definition/validation status privately. For sequences, compare last_value/is_called plus ownership associations, and verify they do not precede the related key range. Sequence state is not MVCC-snapshot-consistent during concurrent writes, so document allowable changes or approve a brief controlled quiescence; do not freeze production automatically.

```sql
SELECT n.nspname, c.relname, k.conname, k.contype, k.convalidated,
       pg_get_constraintdef(k.oid)
FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid
JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public' ORDER BY 1,2,3;
SELECT schemaname, tablename, indexname, indexdef
FROM pg_indexes WHERE schemaname='public' ORDER BY 1,2,3;
```

- Record actual snapshot UTC, completed restore time, elapsed recovery duration, accepted RPO/RTO, image ID and private evidence checksum. Do not claim Azure managed PITR was tested.

## Is a local drill sufficient for the release gate?

A successfully verified REAL logical-backup restore can satisfy the narrowly defined release gate of having a tested fallback before this additive migration, IF the user accepts that fallback, its data freshness/RPO, roles/permissions recovery procedure and existing infrastructure access. It cannot certify Azure PITR, geo-recovery, Azure network recreation or Firebase recovery. A synthetic drill or archive-list-only check is insufficient. Production recovery execution always needs its own approval.
Right now NO-GO: export is prohibited, private export access and zero-cost transfer are unproven, and no real restore has run. The release remains blocked; this plan does not waive that gate.

References:
https://learn.microsoft.com/en-us/azure/postgresql/migrate/how-to-migrate-using-dump-and-restore
https://learn.microsoft.com/en-us/azure/postgresql/backup-restore/concepts-backup-restore
https://azure.microsoft.com/en-us/pricing/details/bandwidth/
