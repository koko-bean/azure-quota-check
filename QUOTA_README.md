Azure quota verification — setup and secrets

1) Create a service principal with limited scope and store as AZURE_CREDENTIALS.

Run locally (replace <subscriptionId>):

az ad sp create-for-rbac --name "github-actions-quota-check" --role Contributor --scopes /subscriptions/<subscriptionId> --sdk-auth

Copy the returned JSON and add it as a GitHub repository secret named AZURE_CREDENTIALS (Repository Settings -> Secrets -> Actions).

2) Configure quotas to check

Copy quota-config.sample.json to quota-config.json and add the provider quota
resources consumed by the deployment. Discover names with `az quota list`;
resource counts are not quota availability.

Each entry can also include an optional `vmSku` field (e.g. `Standard_D4s_v5`)
to additionally validate that an exact VM SKU is available in the target
region before checking family-level quota — see "SKU-specific validation"
below.

3) Behavior

- The workflow runs on pull_request and can be run manually.
- The script (`scripts/check-azure-quotas.ps1`) queries real Azure quota via
  `az quota show` / `az quota usage show` for each configured provider quota
  resource, and calculates available capacity as limit minus usage. It no
  longer counts existing resources — a count-based check can pass even when
  there is no headroom to deploy more.
- Requires the Azure CLI `quota` extension (`az extension add --name quota`)
  and the `Microsoft.Quota` resource provider registered on the subscription.
- Exit codes: `0` = sufficient quota, `2` = quota deficit or SKU issue found
  (blocks deployment), `3` = prerequisite/configuration error (missing
  extension, unregistered provider, wrong subscription).

SKU-specific validation

- Azure quota is tracked per VM **family** (e.g. `standardDSv3Family`), not
  per exact SKU. Having family quota available does not guarantee a specific
  SKU is offered in a given region.
- When a `quotas` entry sets `vmSku`, the script first runs
  `az vm list-skus` to confirm the SKU exists in the target region and has
  no `Location`-type restriction, then resolves its VM family to run the
  normal quota check.
- SKU regional-availability problems are tracked separately from quota
  deficits (as `sku-issue-<sku>-<timestamp>.json` artifacts) because a quota
  increase or support ticket cannot fix them — only choosing a different
  region or SKU can. See `scripts/README.md#sku-specific-validation` for
  details.
- For quota requests or support tickets, use `scripts/request-azure-quota.ps1`
  and `scripts/submit-azure-support-ticket.ps1` (both dry-run by default;
  pass `-Submit` to actually submit).

4) Notes

- Ensure the service principal has Reader access to the quota APIs
  (`Microsoft.Quota/*/read`), plus Quota Request Operator if quota-increase
  submission is required.
- The workflow installs the Azure CLI `quota` extension on ubuntu-latest; the
  azure/login action performs authentication using AZURE_CREDENTIALS.
