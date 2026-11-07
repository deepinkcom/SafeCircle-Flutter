# Emergency contact relationships (Task 1)

`emergency_contact_links` records explicit invitations between existing `users`
rows. It is separate from the legacy phone-based `emergency_contacts` table.
No phone matching, backfill, account linking, legacy-contact conversion, contact
selection persistence, Flutter UI change, or push delivery is performed here.

## Schema

| Field | Contract |
| --- | --- |
| `id` | Integer primary key |
| `inviter_user_id` | Required foreign key to `users.id` |
| `invitee_user_id` | Required foreign key to `users.id`; must differ from inviter |
| `status` | Required: `pending`, `accepted`, `rejected`, or `revoked`; defaults to `pending` |
| `created_at` | Required UTC creation timestamp; database default `CURRENT_TIMESTAMP` |
| `updated_at` | Required UTC timestamp; updated by the application on transitions |
| `responded_at` | Nullable; set when the invitee accepts or rejects |
| `revoked_at` | Nullable; set when a participant revokes the link |

The foreign keys retain the applied migration's `ON DELETE CASCADE` behavior.
The new revision does not change foreign keys or delete any rows. The partial
unique index covers the lower and higher user IDs, independent of direction,
only while status is `pending` or `accepted`. Rejected/revoked records remain
as history and permit a new invitation with a new ID in either direction.

## Lifecycle and authorization

All routes use the existing Firebase token verification and local user lookup.
Caller identity comes from the verified Firebase UID, never a request-body user
ID or a phone match. Invitations target an existing profile by email; knowing
an email does not establish a relationship. The invitee must authenticate and
explicitly accept. This flow never verifies ownership of a legacy phone number.

| Operation | Route | Who can act | Result |
| --- | --- | --- | --- |
| Invite | `POST /contact-links/invites`, `{"email":"user@example.invalid"}` | Authenticated inviter | New `pending` row, HTTP 201 |
| Incoming invites | `GET /contact-links/invites/incoming` | Invitee | Only that user's pending invitations |
| Accept/reject | `POST /contact-links/{id}/respond`, `{"action":"accept"}` or `{"action":"reject"}` | Invitee only | `pending` to `accepted`/`rejected`; records response time |
| Eligible relationships | `GET /contact-links/relationships` | Either participant | Only accepted links involving the caller; `other_user_id` identifies the eligible other account |
| Revoke | `DELETE /contact-links/{id}` | Either participant | `pending`/`accepted` to `revoked`; records revocation time |

Acceptance makes the invited account eligible for emergency-contact selection.
It does not automatically create or enable a legacy contact. Pending, rejected,
and revoked links are excluded from the accepted relationships endpoint.
An accepted response timestamp is retained after revocation. Terminal records
cannot be accepted/rejected again; rejected/revoked records cannot be revoked
again. These invalid transitions return HTTP 409. Self-invitations return 400;
duplicate active pairs return 409. Missing/unauthorized records return 404.
The inviter cannot accept on the invitee's behalf. Outsiders cannot read a
relationship through these lists, respond, or revoke it.

Accept/reject and revoke lock the row with PostgreSQL `SELECT ... FOR UPDATE`
before checking status. Concurrent lifecycle requests therefore check the
latest committed state after obtaining the lock. The unique database index
arbitrates competing invitation inserts, including reverse-direction races;
the existing insert handler rolls back an integrity conflict and returns 409.
Status transition authorization is enforced in the API, not by a database
trigger; direct database access remains a privileged administrative operation.

Legacy `GET /contacts`, `POST /contacts`, and `PATCH /contacts/{id}` and the
`EmergencyContact` model are unchanged. Legacy contacts can still exist without
an associated SafeCircle account or relationship.

## Migration procedure (requires approval before development DB execution)

The applied revision `2549fa7ab98a` is unchanged. Its directional index cannot
prevent two concurrent invitations in opposite directions. New revision
`8c2f7d1a6b90`, whose parent is `2549fa7ab98a`, builds the stronger index first,
then drops the directional index. It does not alter columns or rewrite data.
PostgreSQL runs this in Alembic's normal transaction. If conflicting active
pairs already exist, unique index creation fails and the revision is not
advanced; the old index and all data remain. Do not automatically delete,
merge, or revoke conflicting rows. Stop and seek explicit approval for any
data remediation.

After explicit approval, an operator should:

1. Back up the target database and arrange a maintenance window. Ordinary index
   creation blocks writes to the relationship table while it builds.
2. Activate the backend environment, change to `backend`, and confirm the
   intended target through secure configuration. Do not print credentials.
3. Run `python -m alembic current`; expect `2549fa7ab98a`. Stop on an unexpected
   revision. Do not rerun/edit the applied revision or use `stamp` as a shortcut.
4. Check for conflicts using the read-only query below. A nonempty result needs
   separate review and approval; the migration also enforces this check through
   unique index creation, including concurrent inserts.
5. Run `python -m alembic upgrade 8c2f7d1a6b90` and confirm the new revision with
   `python -m alembic current`. Verify accepted-link listing and unchanged
   legacy contact counts/data before reopening writes.

```sql
SELECT COUNT(*) AS active_count
FROM emergency_contact_links
WHERE status IN ('pending', 'accepted')
GROUP BY
  CASE WHEN inviter_user_id < invitee_user_id
       THEN inviter_user_id ELSE invitee_user_id END,
  CASE WHEN inviter_user_id < invitee_user_id
       THEN invitee_user_id ELSE inviter_user_id END
HAVING COUNT(*) > 1;
```

Only if a rollback is approved, `python -m alembic downgrade 2549fa7ab98a`
reverses the new revision's index change without deleting data. It reintroduces
the weaker directional guarantee, so pause relationship writes and coordinate
application rollback. Do not downgrade below `2549fa7ab98a`: the older revision's
downgrade drops the relationship table.

## Automated verification

From `backend`, install `python -m pip install -r requirements-test.txt` in an
isolated environment, then run:

```text
python -m pytest tests -q -p no:cacheprovider
python -m compileall -q app migrations tests
```

`tests/conftest.py` forces application settings to a SQLite memory URL before
test imports. Integration fixtures create fresh SQLite files under pytest's
temporary directory and override database dependencies; they never use a
development database URL. Firebase verification is replaced with synthetic
identities while exercising the real authentication dependency. No live
Firebase requests or push deliveries are made.

Migration tests create users and legacy contacts in a disposable database,
apply the historical revision there, then run the real Alembic upgrade to the
new revision. They verify full row preservation, invalid schema inputs,
duplicate/reverse pair enforcement, failure without data deletion when old
conflicts exist, and downgrade/reupgrade of only the new revision. Additional
API tests exercise lifecycle, timestamps, eligibility, participant permissions,
authentication, duplicate/self invitations, terminal states, and legacy CRUD.
The PostgreSQL migration DDL is also rendered without connecting to a server.

SQLite cannot prove PostgreSQL row-lock behavior, transactional DDL, or races.
Before applying this to development/production, rehearse upgrade, downgrade,
conflict failure, and simultaneous opposite-direction invites and responses
against a separately provisioned disposable PostgreSQL database. Do not use the
development database as that test target. The historical migration assumes
`users` already exists; supply the existing baseline schema in the disposable
database before exercising the revision chain.
