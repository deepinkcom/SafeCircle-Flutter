# FCM device registration: concurrency and session safety

The subsequent [delivery-retention fix](PUSH_DELIVERY_RETENTION.md)
replaces the device-to-delivery cascade through revision `d9a4f6b2c730`.
It preserves this document's session coordinator and registration-race fix.

The retention migration and compatible API/worker restart have been verified in
local development. Physical Android account-isolation and real FCM retesting of
the combined fixes are explicitly postponed and remain pending. Earlier physical
push tests do not establish that the updated retention worker has passed them.

## Scope

This change fixes registration errors without changing device ownership policy, Firebase configuration, notification navigation, emergency recipients or the migration chain. No migration is required. Re-registering a device preserves its ID and existing push-job references; a foreign owner is never overwritten.

## Backend contract

`POST /devices` remains authenticated and returns HTTP 200 with `id`, `user_id`, `platform`, `registered_at`. It never returns the FCM token. The lookup/update locks an existing row. Concurrent inserts are decided by the existing global unique index `uq_devices_fcm_token`.

The handler recognizes only that PostgreSQL constraint/23505 combination (or the exact SQLite devices.fcm_token uniqueness error in tests), rolls back, rereads the winning row, and returns it for the same authenticated owner. A different owner gets HTTP 409. A concurrently removed row gets a retryable 409; unrelated database errors are not treated as successful registration.

`DELETE /devices` remains authenticated, idempotent and scoped to the caller and token. Both methods use the same token normalization. The retention follow-up atomically cancels unfinished jobs before removal and preserves completed deliveries through a nullable device reference; successful registration does not delete/recreate records or jobs.

Device validation failures return a generic 422 without rejected token input. Storage errors roll back and return generic 503 messages. Logs use fixed messages, without exception text or tracebacks. The application engine also hides bound SQL parameters. PostgreSQL DETAIL can contain a token even when bound parameters are hidden, so device handlers must not log the original driver exception.

## Flutter lifecycle

One NotificationService coordinator covers startup/login, backend-profile readiness, settings and token-refresh registration. Callers share an in-flight future; successful repeats of the same session/token skip another POST. Refresh events supply the new token and are serialized; the last refresh cannot be lost during completion. A failed registration is not cached as success and can be explicitly retried.

Registration captures the existing Firebase bearer only after verifying the expected current account both before and after token acquisition. The short-lived bearer is retained in memory, without a token getter or persistence, so a stale operation can clean up using its own account rather than borrowing the next account's credentials. This is the existing Firebase authentication mechanism, not a new authentication system.

Retiring a session stops unstarted writes. Issued registration transports drain before owned cleanup. A UI timeout does not release the transport barrier or allow another registration to overtake cleanup. A new account's registration waits behind prior-session cleanup, and same-UID sign-out/sign-in creates a distinct session context. Failed cleanup remains a barrier and can be retried.

Normal logout unregisters the installation's tracked tokens while the old account is still authenticated, deletes the SDK FCM token, and only then performs Firebase sign-out. Duplicate logout attempts are guarded. If cleanup cannot be confirmed, the app shows a safe retry message and does not proceed with account switching. This deliberately favors confirmed cleanup over silently claiming an offline logout succeeded. A pending transport may outlive the UI timeout; it remains tracked until it actually settles.

Disposal is NOT logout: confirmed registration remains enrolled so background and swiped-away delivery continue. Listener cleanup and eventual in-memory bearer disposal do not delete device records just because the UI closes.

## Verification

New backend tests use real SQLite uniqueness/FK constraints, deterministic interleaved commits and parallel API requests. They cover same-owner idempotence, foreign-owner conflicts, stable device/job IDs, rollback, validation privacy, driver/parameter redaction and normalization. They exercise PostgreSQL constraint-name classification; they do not prove live PostgreSQL contention timing.

Flutter tests inject Firebase Messaging and HTTP clients. They cover overlapping callers, token refresh, retries, permission denial, transport timeout draining, cleanup failures, account changes during token/auth/cleanup lookup, switching away and back to the same UID, owned cleanup headers and preservation of enrollment on disposal. No production authentication or test overrides are introduced into the live app.

### Initial registration-fix verification (2026-11-09, before retention follow-up)

- Focused backend registration suite: 19 passed before the two additional normalization/engine-redaction tests were added; both additional tests passed in the final full suite.
- Focused Flutter lifecycle suite: 15 passed.
- Full backend suite: 301 passed, 746 warnings, 50.98 seconds. Tests use disposable databases, not development records.
- Full Flutter suite: 405 passed.
- `flutter analyze --no-pub`: no issues found (7.6 seconds).
- Dart formatting check: four changed Dart files checked, zero changes required.
- Android ARM64 debug build: successful with a 2 GiB Gradle heap and one worker; Java native-access and plugin Kotlin migration warnings remain. APK: `build/app/outputs/flutter-apk/app-debug.apk`. The APK was not installed.
- Git whitespace check passed. No files staged, committed or pushed.
- Read-only development checks: revision `c7f0a3e5b921`; device 7 still belongs to user 2; token unique index valid; zero duplicate token groups; original worker connected; existing delivery jobs 1, 2 and 3 still sent; API health HTTP 200.

Registration-fix files: `backend/app/devices.py`, `backend/app/database.py`, `backend/tests/test_device_registration_concurrency.py`, `lib/services/api_service.dart`, `lib/services/notification_service.dart`, `lib/navigation/app_router.dart`, `test/device_registration_lifecycle_test.dart`, and this document. The retention document records the later 326-test verification and local migration.

## Remaining risks and retest prerequisites

- The registration APK was installed as an in-place update, and the development API and compatible retention worker were restarted after the approved migration. Other environments require their own migration/restart approval. No uninstall or data reset is required. Physical retesting remains pending.
- Retest initial login, overlapping initial token refresh, profile completion, permission re-enable, rapid logout/sign-in and account switching on the physical phone. Confirm same-owner registration produces one stable row, another owner stays 409, and foreground/background/swiped-away delivery and tap navigation still work.
- Network loss or process termination during teardown can prevent confirmation of server-side cleanup. The UI must not claim logout completion when its teardown barrier fails; retry while the old account remains authenticated. This is not a server-side enrollment-revocation generation protocol. Expired captured credentials cannot authorize cleanup as another account and must fail closed. A stronger guarantee across arbitrary lost requests/process crashes would require a separately reviewed enrollment/revocation design.
- Existing local/API error logs may already contain sensitive tokens. They were not rewritten or deleted by this change and remain Git-ignored.
- PostgreSQL native server logging is independent of application exception handling. Inspected settings were log_error_verbosity=default, log_min_error_statement=error, log_parameter_max_length_on_error=0. Driver DETAIL and statement logging can still expose values at the server. No live database logging configuration was changed. Database-administrator review/approval is needed for any native logging-policy change; hiding SQLAlchemy parameters alone is not a complete server-log redaction policy.
- No development records, indexes or migrations are changed by automated tests. PostgreSQL concurrency rehearsal should use an approved isolated database, never the active development data.
