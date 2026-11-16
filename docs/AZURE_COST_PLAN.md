# SafeCircle Azure cost plan — temporary assessment/demo environment

Status: planning only. The owner selected **South Africa North** and a
short-lived, lowest-practical-cost environment for the academic marking/demo,
with an expected lifetime of **one month (30 days)**. The owner has now chosen **testing/demonstration windows only**, not 24/7 operation.
This is not a production design or a live Azure quote. No resources are created.

## Confirmed planning decisions

- Region: **South Africa North** (`southafricanorth`, Johannesburg).
- Purpose: temporary environment for assessment, marking and demonstrations.
- Priority: minimise recurring spend; do not pay for production-grade redundancy
  that is not needed for a short-lived demonstration.
- Lifecycle: budget for up to 30 days; create only after explicit provisioning
  approval; delete the resource group at the end of the assessment month after
  required evidence/data has been exported and retained safely.
- Budget: no numeric monthly ceiling has been supplied yet. Do not deploy until
  the Azure Pricing Calculator estimate and expected active days are reviewed.

Microsoft lists South Africa North as an Azure region with three availability
zones. PostgreSQL Flexible Server is listed for South Africa North, including
Burstable compute and HA/backup feature availability. This does not guarantee
that every specific SKU, Container Apps environment mode, or quota is available
for this subscription at deployment time. Verify the actual region/SKU choices
in the subscription before provisioning.
Sources:
- https://learn.microsoft.com/en-us/azure/reliability/regions-list
- https://learn.microsoft.com/en-us/azure/postgresql/flexible-server/overview

## Lowest-practical-cost temporary configuration

| Service | Temporary starting choice | Cost control / limitation |
|---|---|---|
| Resource group | One dedicated assessment resource group in South Africa North | Delete the group after marking once evidence/data is safely retained |
| Container Apps | Consumption plan; no dedicated workload profile | Avoids paying for a dedicated workload profile |
| FastAPI API | 0.5 vCPU / 1 GiB starting allocation; one replica while demo is active | Keep one replica for reliable live demonstration; scale to zero only when not required and after confirming wake-up delay is acceptable |
| Push worker | 0.25-0.5 vCPU / 0.5-1 GiB; one replica only when push notifications are part of the demonstration | Polling worker incurs compute while running; stop/delete the temporary environment outside assessment windows if no alerts are needed |
| PostgreSQL Flexible Server | Burstable B1ms if available and sufficient; 32 GiB minimum/template starting storage | Stop the server between demo periods where operationally practical; compute billing stops while stopped, but storage/backup charges can remain; server auto-start behaviour and stop limits must be checked |
| PostgreSQL HA | Disabled | Accepts a single-zone outage risk for a temporary demo; not suitable as a production recommendation |
| Backup | Minimum supported retention (currently template default 7 days) | Export a separate logical backup before deletion; verify restore if data must be retained |
| ACR | Standard SKU in the current Bicep; admin user disabled | No private endpoint; use managed identity for pulls; delete registry after marking if image is safely retained elsewhere |
| Logs | Minimal diagnostic categories and short retention | Avoid high-volume request/body logging; never log secrets, tokens or location details |
| Networking | Keep the deployment simple, but preserve TLS and restrict database access | Private VNet architecture is preferred for production but may add complexity/cost. For a temporary assessment deployment, compare private networking with a tightly restricted public-access design before approval; never expose PostgreSQL broadly to the internet |

Important: do not reduce security by disabling HTTPS, committing secrets,
enabling the ACR admin account, or opening PostgreSQL to all IP addresses.
Cost optimisation must not expose Firebase credentials, user data, or emergency
location information.

## Active-use schedule

Estimate the number of hours/days the environment is actually needed. The
cheapest safe operational approach may be to:
1. Build and test the image in GitHub Actions without pushing to Azure.
2. Provision the temporary Azure environment shortly before the assessment.
3. Run the API, database and worker only for the agreed demo window.
4. Stop PostgreSQL and scale/stop app workloads when not in use, if the chosen
   configuration supports this without losing readiness or demo reliability.
5. Export required screenshots, logs with sensitive fields redacted, and a
   database backup if needed.
6. Delete the temporary resource group after marking and retention approval.

Do not assume all services can be paused at zero cost. PostgreSQL storage,
backup retention, ACR storage, Log Analytics, DNS, public IPs, NAT gateways and
private endpoints may continue to incur charges while compute is stopped.

## One-month operating assumptions

The planning horizon is 30 days. Until the owner confirms a daily demonstration
schedule, prepare two calculator cases:

- **Continuous availability (upper planning case):** API and worker run 24
  hours/day for 30 days (720 hours); PostgreSQL runs 24 hours/day for 30 days.
