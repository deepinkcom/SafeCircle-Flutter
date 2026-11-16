# SafeCircle Azure demo-only operations runbook (preparation)

**Status:** draft for future authorized deployment. Nothing in this file authorizes
resource creation, changes, startup, shutdown, or deletion. Do not execute
operational commands until deployment and operating schedule are approved.

## Scope and constraints

- Region: South Africa North; resource group: `rg-safecircle-student`.
- Existing VNet: `vnet-safecircle-student`; never delete it as part of demo cleanup.
- PostgreSQL: proposed `safecircle-student-pg`, private networking, B1ms,
  32 GiB, 7-day backup, HA disabled.
- Container Apps: proposed `safecircle-api` and `safecircle-push-worker`.
- This environment is for controlled demonstrations, **not real emergencies**.
- Database and worker are required for complete alert/push functionality.
  API readiness alone does not prove push notifications work.

## Before requesting permission to deploy

1. Confirm remaining Azure for Students credit and applicable free-service limits.
2. Save a current South Africa North pricing-calculator estimate with
   both active-hour and fixed/monthly charges (ACR, storage, networking,
   logs, DNS and any managed-environment charges).
3. Agree on exact test dates, daily active windows, and a maximum spend.
4. Confirm subscription quotas, registry SKU allowance, and PostgreSQL PostGIS.
5. Confirm backend bootstrap/migrations and Flutter HTTPS API URL are ready.
6. Confirm a repeatable, secure secret provisioning method.
7. Obtain explicit approval for **each** provisioning/publishing action.

## Verified local CLI capabilities (2026-11-16)

The owner confirmed the installed Azure CLI provides these commands via
read-only `--help` checks:

- `az containerapp revision list --name <app> --resource-group <rg> --all`
- `az containerapp revision deactivate --revision <revision> --resource-group <rg>`
- `az containerapp revision activate --revision <revision> --resource-group <rg>`

These are **future operational commands**, not yet tested on deployed apps.
Revision names must be obtained from the actual deployed resources. The
templates currently use single-revision mode and fixed revision suffix
`azure`; validate revision lifecycle and reactivation before relying on
20-hour consumption billing. Never execute activate/deactivate until
deployment and operating changes are explicitly approved.

**Stop sequence (future, conditional):** prevent new synthetic test alerts,
verify pending work is drained, deactivate worker and API revisions, verify
no running replicas, then stop PostgreSQL. **Start sequence:** start PostgreSQL,
wait for readiness, activate API and worker, verify both workloads and end-to-end
FCM delivery. PostgreSQL may restart automatically after its stop-duration limit;
check state regularly. ACR, storage, DNS and environment charges may continue.

## Approved demo window: start checklist (future)

- Confirm authorization and a budget/credit check.
- Confirm that PostgreSQL, API, and worker exist and that the stop/start
  mechanism is supported for the deployed Container Apps configuration.
- Start PostgreSQL and wait until its state is Ready.
- Start the API and worker using the **approved, tested** procedure.
- Verify `/health`, `/health/ready`, an authenticated API request,
  a synthetic emergency-alert workflow, and FCM push delivery.
- Confirm HTTPS, private DNS, and that no sensitive data appears in logs.
- Record start time and responsible operator.

## End of each demo window: stop checklist (future)

- Stop the worker and API using the **approved, tested** method.
  Do not merely set API min replicas to zero and assume all usage stops.
- Confirm no running replicas and no pending alerts requiring delivery.
- Stop PostgreSQL only after API and worker have stopped.
- Record stop time; verify Azure cost/usage and any background charges.
- Remember that storage, registry, backups, DNS, and monitoring may still
  be billable even when compute is stopped.

## End of assessment: cleanup (future)

- Export required assessment evidence and a database backup if needed.
- Identify resources created **specifically** for this demo.
- Obtain explicit approval for deletion of each temporary resource.
- Do not blindly delete `rg-safecircle-student` or
  `vnet-safecircle-student`, which already existed during preparation.
- Check for remaining billable resources and confirm cleanup.

## Validation already reported by owner (no deployment)

- All four Bicep templates compiled with `az bicep build`.
- Registry what-if: one registry to create, existing VNet ignored.
- Managed environment what-if: one environment to create, existing VNet ignored.
- PostgreSQL what-if: server, database, private DNS zone and VNet link
  to create; existing VNet ignored.
- Actual image publishing, app/worker configuration validation, private DNS
  resolution, PostGIS, migrations, and live FCM delivery remain untested.
