# Stage 3C: Flutter notification inbox

`NotificationsState`, owned by the existing AppState, shares its injected API
client and Firebase session. Notification routes use that same Provider instance.
The typed `AppNotification`/`NotificationPage` models match Stage 3B's fields and
UTC timestamps. Unknown categories display as notifications but never trigger a
guessed source action. HTTP failures retain only existing safe ApiFailure data.

The inbox uses GET /notifications with backend category, limit and offset;
GET /notifications/unread-count supplies the combined unread badge count;
PATCH /notifications/{id} sends only `{"read": true|false}`. No count is inferred
from a filtered page. Initial/page/count failures remain distinguishable from an
empty successful response. Offset page overlaps are deduplicated by ID; refresh
starts again at zero. Offset pagination cannot provide a cross-request snapshot.

All, Emergency Alerts and Connections filters use server filtering. Read status
changes wait for server confirmation. Uncertain writes reconcile page/count
before another attempt; failed reconciliation keeps a recovery gate. Failed
refreshes retain prior data. Logout, account changes, access failures and disposal
invalidate pending work and clear protected caches/counts as appropriate.
Source lookups also stop navigation after Back closes the originating inbox;
notification-opened history/nearby screens are guarded by the originating session.

Home and Emergency Contacts open one Notifications route. The shared bell shows
a badge only for a known positive backend count. Failed count refreshes retain
the last backend count with an unavailable-count tooltip; an unknown count is not
presented as zero. Counts refresh on main-shell entry, app resume, inbox entry,
read changes and navigation return. No polling, FCM delivery, new FCM listeners,
database changes or fabricated runtime records are introduced.

Opening an unread notification attempts mark-read, independently of its source.
It never accepts/rejects/revokes an invitation or acknowledges an emergency.
Connection destinations refresh ContactLinksState first, then select Received,
Connections or Sent according to current server lists. Terminal incoming or
deleted links may be absent from all existing APIs; the UI displays an unavailable
notice and current connections, without inventing an identity or pending action.

Emergency source resolution first checks current authenticated alert history,
matching `alert_id` for received acknowledgement records (their `id` is the
acknowledgement ID). If absent, it uses current location and the existing nearby
endpoint/radius and requires an exact active alert-ID match. Accessible history
opens the existing Alert History screen. Accessible nearby alerts open the
existing Emergency Nearby screen with a fixed, server-returned target; the
nearest unrelated alert cannot overwrite it. Missing, resolved/out-of-range or
otherwise inaccessible sources get an unavailable message. No new detail endpoint
or emergency recipient rule is added. Location permission may be needed for the
nearby lookup. Viewing a source remains subject to current backend authorization.

No emergency producer was added in Stage 3B, so a real emergency filter may be
empty until a later approved producer exists. Test-only notification fixtures do
not enable a production producer. Push sending and push-tap routing are Stage 3D,
not this stage. The user's applied Stage 3B migration is taken as reported; no
development database connection or migration is run for this Flutter work.

Verification uses injected synthetic HTTP/auth/location boundaries and real
Provider/navigation/model behavior. Physical-device and live FastAPI/Firebase
integration of the new inbox remain separate checks; do not equate unit/widget
tests with that integration.
