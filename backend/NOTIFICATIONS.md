# Persistent notification inbox (Stage 3B)

This stage adds recipient-owned history and read state to the existing FastAPI
application. It does **not** add Flutter screens, Firebase push delivery, nearby
subscriptions, emergency recipient selection, or historical backfills. No live
development database migration is authorized by implementing this code.

## Storage and event policy

`notifications` contains:

| Field | Contract |
| --- | --- |
| `id` | Unique backend integer notification ID |
| `recipient_user_id` | Required FK to `users.id`; derived by the backend |
| `category` | `connection` or `emergency` |
| `event_type` | Nonempty string, maximum 64 characters |
| `source_id` | Positive integer relationship/alert source ID |
| `created_at` | Required server creation time; API serializes UTC ISO date-time |
| `read_at` | Nullable UTC ISO date-time; null means unread |
| `title` | Safe nonempty display text, maximum 160 characters |
| `message` | Safe nonempty display text, maximum 500 characters |

The database unique key is `(recipient_user_id, category, event_type, source_id)`.
Repeated event recording cannot create another row for that same logical event.
The producer returns an existing event without resetting its timestamp or read
state. Recipient/time/ID and partial unread indexes support inbox reads.

The source ID is deliberately not a cascading foreign key: event history remains
if a relationship/source is later removed. Deleting a user cascades only that
user's inbox. A notification does not grant access to its source; consumers must
use the existing authenticated source endpoints and handle unavailable sources.

Real connection mutations generate these events:

| Operation | Event type | Recipient |
| --- | --- | --- |
| Invitation created | `connection.invited` | Invitee |
| Invitation accepted | `connection.accepted` | Inviter |
| Invitation rejected | `connection.rejected` | Inviter |
| Pending/accepted relationship revoked | `connection.revoked` | Other participant, whichever participant acted |

No self-notification is created for the actor. Pending cancellation uses the
same revoked event. A new invitation after a terminal relationship has a new
source ID and therefore a distinct notification. Invalid/unauthorized transitions
create no events. Static templates deliberately exclude account email, phone,
Firebase identity, coordinates, credentials, and provider exception text.

Events are not rewritten or removed when the source becomes accepted, rejected,
or revoked. Original invitation notifications remain history; current actionable
state must be obtained from the relationship APIs. Accepting, rejecting, revoking,
or acknowledging an emergency does not mark anything read. Reading/unreading a
notification never changes its source.

Existing counterparty-null safety is preserved for already-inconsistent orphaned
links: when the other user's row no longer exists there is no recipient inbox,
so no new event is produced or assigned to a substitute account. Normal enforced
user FKs cascade such relationship deletion. For every existing recipient,
notification persistence is mandatory and shares the relationship transaction.

`emergency` is supported for storage/filtering/read counts but **no emergency
producer is enabled in Stage 3B**. Production inboxes will not receive invented
emergency entries. Panic creation, acknowledgement, resolution, nearby spatial
rules and legacy phone contacts remain unchanged. Accepted connections are not
automatically selected as emergency recipients. The development test-push route
is not used as an inbox producer.

## Authentication and privacy

All three routes use the existing Firebase bearer verification and linked-user
dependency. Recipient scope always comes from the verified account, never from
client query/body user IDs. GET responses and successful PATCH responses use
`Cache-Control: no-store`. No caller can create notifications or edit their
content/source/recipient through this API.

Errors use the existing `{"detail": ...}` envelope:

- `401`: missing/invalid Firebase authentication.
- `403`: authenticated identity without a linked backend profile.
- `404`: PATCH target is missing or belongs to another recipient; same response.
- `422`: invalid category, bounds, path ID, body shape or non-boolean `read`.
- `500`: unexpected persistence failure; no raw SQL/provider/exception body is
  intentionally returned. Deploy without debug exception exposure.

## GET /notifications

Optional parameters:

- `category=connection|emergency`; omitted means both categories.
- `unread_only=true|false`; default false.
- `limit`: integer 1-100, default 20.
- `offset`: integer 0-1,000,000, default 0.

Success: HTTP 200, newest `created_at` first, then highest `id` for ties.
No GET operation marks records read.

Fictional response for `GET /notifications?category=connection&limit=20&offset=0`:

```json
{
  "items": [
    {
      "id": 17,
      "recipient_user_id": 42,
      "category": "connection",
      "event_type": "connection.invited",
      "source_id": 123,
      "created_at": "2026-11-08T10:00:00+00:00",
      "read_at": null,
      "title": "SafeCircle invitation",
      "message": "A SafeCircle member sent you a connection invitation."
    }
  ],
  "total": 1,
  "limit": 20,
  "offset": 0,
  "has_more": false
}
```

`total` counts all of the caller's matching records, including any unread-only
filter. Empty pages return `items: []`; an offset past the end is not an error.
`has_more` compares the returned range with total. This is offset pagination:
new inserts between requests may shift pages. Refresh from offset zero and
deduplicate IDs in future clients; it is not a cross-request snapshot/cursor.
Unread totals must come from the count endpoint, not from one page's length.

## GET /notifications/unread-count

Optional `category=connection|emergency`. HTTP 200:

```json
{"unread_count": 3}
```

