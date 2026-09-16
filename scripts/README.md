# Azure Quota Check Scripts

Pure PowerShell scripts for verifying Azure quotas. No CI/CD tool dependencies—use with any deployment system.

## Scripts

### check-azure-quotas.ps1

Main quota verification script. It uses `az quota show` and
`az quota usage show` to compare available quota with deployment requirements.
Configure the quota resources needed by the deployment, such as:

- **AKS** — VM-family vCPU and Public IP quota used by the cluster
- **Container Apps** — `ManagedEnvironmentCount` and workload-profile quota
- **App Service** — SKU-specific Microsoft.Web quota discovered for the subscription
- **Networking** — Standard Public IPv4 address quota

**Usage:**

```powershell
pwsh ./scripts/check-azure-quotas.ps1 -ConfigPath quota-config.json
```

**Parameters:**
- `-ConfigPath` — Path to JSON config file (default: `quota-config.json`)
- `-VerboseOutput` — Print each Azure CLI command

**Exit Codes:**
- `0` — All checks passed ✅
- `2` — Quotas insufficient; artifacts generated ⚠️
- `3+` — Script error ❌

**Output:**
- Generates `artifacts/quota-requests/` folder with:
  - `quota-request-summary-<timestamp>.md` — Human-readable summary
  - `quota-request-<Resource>-<timestamp>.json` — Per-resource details

### request-azure-quota.ps1

Preview or submit adjustable quota increases through `az quota update`.

```powershell
# Dry run
pwsh ./scripts/request-azure-quota.ps1

# Submit after reviewing the generated commands
pwsh ./scripts/request-azure-quota.ps1 -Submit
```

Submission requires the `Microsoft.Quota` provider to be registered and the
caller to have the **Quota Request Operator** role.

### submit-azure-support-ticket.ps1

Prepare one Azure Support ticket per quota category. The script is a dry run
unless `-Submit` is supplied and uses Support API version `2024-04-01`.

**Usage:**

```powershell
pwsh ./scripts/submit-azure-support-ticket.ps1 `
  -ContactName "Your Name" `
  -ContactEmail "your@example.com" `
  -Country "USA" `
  -TimeZone "Eastern Standard Time"

# Create tickets after reviewing the payloads
pwsh ./scripts/submit-azure-support-ticket.ps1 `
  -ContactName "Your Name" `
  -ContactEmail "your@example.com" `
  -Country "USA" `
  -TimeZone "Eastern Standard Time" `
  -Submit
