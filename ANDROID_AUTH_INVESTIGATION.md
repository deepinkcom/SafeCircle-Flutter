# Android authentication investigation

Verified 2026-11-16, preparation/local fixes only.

Account B supplied exact message: Network error. Check your connection and try again.
AuthService maps FirebaseAuthException code network-request-failed to that exact string. In the inspected login flow the relevant Firebase Auth call is signInWithEmailAndPassword, before Firestore profile loading and backend profile readiness. Device registration follows entry to the main UI, and its errors are caught independently. It cannot explain a credential-screen login rejection in this flow.
Confirmed failure category: Firebase Auth network-request-failed. Underlying phone-specific DNS/TLS/network/Google-service cause remains unknown; working general internet does not identify it. No credentials, phone logs, APK version or Firebase request traces were available.

Azure health returned ok and readiness returned ready. Current image remains fcf5798d6fb2456afd114bab0588e3ae0933d6a521694e774f71150c9722fbb1, revision safecircle-api--tm5ge9w.
Public OpenAPI exposes /devices and /users/me; neither /devices/cleanup-status nor /devices/installation exists in this deployed contract. New local installation-cleanup client therefore requires the planned migration/backend release. Installed APK identity is not confirmed; do not assume that contract mismatch proves the old phone's exact exception.
Recent API logs were captured in memory, filtered and aggregated without raw log output: 302 records inspected, relevant request timestamps 2026-11-16T10:55:53Z through 11:31:43Z (12:55:53 through 13:31:43 South Africa time). 74 GET /health 200, 218 GET /health/ready 200, one GET /users/me 200. No matching users/devices 401/403/404/409/422/500 observed in that retained window. This does not prove absence outside the retained window, nor attribute any request to Account A or B. Firebase sign-in is client-to-Firebase and will not appear as a FastAPI login request.

Logout generic Google Play/connection message is produced by app_router's catch-all for unexpected cleanup exceptions; it is not proof of internet failure or stale registrations. Legacy account/token-only registration and unavailable FCM token are established design limitations, but no phone-specific token or registration was inspected. No production recovery/deletion was performed.

Local changes this turn:
- auth_service.dart: sanitized stage/code diagnostics, actionable Firebase sign-in network message, separate Firestore profile errors.
- notification_service.dart: missing installation endpoint is diagnosed with status and actionable server-update message; no cleanup bypass.
- auth_login_diagnostics_test.dart: three regression tests for sign-in failure stage, profile failure stage and success without identity logging.
- device_registration_lifecycle_test.dart: missing-backend contract regression; Firebase token deletion must not occur after a 404.

Checks actually run: 42 focused Flutter tests passed, Flutter analyze clean, 37 device/profile backend tests passed; git diff --check passed. Full suites were not rerun. No backend application code changed this turn. No APK built or installed, backend deployed, migrations run, or production accounts/registrations changed.
The prior release source manifest/image no longer represents the new Flutter changes. Rebuild/reverify the future APK and refresh release evidence before distributing it.

Safest immediate demonstration:
Keep already working Account A sessions intact. Try Account B on the other phone without disturbing Account A, using a different trusted network and confirmed automatic date/time. Record exact attempt time and safe Firebase exception stage/code if failure persists. Check existing Google Play services health/update status through normal Android settings; do not change Firebase production settings. DNS/VPN/certificate interception are hypotheses, not proven causes.
Do not reinstall or clear application data as routine recovery: it may orphan legacy device registrations and cannot add the missing backend endpoint. Do not delete account-wide registrations or bypass logout.
If both accounts can sign in, demonstrate connections/profile/map with dedicated accounts kept on separate phones. Do not claim multi-account logout or emergency push delivery works without actual authorized device verification. Use a separately approved harmless notification path; do not enable production development flags or activate panic alerts as diagnostics.
Deploying the backend will not repair Firebase sign-in connectivity. Secure installation cleanup requires the new backend/migration plus a matching APK; the recovery safety gate remains NO-GO until accepted restore evidence exists. Old unidentified registration recovery may still be needed, but ownership cannot safely be inferred from this report.
