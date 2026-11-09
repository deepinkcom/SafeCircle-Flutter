# Stage 3E profile-picture developer handover

Status: IMPLEMENTATION DRAFT — NOT TESTED. Not a validated release. Stage 3E is
not complete until the next developer compiles, tests, debugs and verifies it.

Starting point: `origin/master`, merge commit
`8d6cb475fab8604195225324610fb45d58cbcfff` (PR #2).
Working branch: `feature/profile-pictures`. No commit, push or deployment is part
of this handover. Source inspection only: no pub get, formatter, analyzer, tests,
build, app launch, Firebase upload, API request or device operation was executed.

## Feature and architecture

Profile & Settings and Personal Details share `ProfilePhotoAvatar` and the same
photo editor. The avatar falls back to the existing person icon. Users can pick
from gallery or optionally capture on Android/iOS, preview, discard/cancel,
explicitly upload, replace or confirm removal. Provider's existing AppState owns
loading/progress/errors and memory bytes; there is no second profile provider.

Firestore `users/{firebaseUid}.photoStoragePath` is the sole persistent photo
reference. It is optional/null for legacy profiles. The existing UserProfile
model/repository and sign-in restoration load it. Files reside in Firebase Storage
at `profilePhotos/{firebaseUid}/{128-bit-random-lowercase-hex}.png`.
There are no email/name filenames, public URLs or Firebase Auth photoURL updates.
Images are read with authenticated Storage `getData`, not `getDownloadURL`.
There is no application-managed disk avatar cache. FastAPI/PostgreSQL continue
to own their existing text-profile readiness/synchronization; photo metadata is
not duplicated there. No backend code or migration is needed or included.

## Files

Modified:

- `pubspec.yaml`: firebase_storage ^14.0.1 and image_picker ^1.2.4 declarations.
- `lib/models/models.dart`: optional photoStoragePath and serialization/copying.
- `lib/services/user_repository.dart`: authoritative photo-reference reads and
  transactional compare-and-set updates that preserve all other profile fields.
- `lib/state/app_state.dart`: injected photo service, session binding, photo
  loading/picking/save/remove/refresh, mutation exclusion and stale-result guards.
- `lib/screens/profile_screen.dart`: circular avatar and photo-editor entry points
  on Profile & Settings and Personal Details.
- `firestore.rules`: optional UID-scoped photo field, ownership/field restrictions.
- `firebase.json`: local Storage rules-file reference; existing project IDs unchanged.
- `ios/Runner/Info.plist`: gallery/camera usage descriptions, no microphone access.

Created:

- `lib/models/profile_photo.dart`: reference validator, memory-only draft, result,
  source enum and sanitized failure type.
- `lib/services/profile_photo_service.dart`: picker/decoder, private Storage I/O,
  auth guards, transaction sequencing and best-effort old-object cleanup.
- `lib/widgets/profile_photo_avatar.dart`: shared circular display/fallback.
- `lib/widgets/profile_photo_editor.dart`: preview and explicit mutation controls.
- `storage.rules`: proposed owner-only immutable photo-object rules.
- `docs/STAGE_3E_PROFILE_PICTURES.md`: this handover.

The lockfile and generated plugin registrants are intentionally unchanged: the
next developer must resolve dependencies and review resulting generated changes.
No tests were added or executed; test implementation/verification is assigned to
the next developer. Backend, FCM worker, notification routing, contact counts,
launcher icons and emergency recipient policies are unchanged.

## Image handling

Picker requests at most 1024 x 1024, quality 85 and no full metadata. Returned
files must be nonempty and at most 8 MiB before reading; a bounded stream also
enforces the limit while reading. Actual JPEG/PNG signatures
are checked; SVG/GIF/other encodings are rejected. HEIC may work only if the picker
returns a converted JPEG; otherwise the user must export JPEG/PNG.

The Flutter decoder checks dimensions (8192 per axis, 24 million pixels maximum),
then decodes down to at most 512 pixels on the long edge and re-encodes PNG. The
stored result is limited to 2 MiB. Re-encoding drops the original filename and
EXIF/GPS data; orientation, transparency and metadata assumptions need testing.
Upload revalidates/re-encodes the draft. Preview is circular; it is a visual crop,
not an interactive crop editor. No additional imaging/cropping dependency is used.

The 8 MiB selection limit applies after picker processing, not necessarily the
original gallery file. Camera/gallery originals are never deleted. Native picker
temporary files remain subject to OS/plugin cleanup. Drafts are cleared on editor
disposal; old avatar MemoryImage cache entries are evicted and byte buffers cleared
on replacement/logout/account change. Managed/runtime/GPU copies cannot be
guaranteed physically zeroized. Screen captures/OS snapshots are outside that promise.

## Persistence, replacement, removal and partial failures

1. A prepared draft is bound to UID and service auth epoch. No upload on selection.
2. Save uploads a NEW immutable random object, preserving the old valid object.
3. A Firestore transaction reads the profile and compares the current reference
   against the expected reference. Conflicts require refresh. Only photoStoragePath
   and updatedAt are updated; text fields and account records are preserved.
4. Only after confirmed reference persistence is old-object deletion attempted.
5. Removal clears the reference transactionally FIRST, then deletes the old file.
   Default avatar is restored after server confirmation, never optimistically.

No cross-product atomic transaction exists between Storage and Firestore. Failed
uploads/transactions or process death can leave unreferenced objects. After an
uncertain Firestore result the new object is NOT deleted: it may be the valid
current photo. The UI requires an authoritative refresh before another mutation.
If old-object deletion fails after a successful reference change, the change
remains successful and a cleanup warning is shown. No unreviewed automatic janitor
or account deletion is introduced. Residual objects require separately approved
owner/admin review; do not bulk-delete paths from logs or guesses.

Storage rules additionally reject deletion of the currently referenced object.
Normal clients never reattach old random names. Arbitrary owner clients and
cross-product races still need rule/concurrency testing; the feature is not a
general distributed storage transaction or malicious-owner moderation system.

## Account isolation and errors

- Firebase Auth UID must match the requested owner, service binding and AppState
  authentication generation before/after awaits and before transaction writes.
- Auth changes invalidate draft epochs; logout/account changes clear memory and
  invalidate open editor session versions, including out-of-band SDK auth events.
  The service notifies AppState to hide stale avatars/previews immediately.
  Auth changes also
  best-effort cancel uploads. In-flight SDK requests cannot necessarily be unsent,
  but fixed UID paths/docs plus rules prevent writing another account's profile.
- Photo mutation/picking is serialized; text-profile saves and photo mutations
  exclude one another. Late reads cannot replace a newly saved avatar or next
  account's state. Same-UID sign-out/sign-in invalidates old drafts.
- All references are validated as same-UID paths; gs://, HTTP URLs, foreign UIDs,
  arbitrary object names and traversals are not accepted by the service/rules.
- Storage download is memory-only, capped at 2 MiB and decoded before display.
  Offline refresh keeps an already loaded image only for the same reference/owner.
  First offline login has no persistent avatar cache and may show the fallback.
- Errors are fixed/sanitized; raw exceptions, bytes, tokens and Storage credentials
  are not logged. Permission/bucket errors give setup/sign-in guidance; selection
  cancellation makes no mutation. Upload has a 60-second UI deadline with a
  cancellation request; Firestore transactions use SDK retry/timeout semantics.
- SDK transaction retries compare the same expected reference and recheck session
  state. The app does not blindly repeat an uncertain completed save/remove.

## External Firebase configuration — NOT PERFORMED

An administrator must inspect the actual intended Firebase project and existing
bucket, billing/availability, deployed rules and credentials. A client storageBucket
setting does not prove the bucket exists or its rules are correct. No live Storage
resource, security-rule deployment, Firebase Auth account or database record was
created or changed during implementation.

The proposed `storage.rules`:

- Deny unauthenticated/other-UID access and all listing.
- Permit create only for random PNG object names, ownerUid metadata, image/png
  content type and 1..2 MiB size, with an existing Firestore user profile.
- Refuse updates/overwrites; replacement always uses a new object.
- Permit get only for the owner's currently referenced photo.
- Permit delete only when that object's path is not the current profile reference.
- Deny all other paths. Merge carefully with any legitimate existing bucket policy;
  do not accidentally remove unrelated live storage permissions.

The proposed Firestore rules preserve the existing required text fields and
owner-only reads/writes; photoStoragePath is OPTIONAL or null. Its allowed string
must match the same UID/random PNG path. Existing email/createdAt restrictions and
the ban on profile-document deletion remain. Existing profiles need no backfill.

Storage's firestore.exists/get cross-service rules require the documented Firebase
service-agent permissions to the default Firestore database; an administrator must
review/enable that integration only with separate approval. Review both rule sets
together in emulators, then obtain explicit deployment approval. No permissive
test-mode rules or public bucket ACLs are acceptable. No deployment was performed.

Rules validate MIME/size/ownership, NOT actual file contents. The official client
validates/normalizes content; a hostile owner client can spoof MIME metadata. Strong
trusted content scanning, quotas/rate limits and automatic orphan cleanup would
require additional reviewed server infrastructure and are not implemented here.
Never generate/persist public bearer download URLs; separately review Storage
download-token behaviour, administrator access and accidental token disclosure.

## Platform and dependency assumptions — UNTESTED

- Dependencies were selected from publisher documentation; resolution against this
  project's Firebase Core 5/Auth 7/Firestore 7 and lockfile has NOT been executed.
- image_picker 1.2.4 documents Android SDK 24+ and iOS 13+; compare the project's
  resolved platform minimums before changing them. No Android config was changed.
- iOS usage strings are included, but non-Android Firebase options are existing
  placeholders. Real iOS setup/permissions require separate verification.
- Camera UI is offered only on Android/iOS. Desktop/web picker, Storage platform
  support, Firebase options and CORS need separate work/verification if targeted.
- Android activity/process destruction while the native picker is open can lose
  the selection. retrieveLostData auto-restoration is deliberately NOT implemented:
  never silently restore a previous account's selection. Reopen and select again.
- No realtime Firestore profile subscription was added. Another device's photo
  changes appear on manual refresh or next login; compare-and-set guards stale saves.
- File cleanup is best effort and not durable; document/monitor orphan growth.

## Next-developer checklist — EVERY ITEM NOT RUN

| Area | Required coverage | Status |
|---|---|---|
| Dependencies/build | pub get, lockfile review, format, analyze, compile/authorized build | NOT RUN |
| Gallery | JPEG/PNG selection, picker cancellation and inaccessible files | NOT RUN |
| Camera | capture/cancel, denied/permanently denied permission, unavailable camera | NOT RUN |
| Preview | correct orientation/aspect, transparency, discard, explicit upload only | NOT RUN |
| Validation | invalid bytes/MIME/extensions, empty/8 MiB inputs, huge dimensions, 2 MiB output | NOT RUN |
| Upload | progress, duplicate taps, timeout/cancellation, correct owner/random path | NOT RUN |
| Persistence | Firestore field, logout/login/restoration, unchanged name/email/city/phone | NOT RUN |
| Replacement | old remains after failure; new reference before old deletion; cleanup warning | NOT RUN |
| Removal | confirmation/cancel, default avatar, only photo reference/file removed | NOT RUN |
| Partial failure | ambiguous commit, required refresh, orphan retention, app crash mid-save | NOT RUN |
| Offline | selection, upload, Firestore commit, refresh and old-photo preservation | NOT RUN |
| Account isolation | A->B, A->logout->A, pending picker/upload/load/transaction/cleanup, disposal | NOT RUN |
| Cross-device | simultaneous replacement/removal, CAS conflicts and stale loads | NOT RUN |
| Storage rules | unauth/other UID/list denied; current get allowed; referenced delete denied | NOT RUN |
| Rule validation | MIME/size/name/ownerUid; overwrite denied; Firestore cross-service permissions | NOT RUN |
| Firestore rules | legacy absent/null fields, own-path only, immutable email/createdAt, other UID denied | NOT RUN |
| Personal Details | same avatar/editor; photo and text saves cannot overwrite each other | NOT RUN |
| UI/accessibility | small screens, text scaling, labels/touch targets, loading/errors/back/account change | NOT RUN |
| Memory/process | cache eviction, no cross-account preview, native picker process death, restored session | NOT RUN |
| Emergency contacts | phone counts, CRUD/enabled status, connections/lifecycle unchanged | NOT RUN |
| Notifications/FCM | mocked registration/logout/routing regressions; live tests need separate approval | NOT RUN |

Suggested commands for the NEXT developer, only when authorized (NOT EXECUTED):

```powershell
flutter pub get
# Review dependency/lockfile changes; do not run a broad pub upgrade.
dart format lib/models/profile_photo.dart lib/models/models.dart lib/services/profile_photo_service.dart lib/services/user_repository.dart lib/state/app_state.dart lib/screens/profile_screen.dart lib/widgets/profile_photo_avatar.dart lib/widgets/profile_photo_editor.dart
flutter analyze --no-pub
flutter test --no-pub
git diff --check
```

Add focused model/service/state/widget tests and rule-emulator tests; inject
FirebaseAuth, FirebaseStorage, UserRepository, ImagePicker and ProfilePhotoService
instead of contacting the live project. Configure emulators explicitly and use a
demo project, e.g. `firebase emulators:start --only auth,firestore,storage --project
demo-safecircle-profile-photos`. Wire every SDK instance to emulators before use;
do not assume that starting an emulator redirects the application automatically.
FirebaseBootstrap readiness and fake session bindings also need explicit test setup.

Optional existing backend regression run (no development DB, after approval):
set SAFECIRCLE_RETENTION_POSTGRES=0 and DATABASE_URL=sqlite+pysqlite:///:memory: in
the TEST PROCESS, use `.venv-backend-test\Scripts\python.exe -B -m pytest` from
backend, and pass --basetemp to a fresh ignored `.buildlog` subdirectory. Use the
module entry point, not stdin, because Windows subprocess tests require it.

Authorized Android compilation/installation, emulator rule execution, resource
provisioning/deployment and live photo/FCM tests require their own approvals. The
prior foreground/background/swiped-away FCM passes predate these untested changes;
they are not evidence that Stage 3E preserves those behaviours. Do not label this
stage complete or production-ready until the next developer signs off.

## Primary implementation references

- https://pub.dev/packages/image_picker (setup, permissions, activity destruction)
- https://pub.dev/packages/firebase_storage (official FlutterFire Storage plugin)
- https://firebase.google.com/docs/storage/flutter/download-files (authenticated SDK reads)
- https://firebase.google.com/docs/storage/security/rules-conditions (ownership, metadata and Firestore integration)
- https://firebase.google.com/docs/firestore/manage-data/transactions (compare-and-set transaction semantics)