Only the current recipient's rows with null `read_at` are counted. Omitting the
category gives the combined count. Empty inboxes return zero.

## PATCH /notifications/{notification_id}

The complete permitted body is a required strict JSON boolean:

```json
{"read": true}
```

HTTP 200 returns the complete notification object, using the same shape as each
GET page item. `true` sets server UTC `read_at` only if previously unread;
repeating true preserves the original read time. `{"read": false}` clears it;
repeating false is safe. Strings/numbers/null are not accepted as booleans.
Extra fields, including `recipient_user_id`, `read_at`, and title, are rejected.

PATCH selects the recipient-owned row with `FOR UPDATE` under PostgreSQL so
concurrent read-state updates serialize. It does not implement a source action,
bulk marking, deletion, or notification creation.

## Transaction boundaries and failure handling

`record_connection_event()` uses the caller's SQLAlchemy Session and never
commits independently. Creation first flushes the relationship to obtain its
ID and preserve existing duplicate-pair conflict handling. Then it records and
flushes the notification before the single commit. Responses/revocation retain
the existing relationship row lock and include the new event before committing.

Any notification insert or commit failure rolls back the whole relationship
operation; notification failure is not ignored or reported as a successful
invitation. Event persistence failures are not falsely translated into the
existing duplicate-invitation 409. The unique event key is the final DB guard;
relationship locks/active-pair constraints remain in place. A response/identity
read could still fail after a successful commit, so clients should retain their
existing uncertain-outcome reconciliation rather than blindly repeat mutations.

## Migration and deployment prerequisites

- New revision: `b6e9c2d4f810_add_persistent_notifications.py`.
- Parent/current prior source head: `8c2f7d1a6b90`.
- Earlier revision `2549fa7ab98a` is unchanged.
- Upgrade creates only the notifications table, constraints and indexes. It does
  not mutate legacy contacts/relationships/users or synthesize old events.
- Existing pending invitations remain available in their existing list even
  though no notification is backfilled for them. Future real transitions create
  new events. Historical backfill would need separate approval and policy.

**Migration must precede deployment of the new mutation handlers.** Missing table
or permission errors fail and roll back relationship writes; there is no fallback
that silently drops notifications. Coordinate a maintenance/deployment window,
verified backup and target verification. Do not apply this revision to the
development database or inspect its state without separate explicit approval.

Only after such approval, an operator should activate the intended backend
environment, securely verify the target without printing credentials, and use:

```text
python -m alembic current
python -m alembic upgrade b6e9c2d4f810
python -m alembic current
```

Expect prior revision `8c2f7d1a6b90`; if different, stop and review the unapplied
chain before any change. Alembic's oldest relationship migration assumes an
existing users baseline: do not use `upgrade head` to initialize a blank
production database without the baseline plan. Keep the migration/schema
prerequisite for app startup/deployment explicit.

Downgrade to the parent drops all notification history. It requires explicit
approval, backup/restore planning and a compatible backend rollback first.
Never use downgrade as routine cleanup or go below existing relationship
revisions. No development migration or Docker operation was run for this stage.

## Automated verification and limitations

From `backend`, using the existing isolated test environment:

```powershell
..\.venv-backend-test\Scripts\python.exe -m pytest tests -q -p no:cacheprovider
..\.venv-backend-test\Scripts\python.exe -m compileall -q app migrations tests
```

`tests/conftest.py` sets a SQLite memory URL before application imports. Integration
fixtures use new SQLite files under pytest temporary storage, real SQLAlchemy
models/transactions and synthetic Firebase identities. No real identity checks,
push deliveries or development database connections are used.

Tests cover ownership/authentication, strict input bounds, filtered counts and
pages, UTC/read-state idempotence, all connection event recipients, history,
duplicate prevention, failed inserts/commits and whole-operation rollback,
legacy contacts, unchanged contact APIs and controlled emergency-route
regressions. Real Alembic upgrades/downgrades are tested only in disposable files;
PostgreSQL DDL is rendered offline. Emergency spatial SQL is compiled for
PostgreSQL with controlled storage responses, not executed against PostGIS.

Real PostgreSQL row-lock/concurrency behavior and a production-like migration
rehearsal remain unverified here and require an approved disposable PostgreSQL
environment. Do not treat SQLite or SQL rendering as that evidence. Full
PostGIS/delivery/device integration and Flutter Notifications UI belong to later
approved stages. This implementation introduces no background worker, outbox,
notification push sender or emergency subscription policy.

## Stage 3C.1 / 3D extension

The retention follow-up is documented in
[Push-delivery retention](../docs/PUSH_DELIVERY_RETENTION.md). New revision
`d9a4f6b2c730` follows `c7f0a3e5b921` and has been verified in local development.
Other environments require separate migration and API/worker restart approval.
Physical Android account-isolation and real FCM retesting remain pending.
Inbox contracts and emergency policy are unchanged.

The later notification-management and connection-push implementation supersedes
this document's original no-worker scope statement. See
[Stage 3C.1 / 3D status](../docs/STAGE_3C1_3D_STATUS.md) for API extensions,
soft-delete retention, migration c7f0a3e5b921, explicit worker deployment,
verification boundaries and incomplete emergency delivery/profile photos.
