# Azure Quota Check Scripts

Pure PowerShell scripts for verifying Azure quotas. No CI/CD tool dependencies—use with any deployment system.

## Scripts

### check-azure-quotas.ps1

Main quota verification script. Checks:
- **vCPU** — Current compute usage vs. subscription limit
- **App Service Plans** — Current count vs. required
- **AKS** — Cluster count + provider API queries
- **Container Apps** — Managed environment count + API queries
- **Public IPs** — Current count vs. required

**Usage:**

```powershell
pwsh ./scripts/check-azure-quotas.ps1 -ConfigPath quota-config.json
```

**Parameters:**
- `-ConfigPath` — Path to JSON config file (default: `quota-config.json`)

**Exit Codes:**
- `0` — All checks passed ✅
- `2` — Quotas insufficient; artifacts generated ⚠️
- `3+` — Script error ❌

**Output:**
- Generates `artifacts/quota-requests/` folder with:
  - `quota-request-summary-<timestamp>.md` — Human-readable summary
  - `quota-request-<Resource>-<timestamp>.json` — Per-resource details

### submit-azure-support-ticket.ps1

Auto-submit Azure support tickets for quota increase requests.

**Usage:**

```powershell
pwsh ./scripts/submit-azure-support-ticket.ps1 `
  -ContactName "Your Name" `
  -ContactEmail "your@example.com" `
  [-Severity "moderate"] `
  [-AutoConfirm]
```

**Parameters:**
- `-ContactName` — Your name (required)
- `-ContactEmail` — Your email (required)
- `-Severity` — Issue severity: `minimal`, `moderate`, `critical` (default: `moderate`)
- `-AutoConfirm` — Skip confirmation and submit immediately

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
  "vcpu": { "required": 10 },
  "appServicePlans": { "required": 2 },
  "aks": { "requiredClusters": 1 },
  "containerApps": { "required": 5 },
  "publicIpAddresses": { "required": 2 }
}
```

Copy from `quota-config.sample.json` and customize.

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

# 5. (Optional) Submit quota request
pwsh ./scripts/submit-azure-support-ticket.ps1 \
  -ContactName "Your Name" \
  -ContactEmail "you@example.com" \
  -AutoConfirm
```

## Troubleshooting

### "Could not find vCPU usage entry"

Regional vCPU queries may not work for all subscription types. Script skips this check gracefully; it's not a hard failure.

### "Provider API Not Found or InvalidResourceType"

Script auto-discovers API versions per provider. If failures persist:
- Verify service principal has `Reader` role
- Check subscription availability in target region
- Register provider: `az provider register --namespace Microsoft.App`

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
- Provider API discovery & queries: ~10-20 seconds
- **Total**: ~30-60 seconds depending on subscription size and network

## Contributing

To extend for additional Azure services:

1. Add a new quota object to `quota-config.sample.json`
2. Add a check function in `check-azure-quotas.ps1`
3. Call `az <service> list` or provider REST APIs
4. Compare against config and record deficits in `$global:deficits`
5. Update this README with the new check

## Support

Open an issue for bugs, feature requests, or CI/CD integration help.
