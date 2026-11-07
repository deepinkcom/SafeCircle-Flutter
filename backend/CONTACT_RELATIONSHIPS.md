# Emergency contact relationships (Tasks 1 and 2)

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
| Sent invites | `GET /contact-links/invites/outgoing` | Inviter | All invitations sent by the caller, including pending, accepted, rejected, and revoked history |
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

## API reference (Task 2)

Every operation requires a Firebase ID token in the HTTP `Authorization` header
using the `Bearer` scheme, plus an existing linked SafeCircle user profile.
The examples below use fictional accounts and IDs. Do not log authorization
headers or tokens. No new migration is required for Task 2.

The six routes implement seven operations; accept and reject share the existing
response route. Request bodies reject additional fields. Invitation emails are
trimmed and lowercased before looking up an existing user; the caller supplies
neither inviter ID nor a phone number. Email must be 3 to 255 characters.

| Operation | Example request | Success response |
| --- | --- | --- |
| Send invitation | `POST /contact-links/invites` with `{"email":"invitee@example.invalid"}` | `201`, one pending relationship object |
| List received invitations | `GET /contact-links/invites/incoming` | `200`, array of the caller's pending received invitations |
| List sent invitations | `GET /contact-links/invites/outgoing` | `200`, array of all invitations created by the caller |
| Accept invitation | `POST /contact-links/123/respond` with `{"action":"accept"}` | `200`, relationship object with `status: accepted` and a response timestamp |
| Reject invitation | `POST /contact-links/123/respond` with `{"action":"reject"}` | `200`, relationship object with `status: rejected` and a response timestamp |
| Revoke relationship | `DELETE /contact-links/123` with no body | `200`, relationship object with `status: revoked` and a revocation timestamp |
| List accepted contacts | `GET /contact-links/relationships` | `200`, array of accepted relationships involving the caller |

Sent invitations include all four statuses so the inviter can track responses
and revocations. They are ordered by `created_at` descending, then `id`
descending for tied timestamps. Incoming invitations are ordered by creation
time descending; accepted relationships by update time descending. All lists
return `[]` when empty and currently return the entire matching list without
pagination. Each list is scoped to the authenticated caller. Listing does not
update timestamps, relationship state, or legacy contacts.

### Response examples

Successful mutations return the same object shape. For example, sending an
invitation as fictional user 41 to fictional user 42 returns `201`:

```json
{
  "id": 123,
  "inviter_user_id": 41,
  "invitee_user_id": 42,
  "status": "pending",
  "created_at": "2026-11-07T10:00:00Z",
  "updated_at": "2026-11-07T10:00:00Z",
  "responded_at": null,
  "revoked_at": null,
  "other_user_id": 42
}
```

Each list returns an array of those objects. For example, after user 42 accepts,
user 41's outgoing list and accepted relationship list include:

```json
[
  {
    "id": 123,
    "inviter_user_id": 41,
    "invitee_user_id": 42,
    "status": "accepted",
    "created_at": "2026-11-07T10:00:00Z",
    "updated_at": "2026-11-07T10:05:00Z",
    "responded_at": "2026-11-07T10:05:00Z",
    "revoked_at": null,
    "other_user_id": 42
  }
]
```

`other_user_id` is always relative to the caller: user 42 sees 41 in their
incoming list and in the response when accepting or rejecting. Pending
invitations have null response and revocation timestamps. Accepting or rejecting
sets `responded_at` and `updated_at` to the same time, preserves `created_at`,
and removes the row from the incoming list. Rejection returns the same object
shape with `status: rejected`; it remains in the sender's history but is absent
from accepted contacts.

Revocation changes `status` to `revoked` and sets `revoked_at` and `updated_at`
to the same time. Any earlier response timestamp is retained. It returns the
object rather than `204` and does not physically delete the relationship.
The sender still sees that row in outgoing history; neither participant sees it
as an accepted contact. A new invitation after rejection/revocation creates a
new relationship ID, leaving the original history intact.

### Errors and status codes

| Status | When | JSON detail |
| --- | --- | --- |
| `400` | Sending an invitation to yourself | `You cannot invite yourself` |
| `401` | Missing Firebase token | `Missing Firebase ID token` |
| `401` | Invalid or expired Firebase token | `Invalid or expired Firebase ID token` |
| `401` | Decoded identity has no UID | `Invalid Firebase identity` |
| `403` | Verified Firebase account has no SafeCircle profile | `Firebase account is not linked to a SafeCircle user profile` |
| `404` | No registered recipient, or ambiguous case-variant email records | `SafeCircle user not found` |
| `404` | Invitation missing, or caller is not its invitee | `Invitation not found` |
| `404` | Relationship missing, or caller is not a participant | `Relationship not found` |
| `409` | Active invitation/relationship already exists in either direction | `An active relationship or invitation already exists` |
| `409` | Competing insert loses the database uniqueness race | `An active invitation already exists` |
| `409` | Accepting/rejecting a row that is no longer pending | `This invitation has already been processed` |
| `409` | Revoking a rejected/revoked row | `This relationship is no longer active` |
| `422` | Missing/invalid body fields, extra body fields, invalid action, or noninteger path ID | FastAPI validation detail array |

