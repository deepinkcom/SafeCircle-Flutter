# SafeCircle Azure cost-planning worksheet

Status: planning only. No Azure resources are created by this worksheet. Prices
are intentionally not hard-coded: Azure pricing varies by region, currency,
subscription offer, SKU, usage and date. Obtain a live quote from the Azure
Pricing Calculator for the intended subscription and region before approval.

## Candidate region

Initial planning region: South Africa North, subject to checking availability
for each required service and SKU. Do not assume all Container Apps, PostgreSQL,
ACR networking, zone-redundancy or private-link features are available in that
region. If a service is unavailable, compare another approved region and assess
data residency, latency, regulatory and cross-region data-transfer implications.

## Cost components to quote

| Component | Planning configuration | Cost driver / decision |
|---|---|---|
| Container Apps environment | Workload profiles / consumption mode to be selected | API and worker vCPU-seconds, GiB-seconds, replicas, environment/networking |
| SafeCircle API | 0.5 vCPU, 1 GiB starting template; minimum 1 replica | Always-on baseline plus peak scale-out |
| Push worker | 0.5 vCPU, 1 GiB starting template; exactly 1 replica | Continuous polling means continuous compute |
| PostgreSQL Flexible Server | Burstable B1ms and 32 GiB are template defaults only | Server uptime, compute SKU, provisioned storage, backup overage, HA |
| Container Registry | Basic by default | Registry storage, transactions, selected SKU |
| Private networking | VNet, private DNS; optional NAT/private endpoints | NAT gateway hourly/data processing, private endpoint hourly/data, DNS, egress |
| Monitoring | Azure Monitor / Log Analytics | Ingestion volume, retention and alerting |
| Data transfer | Client traffic, push integrations, cross-region dependencies | Outbound bandwidth and cross-region traffic |

## Required calculator scenarios

Prepare at least these three scenarios in the Azure Pricing Calculator:

1. **Development / demonstration**: one API replica, one worker replica,
   smallest supported non-production database SKU, short log retention. This
   is not suitable for emergency-service production.
2. **Pilot**: one always-on API replica, one always-on worker, production-like
   database storage and backup retention, monitoring and alerting.
3. **Production**: API redundancy and scale-out, database HA where supported,
   restore testing, longer backup retention, private networking, monitoring,
   and a documented disaster-recovery target.

For each scenario record:
- Region and currency.
- SKU, replica count, hours/month, storage and backup assumptions.
- Monthly estimated subtotal by service.
- Data transfer and monitoring assumptions.
- Tax, support plan and any discounts separately.
- Calculator estimate date and URL/export.

## Availability and cost trade-offs

- The API and polling worker currently have minimum replica counts of one.
  Scaling either to zero may reduce cost but is not recommended for this
  emergency-response use case without a tested alternative architecture.
- The PostgreSQL Bicep template currently disables high availability and
  geo-redundant backup. Production approval must explicitly decide whether
  those settings meet the application's recovery objectives.
- Premium ACR is needed for the private-endpoint pattern. Basic ACR is cheaper
  but the current template leaves public registry access enabled by default.
- Private networking can add fixed costs (for example NAT gateway or private
  endpoints) and operational complexity. Validate whether the selected
  Container Apps networking mode can reach the delegated PostgreSQL subnet and
  registry private endpoint before choosing a topology.

## Approval gate

Do not provision anything until the project owner has approved:
1. The region and data residency.
2. Development, pilot or production sizing.
3. A monthly budget and alert threshold.
4. HA, backup retention and recovery objectives.
5. Network design and public/private exposure.
6. A resource-by-resource Azure Pricing Calculator estimate.

No prices in this document are a quote or promise of availability.