- **Assessment-window operation (cost-saving case):** API, worker and database
  run only during agreed demonstration/preparation windows. Record the exact
  hours/day and number of days. Stopping compute does not eliminate storage,
  backup, registry, monitoring or networking charges.

For both cases, include 30 days of database storage and any applicable backup
retention, and include the full month of any always-on supporting services.
Use the continuous case as the conservative budget until a schedule is agreed.

## Cost estimate still required

No fixed Rand amount is quoted here because current South Africa North prices
depend on subscription offer, currency, tax, exact SKU, active hours, storage,
backup, log ingestion and outbound data. Before deployment, enter the following
into the Azure Pricing Calculator and save/export the estimate:

- Region: South Africa North.
- Container Apps Consumption: API + worker replica count, vCPU/memory and
  actual active hours.
- PostgreSQL Flexible Server: Burstable B1ms (or lowest currently available
  suitable SKU), 32 GiB storage, 7-day backup, active hours and stop periods.
- ACR Standard (current template): one registry, expected image storage and retention. Verify student allowance eligibility; compare Basic if not covered.
- Monitoring: minimal ingestion and short retention.
- Networking: quote the selected private or restricted-public design, including
  any NAT gateway, private endpoints and DNS charges.
- Currency: ZAR if supported by the subscription/calculator; otherwise record
  the calculator currency and conversion date separately.

Calculator: https://azure.microsoft.com/pricing/calculator/

## South Africa North availability caveat

South Africa North is the selected target region. Before provisioning, verify
for the actual subscription:
- Container Apps availability and selected Consumption plan in the region.
- PostgreSQL Flexible Server Burstable SKU and PostGIS extension support.
- ACR Basic availability.
- Required Container Apps VNet integration/subnet requirements if choosing
  private PostgreSQL networking.
- Quotas and regional capacity.

If a required service/SKU is unavailable, stop and ask the owner before
proposing another region. South Africa West is not an automatic fallback.

## Approval gate

Before any resource is created, obtain explicit approval for:
1. The calculator estimate and numeric maximum spend in ZAR (or documented
   subscription currency).
2. The planned active dates/hours.
3. Whether the demo needs real Firebase push delivery or only API/database
   demonstration.
4. Private PostgreSQL networking (selected; existing VNet and delegated subnets).
5. Data retention/export and resource-group deletion date.

No Azure resources are created by this document. No prices here are a quote.

## Selected operating mode (confirmed 2026-11-16)

**Testing and demonstrations only for the 30-day assessment.** This is not an
always-available emergency service. Do not use it for real emergencies.

- Existing resources already verified: `rg-safecircle-student` in South Africa
  North and `vnet-safecircle-student` with `snet-postgres` (10.20.1.0/27)
  and `snet-containerapps` (10.20.2.0/27).
- **No new Azure resources are authorized.** Compilation and read-only what-if
  checks are allowed; provisioning, publishing, and database changes are not.
- The Container Apps template defaults to API min/max 1 and worker min/max 1.
  **Neither app automatically shuts down between sessions.** Do not describe
  API scale-to-zero as a way to stop the worker. Explicitly stopping the apps
  requires a separately approved operational procedure and support verification.
- During approved test windows, API and worker must both be running, PostgreSQL
  must be started, and `/health/ready` plus push delivery must be tested before
  demonstrating panic/emergency notifications.
- Outside test windows, plan to stop the API and worker together and stop
  PostgreSQL only after the app workloads have stopped. Confirm Azure CLI support,
  expected restart latency, and how to restore both apps before scheduling this.
  Do not treat PostgreSQL stop as free: storage/backups remain billable.
- ACR, DNS, logging, and other provisioned resources may cost money even when
  apps and database compute are stopped. Verify any fixed VNet-integrated
  Container Apps environment charges, including dedicated infrastructure.
- Before provisioning: record test dates/hours, expected runtime, remaining
  student credits, subscription-specific free allowance eligibility, a calculator
  estimate for South Africa North, and an explicit numeric spending ceiling.
- Delete only the temporary resources after evidence and necessary data are
  exported; **do not blindly delete the existing resource group or VNet**,
  because those resources predate the proposed deployment.

### Active-hour planning examples (not Azure quotes)

For API 0.5 vCPU/1 GiB and worker 0.25 vCPU/0.5 GiB,
the combined allocation is 0.75 vCPU and 1.5 GiB while both run.

| Total active hours over 30 days | vCPU-seconds at full active allocation | GiB-seconds at full active allocation |
|---:|---:|---:|
| 10 | 27,000 | 54,000 |
| 20 | 54,000 | 108,000 |
| 40 | 108,000 | 216,000 |
| 720 (comparison only) | 1,944,000 | 3,888,000 |

These are capacity arithmetic, **not billed usage estimates**; Azure may apply
different active/idle rates and charges, and quotas/free allowances depend on
subscription eligibility. Keep a separate full-month line for fixed services.
