# Azure Quota Verification Workflow

Verify Azure quotas exist for services before deployment. Supports vCPU, App Service Plans, AKS, Container Apps, and Public IPs. Auto-generates quota-increase requests.

## Files

- `.github/workflows/azure-quota-verification.yml` - GitHub Actions workflow
- `scripts/check-azure-quotas.ps1` - Main quota checker (vCPU, resource counts, provider APIs)
- `scripts/submit-azure-support-ticket.ps1` - Auto-submit Azure support ticket (requires permissions)
- `scripts/create-github-quota-issue.ps1` - Create GitHub issue fallback (requires GITHUB_TOKEN)
- `quota-config.json` - Quota requirements (edit with your values)
- `QUOTA_README.md` - Detailed setup instructions

## Quick Start

### 1. Set Azure Credentials

Create a service principal with Reader role:

```bash
az ad sp create-for-rbac --name "github-actions-quota-check" \
  --role Reader \
  --scopes /subscriptions/<your-subscription-id> \
  --sdk-auth -o json
```

Copy the JSON output and add as GitHub secret: **AZURE_CREDENTIALS** (Repo → Settings → Secrets → Actions).

### 2. Configure Quotas

Edit `quota-config.json`:

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

### 3. Run Workflow

Commit and push to a branch → open PR. Workflow runs automatically.

Or manually: Actions → azure-quota-verification → Run workflow.

## How It Works

### Checks Performed

| Resource | Source | Check Type |
|----------|--------|-----------|
| vCPU | az vm list-usage | Provider API (strict) |
| App Service Plans | az appservice plan list | Resource count |
| AKS | az aks list | Resource count + Provider API |
| Container Apps | az containerapp list | Resource count + Provider API |
| Public IPs | az network public-ip list | Resource count |

### Exit Codes

- **0**: All checks passed ✅
- **2**: Quotas insufficient; artifacts generated ⚠️
- **3+**: Script error ❌

### When Quotas Are Insufficient

The script generates artifacts in `artifacts/quota-requests/`:

- `quota-request-summary-<timestamp>.md` - Human-readable summary with 3 options to increase quotas
- `quota-request-<Resource>-<timestamp>.json` - Per-resource deficit details

GitHub Actions workflow uploads these as an artifact for download.

## Requesting Quota Increases

### Option 1: Azure Portal (Manual)

1. Go to **Help + support** → **New support request**
2. Select **Quotas** and the specific service/region
3. Attach JSON files from `artifacts/quota-requests/`
4. Submit

### Option 2: CLI (Automated, requires Microsoft.Support permissions)

```bash
pwsh ./scripts/submit-azure-support-ticket.ps1 \
  -ContactName "Your Name" \
  -ContactEmail "you@example.com" \
  -Severity "moderate" \
  -AutoConfirm
```

**Permissions required**: `Microsoft.Support/supportTickets/write`

### Option 3: GitHub Issue (Fallback, requires GITHUB_TOKEN)

```bash
pwsh ./scripts/create-github-quota-issue.ps1 \
  -Owner "your-org" \
  -Repo "your-repo" \
  -RepoToken $env:GITHUB_TOKEN
```

## Troubleshooting

### Workflow fails with "Not Found" or "InvalidResourceType"

The script auto-discovers supported API versions per provider. If failures persist, check:
- Service principal permissions (Reader role minimum)
- Subscription availability in target region
- Provider registration: `az provider register --namespace Microsoft.App` (etc.)

### "Could not find vCPU usage entry"

Regional vCPU queries may not work for all subscription types. The script skips this check if data is unavailable; it's not a hard failure.

### Support ticket creation fails with 403

Your principal lacks `Microsoft.Support/supportTickets/*` permissions. Use Option 1 (Portal) or Option 3 (GitHub Issue) instead.

## Configuration Schema

### Root

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| subscriptionId | string | Optional | Subscription ID (auto-detected if omitted) |
| location | string | Yes | Azure region (e.g., "eastus") |
| vcpu | object | Optional | vCPU quota config |
| appServicePlans | object | Optional | App Service Plans config |
| aks | object | Optional | AKS config |
| containerApps | object | Optional | Container Apps config |
| publicIpAddresses | object | Optional | Public IPs config |

### Quota Objects

```json
{
  "vcpu": { "required": 10 },
  "appServicePlans": { "required": 2 },
  "aks": { "requiredClusters": 1 },
  "containerApps": { "required": 5 },
  "publicIpAddresses": { "required": 2 }
}
```

## Local Testing

Authenticate with service principal:

```bash
az login --service-principal \
  -u <clientId> \
  -p '<clientSecret>' \
  --tenant <tenantId>

az account set --subscription <subscriptionId>

pwsh ./scripts/check-azure-quotas.ps1 -ConfigPath quota-config.json
```

Then check `artifacts/quota-requests/` for generated artifacts.

## Security

- **AZURE_CREDENTIALS secret**: Store securely; restrict to trusted workflows
- **Service principal**: Use Reader role only; grant Microsoft.Support permissions separately if auto-submitting tickets
- **GitHub token**: Use GITHUB_TOKEN (auto-provided) or a fine-grained PAT with Issues write scope
- **Artifacts**: May contain environment details; restrict artifact access accordingly

## Contributing

To extend checks for additional services:

1. Add a new section in `scripts/check-azure-quotas.ps1`
2. Call `az <service> list` or provider REST APIs
3. Compare against `$config.<service>`
4. Record deficits in `$global:deficits`
5. Update `quota-config.sample.json` and README

## Support

For issues or questions, open a GitHub issue or refer to QUOTA_README.md for detailed setup.
