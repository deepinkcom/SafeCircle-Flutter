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
`.env` files. In Azure, supply the JSON document as a protected Container Apps secret and map it to `FIREBASE_SERVICE_ACCOUNT_JSON`. The backend now accepts this secret directly; local development can continue using `FIREBASE_SERVICE_ACCOUNT_PATH`. Prefer workload identity
where the Firebase integration supports it; do not put private keys in Flutter,
image layers, source control, or build logs.

## Required backend configuration

- `DATABASE_URL`: SQLAlchemy PostgreSQL URL for the Azure database. Use TLS
  (Azure PostgreSQL connection string with `sslmode=require` or stricter).
- `FIREBASE_SERVICE_ACCOUNT_PATH`: path to a mounted service-account JSON file (supported for local/container file mounts).
- `FIREBASE_SERVICE_ACCOUNT_JSON`: service-account JSON supplied as a protected Container Apps secret. If set, this takes precedence over the file path. Never print this variable or include it in diagnostics.
- `PORT`: optional HTTP listen port; defaults to 8000 in the image.

The current settings class requires `DATABASE_URL`. Firebase authentication
initialization requires a valid service-account file. Configure both before
starting the API or worker.

## Database and migration gate — important

The current migration chain does **not** create a complete empty SafeCircle
database. Its root revision
`2549fa7ab98a_add_emergency_contact_links.py` creates
`emergency_contact_links` with foreign keys to an existing `users` table.
Later migrations also alter existing `devices` and `alerts` tables.

A reviewed legacy baseline matching the isolated PostgreSQL integration fixture
is now recorded in `backend/scripts/bootstrap_postgres.sql`. It creates the
pre-existing `users`, `emergency_contacts`, `devices`, `alerts`, and
`alert_acknowledgements` tables and enables PostGIS. This is a one-time
bootstrap for a **brand-new empty database only**, not an Alembic revision and
not a script to run against an existing database.

For a new Azure database, first confirm the server supports PostGIS and that the
deployment identity is permitted to create the extension. Review the SQL, take
a backup where applicable, then execute the baseline once against the empty
target database. Only after it succeeds should the approved release process run
`alembic upgrade head`. Never use `alembic stamp head` to bypass missing
schema creation. Existing installations must be assessed against their actual
schema and migration version; do not re-run the baseline.

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

The repository's default test fixture forces SQLite so ordinary backend tests cannot
inherit a developer database URL. CI now has a separate disposable PostGIS
service job that explicitly enables
`tests/test_emergency_notification_postgres.py`. This exercises the migration
chain and PostgreSQL-specific emergency-event locking/recovery behavior against
PostGIS. It is still not a substitute for a staging Azure database rehearsal,
network/TLS checks, backup restoration, or production-like load tests.

## Container Apps configuration guidance

API:
- Ingress: external HTTPS; target port 8000.
- Liveness probe: `/health` confirms the API process can serve requests.
- Readiness probe: `/health/ready` runs `SELECT 1` and returns HTTP 503 if the
  database is unavailable. Configure Container Apps readiness probes against
  this path; do not use it as liveness, or a database outage could restart-loop
  otherwise healthy API processes.
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

## CI and health verification

The CI workflow now includes a separate PostgreSQL/PostGIS integration job
using a disposable PostGIS container and synthetic credentials. It does not
connect to Azure or any developer database.

The API exposes:
- `GET /health`: process liveness; deliberately does not query PostgreSQL.
- `GET /health/ready`: database readiness; performs `SELECT 1` and returns
  HTTP 503 when SQLAlchemy cannot reach the configured database.

The notification worker remains a separate long-running process. A healthy API
readiness response does not prove the worker is running or that Firebase Cloud
Messaging delivery succeeds; monitor the worker independently.

## Azure infrastructure templates (not deployed)

`infra/azure/container-apps.bicep` defines two Container Apps using an
**existing** Container Apps managed environment and **existing** Azure Container
Registry. It creates a user-assigned managed identity and grants it the ACR
`AcrPull` role, then defines:
- `safecircle-api`: external HTTPS ingress, port 8000, liveness and database
  readiness probes, and a minimum replica count of at least one.
- `safecircle-push-worker`: no ingress, explicit
  `python -m app.push_worker` command, and exactly one replica so the polling
  worker cannot scale to zero.

The template accepts the database URL and Firebase service-account JSON as
secure parameters and stores them as Container Apps secrets. It does not output
secret values. The API and worker use secret references for their environment
variables. The managed identity is used for image pulls; it does not currently
provide passwordless PostgreSQL authentication.

### Required prerequisites and deployment sequence

The Container Apps template is intentionally not a one-click deployment. Before
it can be used, an administrator must provision and approve:
1. An Azure resource group and Container Apps managed environment.
2. An Azure Container Registry and push the reviewed image tag to it.
3. Azure Database for PostgreSQL Flexible Server, database, networking and
   firewall/private DNS connectivity from the Container Apps environment.
4. PostGIS extension and the reviewed baseline schema, followed by the approved
   Alembic migration task.
5. Firebase service-account secret and a verified non-production FCM test.

The current template references the existing registry and managed environment;
it does not create those resources or the PostgreSQL server. This separation
prevents accidental resource creation and keeps infrastructure provisioning
behind an explicit approval gate.

### Build and validation

CI compiles the Bicep template with Azure CLI. Compilation checks syntax and
resource schema only; it does not prove the target subscription has permissions,
that resource names are available, that quotas are sufficient, or that the
network and database configuration is correct. Before any deployment, run
`az deployment group what-if` against the explicitly approved resource group
and review every proposed change.

Example local validation (no Azure resources are created):

```sh
az bicep build --file infra/azure/container-apps.bicep
```

Do not run `az deployment group create`, `az containerapp update`,
`az acr build`, or database bootstrap/migration commands without separate
explicit approval.
