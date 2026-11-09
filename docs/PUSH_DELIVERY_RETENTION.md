# Push-delivery retention and logout safety

## Schema and behavior

Revision `d9a4f6b2c730` follows `c7f0a3e5b921`. It makes
`push_deliveries.device_id` nullable and replaces its device FK with `ON DELETE
SET NULL`. It preserves the notification FK, notification/device unique constraint
and scheduling index, and adds `ix_push_delivery_device` for device cleanup.
Existing delivery rows are not rewritten or backfilled. No raw token, email or
Firebase UID is copied into history.

Logout physically removes the registration. Sent/failed/cancelled deliveries keep
their IDs, statuses and attempts, with a null device reference. Pending/sending
jobs are cancelled in the deletion transaction. Recipient identity remains available
through the notification. Detached jobs are never reattached to a new registration,
even if a token matches. Inbox soft deletion retains history and suppresses sends;
physical notification/account deletion still removes history under the existing policy.

## Worker and transaction guarantees

Claims use `FOR UPDATE SKIP LOCKED`, increment attempts and commit a two-minute
lease. Attempts form a monotonic generation and are never reset. Final processing
locks device, notification, then job; cleanup locks device, then unfinished jobs in
ID order. Claiming never waits on a device lock. After lock acquisition the worker
rechecks generation, sending status, expiry, device, category, suppression and owner.
Stale/expired workers cannot submit or overwrite newer state.

The device lock stays held through FCM submission. Logout waits for an in-progress
submission, then cancels remaining work and deletes the registration atomically.
After confirmed logout, no new submission can use that removed registration.
Lock queues can delay logout; the existing Flutter cleanup barrier reports timeout
and retry rather than claiming completion prematurely.

The existing Firebase SDK/payload executes in a spawned process with a 20-second
submission deadline. Token/recipient data travel only through process memory/IPC;
the child returns a fixed result category. On timeout the child is terminated and
joined (with kill fallback) before releasing the device lock. A timed-out thread
would not provide this guarantee. Firebase project/configuration/SDK options are
unchanged. Process startup and teardown add overhead. Injected test senders control
their own synchronization; only the default production sender uses this boundary.

Invalid registration/sender mismatch marks the attempted job failed, cancels other
unfinished jobs, removes the device and retains history. Transient/uncertain failures
use the existing backoff and five-attempt cap. FCM and PostgreSQL cannot commit
atomically: acceptance followed by worker/commit failure can lead to a retry.
Delivery remains at-least-once; stable notification IDs support client deduplication.
Logout cannot retract a message already accepted by FCM.

## Isolated verification

The opt-in PostgreSQL module is hard-wired to `127.0.0.1:52156`, database
`safecircle_retention_test_20261109`, with synthetic test-only credentials. There is
no configurable URL or fallback to development. Each test validates the database
name and uses a random private schema, removed afterward. The container
`safecircle-retention-verify-20261109` uses tmpfs data storage and no production mounts.

After separately establishing that disposable container, from `backend`:

```powershell
$env:SAFECIRCLE_RETENTION_POSTGRES = '1'
$testTemp = Join-Path $env:TEMP ('safecircle-retention-' + [guid]::NewGuid().ToString('N'))
..\.venv-backend-test\Scripts\python.exe -B -m pytest tests -q -p no:cacheprovider --basetemp $testTemp
```

Without the flag, PostgreSQL-specific tests explicitly skip. Other backend tests use
disposable SQLite databases. Process tests exercise success/failure/invalid results
and real child termination without Firebase credentials or network. PostgreSQL tests
cover migrations, preservation, SET NULL, uniqueness, logout, invalid tokens, retries,
rollback, locks, lease reclamation, account isolation and online/offline downgrade guards.

Verification on 2026-11-09: the initial PostgreSQL regression reproduced history loss
(two failures before implementation). The affected suite then passed 70 tests.
Final full backend suite: **326 passed, 810 deprecation warnings, 68.52 seconds**,
including 21 PostgreSQL cases and four bounded-process cases. Python syntax checks
passed for nine changed/new Python files; Git whitespace and secret-pattern checks
passed. The disposable test container was removed after verification. Development
was then at c7f0a3e5b921 with 0 devices, 0 deliveries and 11 notifications; its original
CASCADE FK was confirmed unchanged in a read-only transaction. API and original
worker stayed running. No real FCM submission or physical-device retest was performed.

## Verified local development status

After separate approval, the development migration to `d9a4f6b2c730` completed with
exit code 0. A full backup passed an isolated template0 restore, including semantic
verification of PostgreSQL's equivalent array-cast renderings. Pre/post-migration
counts, application row fingerprints and sequence states were preserved: 2 users,
7 connections, 11 notifications, 0 devices and 0 deliveries. The nullable SET NULL
device FK, preserved notification FK/uniqueness/scheduling index and new device index
were verified. One compatible API and worker were restarted; API health returned 200
and the worker connected without startup errors. Deleted jobs 1-3 were not recreated.

**Physical Android account-isolation and real FCM retesting of the combined changes
are postponed and remain pending.** No invitation or FCM message was sent during
migration verification. An authenticated API read after restart was not verified
because the existing private sender session expired; legitimate sign-in is required
before sender testing. Automated tests and earlier device tests do not replace this
remaining verification. This status does not claim production deployment or approval.

## Procedure for another environment

Migration and service restarts require separate approval for each environment.
Do not start this worker against the old schema. After review and explicit approval:

1. Verify branch/diff, exact database target and current revision `c7f0a3e5b921`.
2. Create and validate a fresh full backup including delivery rows, outside tracked
   source. The pre-c7 backup cannot recover jobs deleted after that migration.
3. Pause writes and gracefully stop API and worker in a coordinated window.
4. From `backend`, using `.venv-backend-test` and the established configuration,
   run `python -m alembic upgrade d9a4f6b2c730`. Use a bounded lock timeout; stop on
   unexpected errors without destructive recovery.
5. Verify revision, nullable device FK, preserved notification FK/uniqueness/indexes
   and complete before/after delivery snapshots.
6. Start compatible API and worker, check health and sanitized logs.
7. Retest physical-device registration, delivery, logout retention, account switching
   and foreground/background/swiped-away delivery and navigation.

This migration never synthesizes deleted jobs 1-3.

## Rollback and retention limits

Downgrade locks the delivery table and refuses before DDL if detached history exists.
Generated PostgreSQL downgrade SQL has the same guard. It never deletes rows or
invents registrations to satisfy NOT NULL. If all jobs remain attached, downgrade
restores the old FK/nullability and removes only the new index. Once detached history
exists, prefer a forward fix. Backup restoration would lose later writes and needs
separate approval and reconciliation.

Physical notification/account deletion policy is unchanged. Define history retention,
authorized reporting and eventual purge policy before production; notification
references remain personal data. No per-attempt audit, completion timestamp, original
device snapshot or provider message ID is added. Native PostgreSQL logging and old
sensitive logs remain separate operational concerns. Never log raw provider/SQL errors.