HTTP errors use the standard `detail` envelope, for example:

```json
{"detail": "Invitation not found"}
```

Unauthorized callers receive the same `404` response as missing records on
respond/revoke, so these operations do not disclose other users' relationships.
Only `pending` rows can be accepted/rejected, and only `pending`/`accepted` rows
can be revoked. No operation promotes rejected/revoked history to accepted.
Knowing a recipient email or legacy phone number never grants authority to
respond as that recipient or creates an automatic account link.

## Registered-user discovery for Flutter

`GET /users/search` uses the existing users router and Firebase authentication.
Both the caller and target must have an existing backend `users` profile; it
does not enumerate Firebase accounts. The existing profile fields are `name`,
`email`, `city`, and `phone`, plus internal `id`, `firebase_uid`, and `created_at`.
There is no username, public handle, or discovery-consent setting in the schema.

For this invitation workflow, discovery is a **complete-email lookup**, not a
public directory. The caller must already know the recipient's email. Broad
name, city, phone, prefix, domain-only, wildcard, and blank searches cannot
list accounts. This reduces enumeration compared with substring search;
it still confirms registration for a supplied full address. The endpoint does
not introduce a shared rate limiter or prevent repeated guessed-address checks.

### Request

```http
GET /users/search?q=invitee%40example.invalid
```

Use the same Firebase bearer authorization header as the existing API methods.
`q` is required. Surrounding whitespace is trimmed; the remaining value must
be 3 to 255 characters, have exactly one `@`, a dot in the domain portion,
and no whitespace. Matching is case-insensitive against the whole email.
`%`, `_`, and other SQL metacharacters are literal characters, never wildcards.
This is email-shaped lookup validation, not deliverability or ownership
verification; only Firebase authentication and the invitation response establish
the caller's identity and the recipient's consent.

### Response

HTTP `200` returns a JSON array containing **zero or one** object:

```json
[
  {
    "name": "Example Invitee",
    "email": "invitee@example.invalid"
  }
]
```

Only `name` and the matched, already-supplied `email` are returned. No internal
user ID, Firebase UID, city, phone, creation time, device token, or relationship
details are exposed. The response uses `Cache-Control: no-store`. The query
selects only those two response fields using bound equality parameters.

`[]` is returned when no account matches, the account is the authenticated
caller, or multiple other accounts differ only in email casing. The lookup
reads at most two candidates to detect ambiguity and never returns more than
one. There is no paging or adjustable result limit; additional `limit`,
`offset`, or `page` parameters cannot expand the result set. Ambiguous profiles
are not merged, updated, or automatically linked.

Expected errors are `401` for missing/invalid Firebase authentication, `403`
for a verified Firebase identity without a linked SafeCircle profile, and `422`
for a missing or invalid `q`. Errors use the existing `detail` envelope (a
validation detail array for `422`). Unknown/self/ambiguous matches use `200 []`
rather than a distinct account-specific error. The endpoint performs no writes.

### Flutter integration

The existing `lib/services/api_service.dart` provides `_authHeaders()` and JSON
list decoding patterns but has no user-search method yet. No Flutter files are
changed by this backend task. A future service method can build the URI with
`Uri.replace(queryParameters: {'q': email.trim()})`, perform an authenticated
GET, and decode the response as a list. Use query-parameter encoding so `+`,
`&`, and other address characters are preserved; do not concatenate raw input
into the URL. Request lookup when a complete address is submitted rather than
on every partial keystroke. Do not log email queries or authorization headers.

After confirmation by the caller, pass the returned `email` unchanged in
`POST /contact-links/invites` as `{"email":"invitee@example.invalid"}`. The
invitation lookup uses the same case-insensitive exact email comparison,
supports stored mixed-case addresses, and returns `404` on ambiguous case
variants instead of choosing an arbitrary recipient. All existing duplicate,
self-invitation, authorization, lifecycle, and database constraints still apply.
Discovery never creates a relationship or converts a phone-only contact.
`POST /users/me` is unchanged. No schema change or migration is required.

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
