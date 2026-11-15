# SafeCircle — Azure deployment preparation

Status: preparation only. This document does not authorize provisioning, migration,
publishing, or production deployment.

## Target architecture

- Flutter clients call the FastAPI API over HTTPS.
- Azure Container Apps runs the API image built from `backend/Dockerfile`.
- A second Container App runs the persistent notification worker using the same
  image with command `python -m app.push_worker`.
- Azure Container Registry stores the image.
- Azure Database for PostgreSQL Flexible Server stores application data and
  must have the PostGIS extension enabled.
- Firebase Authentication and Firebase Cloud Messaging remain external services.

Keep the API and worker as separate Container Apps. The worker polls continuously,
so it must not scale to zero. Configure a minimum replica count of 1 until a
queue-driven design replaces polling. Configure the API minimum replica count
according to the application's emergency-service availability requirements.

## Container build

Build from the repository root:

```sh
docker build -t safecircle-api:local ./backend
```

Run locally only with a separately prepared, non-production environment:

```sh
docker run --rm -p 8000:8000 \
  -e DATABASE_URL="$DATABASE_URL" \
  -e FIREBASE_SERVICE_ACCOUNT_PATH=/run/secrets/firebase-service-account.json \
  -v "$PWD/firebase-service-account.json:/run/secrets/firebase-service-account.json:ro" \
  safecircle-api:local
```

Do not commit credentials or environment files. The Docker build context excludes
`.env` files. In Azure, mount the Firebase service-account JSON from a protected
Container Apps secret as a read-only file and set
`FIREBASE_SERVICE_ACCOUNT_PATH` to that mounted path. Prefer workload identity
where the Firebase integration supports it; do not put private keys in Flutter,
image layers, source control, or build logs.

## Required backend configuration

- `DATABASE_URL`: SQLAlchemy PostgreSQL URL for the Azure database. Use TLS
  (Azure PostgreSQL connection string with `sslmode=require` or stricter).
- `FIREBASE_SERVICE_ACCOUNT_PATH`: path to the mounted service-account JSON file.
- `PORT`: optional HTTP listen port; defaults to 8000 in the image.

The current settings class requires `DATABASE_URL`. Firebase authentication
initialization requires a valid service-account file. Configure both before
starting the API or worker.

## Database and migration gate — important

The current migration chain does **not** create a complete empty SafeCircle
database. Its root revision
`2549fa7ab98a_add_emergency_contact_links.py` creates
`emergency_contact_links` with foreign keys to an existing `users` table.
Later migrations also alter existing `devices` and `alerts` tables. There is
no baseline migration in the inspected migration chain that creates all of the
pre-existing core tables.

Therefore, do not point Alembic at a newly created empty production database
until the authoritative baseline schema / database bootstrap procedure has
been identified and reviewed. Do not use `alembic stamp head` to bypass this
requirement.

Before applying the existing migrations to an approved database:

1. Take and verify a restorable backup.
2. Confirm the database schema matches the application's expected pre-migration
   tables and constraints.
3. Enable PostGIS using an appropriately privileged database account:
   `CREATE EXTENSION IF NOT EXISTS postgis;`
4. Verify PostGIS with `SELECT PostGIS_Full_Version();`.
5. Review the migration SQL and data-impact with a database administrator.
6. Run `alembic upgrade head` as a one-off release task, not in every API
   replica's startup command.
7. Verify `alembic current`, application reads/writes, spatial queries, and
   notification worker behavior.

The repository's current test fixture forces SQLite for the default backend
test suite. Tests named for PostgreSQL exercise real PostgreSQL-specific
behavior only when a suitable PostgreSQL test database is explicitly supplied.
A green SQLite test run is not proof that PostGIS migrations or PostgreSQL
locking/concurrency behavior works in Azure.

## Container Apps configuration guidance

API:
- Ingress: external HTTPS; target port 8000.
- Liveness/readiness initial probe path: `/health` (currently a basic process
  health response, not a database readiness check).
- Configure minimum replicas based on availability requirements.
- Set resource requests/limits after load testing.

Worker:
- No public ingress.
- Container command: `python -m app.push_worker`.
- Minimum replicas: 1; do not scale to zero while using the polling loop.
- Configure restart policy and monitoring for repeated storage/provider errors.

Database:
- Private networking is preferred; restrict firewall/network access to the
  Container Apps environment.
- Enforce TLS, least-privilege database credentials, automated backups and
  restore testing.
- Enable PostGIS before deploying code that uses GeoAlchemy spatial columns.

## Flutter API endpoint

The current Flutter `ApiService` constructor defaults to a development LAN
address (`http://192.168.0.28:8000`). Production builds must not rely on that
default. Supply the deployed HTTPS API base URL at build time using Flutter's
`--dart-define`:

```sh
flutter build apk --release \
  --dart-define=SAFECIRCLE_API_BASE_URL=https://YOUR-API-HOST
```

The source currently needs a corresponding `String.fromEnvironment` binding
for this define before the command above takes effect. Keep the local default
for development until that change is implemented and covered by tests. Never
put database credentials or Firebase service-account private keys in
`--dart-define`.

## CI

`.github/workflows/ci.yml` runs backend tests, Flutter analysis/tests, and a
local Docker image build. It deliberately does not log in to Azure, push to
ACR, provision resources, run migrations, or deploy.

## Outstanding release blockers

- Identify and document the authoritative baseline schema/bootstrap for
  `users`, `alerts`, and `devices` before using a blank Azure database.
- Implement and test the Flutter `SAFECIRCLE_API_BASE_URL` build-time setting.
- Add a database-aware readiness check with safe timeout behavior.
- Run PostgreSQL/PostGIS migration and concurrency tests against a disposable
  PostgreSQL instance.
- Confirm Firebase service-account mounting and FCM delivery in a non-production
  environment.
- Add Azure deployment automation only after CI passes and separate approval
  is granted for Azure credentials and deployment scope.