```

**Parameters:**
- `-ContactName` — Your name (required)
- `-ContactEmail` — Your email (required)
- `-Country` — Contact country required by the Support API
- `-TimeZone` — Windows time-zone name required by the Support API
- `-Severity` — `minimal`, `moderate`, or `critical` (default: `minimal`)
- `-Submit` — Create tickets; omitted means dry run
- `-AutoConfirm` — Skip the prompt when combined with `-Submit`

**Requirements:**
- `Microsoft.Support/supportTickets/*` permissions (contact your Azure admin)
- Run from repo root (looks for `artifacts/quota-requests/`)

**Note:** If you lack support ticket permissions, use `create-github-quota-issue.ps1` instead.

### create-github-quota-issue.ps1

Create a GitHub issue as a fallback quota request mechanism.

**Usage:**

```powershell
$env:GITHUB_TOKEN = "your-pat-or-actions-token"

pwsh ./scripts/create-github-quota-issue.ps1 `
  -Owner "your-org" `
  -Repo "your-repo" `
  -RepoToken $env:GITHUB_TOKEN
```

**Parameters:**
- `-Owner` — GitHub org or username (required)
- `-Repo` — Repository name (required)
- `-RepoToken` — GitHub Personal Access Token or `$env:GITHUB_TOKEN` (required)

**Requirements:**
- GitHub token with **Issues** write scope
- Run from repo root (looks for `artifacts/quota-requests/`)

**Output:**
- Creates GitHub issue with:
  - Title: `[Quota Request] ...`
  - Label: `quota-request`
  - Body: Formatted deficits from artifacts

## Authentication

Before running scripts, authenticate with Azure:

```powershell
# Interactive login
az login --subscription <subscription-id>

# Or use service principal
az login --service-principal \
  -u <client-id> \
  -p '<client-secret>' \
  --tenant <tenant-id>

az account set --subscription <subscription-id>
```

## Configuration

Scripts read from `quota-config.json`:

```json
{
  "subscriptionId": "your-subscription-id",
  "location": "eastus",
  "quotas": [
    {
      "name": "Total regional vCPUs",
      "providerNamespace": "Microsoft.Compute",
      "resourceName": "cores",
      "resourceType": "dedicated",
      "requiredAvailable": 10
    }
  ]
}
```

Copy from `quota-config.sample.json`, then discover valid resource names with:

```powershell
az quota list --scope /subscriptions/<id>/providers/<provider>/locations/<region> --output table
```

There is no universal "AKS cluster count" or "App Service Plan count" quota.
Configure the underlying provider quotas consumed by the planned SKU and topology.

## Integration Examples

See `examples/` folder for sample configurations:
- **Jenkins** — Jenkinsfile
- **GitLab CI** — .gitlab-ci.yml
- **Azure DevOps** — azure-pipelines.yml

Each example shows how to:
1. Authenticate with Azure
2. Call `check-azure-quotas.ps1`
3. Handle exit codes and artifacts
4. Optionally submit quota requests

## Local Testing

```bash
# 1. Authenticate
az login
az account set --subscription <your-id>

# 2. Edit quota-config.json with your requirements

# 3. Run the checker
pwsh ./scripts/check-azure-quotas.ps1 -ConfigPath quota-config.json

# 4. Check artifacts
ls artifacts/quota-requests/

# 5. Preview quota updates
pwsh ./scripts/request-azure-quota.ps1

# 6. (Optional) Preview support-ticket fallback
pwsh ./scripts/submit-azure-support-ticket.ps1 \
  -ContactName "Your Name" \
  -ContactEmail "you@example.com" \
  -Country "USA" \
  -TimeZone "Eastern Standard Time"
```

## Troubleshooting

### "Microsoft.Quota is NotRegistered"

A subscription owner must run:

```powershell
az provider register --namespace Microsoft.Quota
```

The pipeline identity needs Reader to check quota and **Quota Request Operator**
to submit increases.

### "Support ticket creation failed with 403"

Your principal lacks `Microsoft.Support/supportTickets/*` permissions. Use GitHub issue fallback or open tickets manually via Azure Portal.

### "GitHub token not found"

Set `GITHUB_TOKEN` env var or pass `-RepoToken` explicitly:

```powershell
$env:GITHUB_TOKEN = "ghp_..."
pwsh ./scripts/create-github-quota-issue.ps1 -Owner "you" -Repo "your-repo" -RepoToken $env:GITHUB_TOKEN
```

## Security

- **Service principal**: Use `Reader` role; grant `Microsoft.Support/*` permissions separately if needed
- **GitHub token**: Use `$env:GITHUB_TOKEN` (auto-provided in Actions) or a fine-grained PAT with Issues scope
- **Config file**: May contain subscription ID; don't commit to public repos
- **Artifacts**: Contain quota details; restrict access as needed

## Performance

- vCPU check: ~2-5 seconds
- Resource counts: ~3-10 seconds per service
- Quota query pair: ~2-10 seconds per configured resource
- **Total**: typically under one minute

## Contributing

To extend for additional Azure services:

1. Add a new quota object to `quota-config.sample.json`
2. Discover its quota resource name with `az quota list`
3. Add the provider, quota resource name, and required available capacity
4. Update this README with the mapping

## Support

Open an issue for bugs, feature requests, or CI/CD integration help.
