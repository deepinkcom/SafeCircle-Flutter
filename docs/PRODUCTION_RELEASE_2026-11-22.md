# Production release verification - 22 November 2026

The production backend release completed successfully. This report supersedes
the historical NO-GO status in the earlier release and recovery preparation
documents. The deployment was explicitly approved after recovery verification.

## Migration and recovery

- Database: `safecircle_db` on the existing private PostgreSQL 16 server.
- Alembic revision: `e17d6a10bc25` -> `a91b8c7d6e5f`.
- One guarded migration attempt completed successfully, with zero retries.
- TLS `verify-full`, a 5-second lock timeout, a 60-second statement timeout,
  database/schema identity checks, a transaction advisory lock, and a locked
  parent revision check were enforced. The exact migration source SHA256 was
  `91043ab024614927a8e0d7630bdfddee40df5fe26277ce492ed5d1c130aaf941`.
- Schema and revision were verified before commit and again in a read-only
  transaction after commit. No schema downgrade was performed.
- Accepted recovery evidence: backup run `20261121T115041Z`, archive SHA256
  `8860eec30d4435f8377756747cff60a9e2b68108a9d743c42f438c974d24bc5b`,
  isolated PostgreSQL 16 restore with matching schema/data fingerprints and
  parent Alembic revision. The archive was not downloaded or rehashed during
  this release; the previously verified evidence was supplied and accepted.

The migration ran in a separate process inside the existing API replica, with
the exact migration source loaded and hash-checked in memory. Credentials
remained inside that protected environment; none were exported or printed.
The initialization job was not started, repurposed, or modified.

## Deployed image and final checks

Both applications use the approved immutable image:

`safecirclestudentacr.azurecr.io/safecircle-api@sha256:3af46d3238ee8d7713230c257b84705930e67fad1fa1aae6379f98aa3723e3c7`

| Application | Verified revision | Result |
| --- | --- | --- |
| Push worker | `safecircle-push-worker--0000005` | Healthy; one ready replica |
| API | `safecircle-api--0000003` | Healthy; one ready replica |

The worker passed before the API update. Final checks confirmed the image on
both apps, healthy revisions, ready replicas without restarts, unchanged
non-image configuration, `/health` = `ok`, `/health/ready` = `ready`, and the
`DELETE /devices/installation` operation in OpenAPI. No production test alert,
notification, account mutation, or device-cleanup request was used as a probe.
Environment settings, secret references, identity, ingress, networking, and
scaling were preserved. PostgreSQL public access and authentication were not
changed. No new Azure resource was provisioned.

## Guarded rollout history

Two earlier rollout attempts stopped at conservative platform log checks.
Each affected image was individually rolled back and verified healthy; when
both apps had been changed, the API was rolled back before the worker. The
expanded schema was retained throughout.

Review established an identical pre-existing KEDA trigger warning on the
fixed-one-replica worker, and a generic scaling-target-not-yet-created event
before container startup. The log checker was corrected to read the platform
`Msg` field. It reports the exact known worker warning separately and accepts
the exact transient target event only when it precedes a subsequent successful
container-start event and revision/replica health checks pass. Validation
confirmed that the same target warning after startup still blocks release.
All other warnings and application startup errors remain blocking.

The final worker log review checked 11 records, with three known existing
scaling warnings and no other warning/error found. The final API review
checked 22 records and found no warning/error. The migration was not repeated
during the image rollout attempts.

## APK and remaining work

The previously built APK has SHA256
`84debc8d08fbded1d31a9f06279839a1b1ef5428a86a4d31ca900d87d60ca584`.
No new APK was built or installed during the production release or GitHub
push. The user will install it later. Physical phone login, logout, push,
location, and photo acceptance checks remain separate from backend deployment.
This report does not assert that every later local Flutter change is contained
in that existing APK.

Temporary recovery resources were retained to preserve the protected backup
and verification evidence. The restore VM is deallocated. Backup storage has
public network access disabled and blob public access disallowed. Cleanup
remains pending and must preserve the archive and recovery evidence.

The old Markdown plans, source manifest, and recorded test counts are historical
snapshots. They are not a current working-tree fingerprint or proof that a later
APK was rebuilt. The fork commit containing this report records the source and
documentation state at push time; Azure runs the immutable image above.

## Source push verification

Before the fork push, all 476 Flutter tests passed, Flutter analysis reported
no issues, and `git diff --check` passed. Pending files were checked for private
key and credential markers; none were found. Firebase Android JSON is client
configuration, not a service-account credential. The empty accidental
`-Recurse` file is excluded from the commit.
