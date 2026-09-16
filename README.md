# Azure Quota Verification

Verify Azure quotas exist for services before deployment. Supports vCPU, App Service Plans, AKS, Container Apps, and Public IPs. Auto-generates quota-increase requests.

Platform-agnostic PowerShell scripts that work with any CI/CD tool, plus GitHub Actions integration.

## Quick Start: Choose Your Integration

### 🚀 Using GitHub Actions?

```bash
cd your-repo
cp -r github-actions/.github .
cp scripts/ .
cp quota-config.sample.json quota-config.json
```

Then follow: [`github-actions/README.md`](github-actions/README.md)

### 🔧 Using Jenkins, GitLab CI, Azure DevOps, or Custom Pipeline?

```bash
cp -r scripts/ your-repo/
cp quota-config.sample.json your-repo/quota-config.json
```

Then:
1. Follow: [`scripts/README.md`](scripts/README.md) for script usage
2. Copy example config from `examples/<your-ci-tool>/`
3. Customize and integrate

### 📋 All Platforms

1. Create Azure service principal with Reader role
2. Store credentials in your CI/CD platform
3. Edit `quota-config.json` with your requirements
4. Commit and run

## Repository Structure


```
azure-quota-check/
├── README.md (this file)
├── quota-config.sample.json (template config)
├── QUOTA_README.md (legacy; see github-actions/README.md and scripts/README.md)
│
├── github-actions/ (GitHub Actions integration)
│   ├── README.md (setup guide)
│   └── workflows/
│       └── azure-quota-verification.yml
│
├── scripts/ (pure PowerShell, CI/CD agnostic)
│   ├── README.md (usage guide)
│   ├── check-azure-quotas.ps1 (main quota checker)
│   ├── submit-azure-support-ticket.ps1 (auto-submit support tickets)
│   └── create-github-quota-issue.ps1 (GitHub issue fallback)
│
└── examples/ (sample CI/CD configurations)
    ├── jenkins/Jenkinsfile
    ├── gitlab-ci/.gitlab-ci.yml
    └── azure-devops/azure-pipelines.yml
```

## Core Features

| Resource | Source | Check Type |
|----------|--------|-----------|
| vCPU | az vm list-usage | Provider API (strict) |
| App Service Plans | az appservice plan list | Resource count |
| AKS | az aks list | Resource count + Provider API |
| Container Apps | az containerapp list | Resource count + Provider API |
| Public IPs | az network public-ip list | Resource count |

## How It Works

1. **Authenticate** with Azure (service principal or user credentials)
2. **Query resources** using Azure CLI and REST APIs
3. **Compare** current usage/count against `quota-config.json` requirements
4. **Generate artifacts** if any quota is insufficient:
   - Human-readable markdown summary
   - Per-resource JSON details
5. **Exit with code 2** to signal deployment halt
6. **Offer 3 submission options** for quota increases:
   - Azure Portal (manual)
   - CLI auto-submit (requires permissions)
   - GitHub issue (fallback, no special permissions)

## Exit Codes

- **0**: All checks passed ✅
- **2**: Quotas insufficient; artifacts generated ⚠️
- **3+**: Script error ❌

## Configuration

### quota-config.json

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

All fields optional except `location`. Customize based on your deployment needs.

## Requesting Quota Increases

When quotas are insufficient, artifacts are generated with 3 submission options:

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
  -AutoConfirm
```

### Option 3: GitHub Issue (Fallback, no special permissions)

```bash
export GITHUB_TOKEN="ghp_..."
pwsh ./scripts/create-github-quota-issue.ps1 \
  -Owner "your-org" \
  -Repo "your-repo" \
  -RepoToken $GITHUB_TOKEN
```

## Integration Examples

See `examples/` for sample configurations:

- **GitHub Actions**: Copy `github-actions/workflows/` to your repo's `.github/workflows/`
- **Jenkins**: Use `examples/jenkins/Jenkinsfile` as a base
- **GitLab CI**: Use `examples/gitlab-ci/.gitlab-ci.yml`
- **Azure DevOps**: Use `examples/azure-devops/azure-pipelines.yml`

## Authentication Setup

### 1. Create Service Principal

```bash
az ad sp create-for-rbac --name "quota-check" \
  --role Reader \
  --scopes /subscriptions/<subscription-id> \
  --sdk-auth -o json
```

### 2. Store Credentials

- **GitHub Actions**: Add JSON to `AZURE_CREDENTIALS` secret
- **Jenkins**: Add to Jenkins credentials store
- **GitLab CI**: Add as masked CI/CD variables
- **Azure DevOps**: Add to pipeline variable groups
- **Other**: Set `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID` env vars

### 3. Set Subscription & Region

Export environment variables or pass to scripts:

```bash
export AZURE_SUBSCRIPTION_ID="your-id"
export AZURE_LOCATION="eastus"

pwsh ./scripts/check-azure-quotas.ps1 -ConfigPath quota-config.json
```

## Local Testing

```bash
# 1. Authenticate
az login
az account set --subscription <your-id>

# 2. Edit config
cp quota-config.sample.json quota-config.json
# ... edit with your values ...

# 3. Run checker
pwsh ./scripts/check-azure-quotas.ps1 -ConfigPath quota-config.json

# 4. Check artifacts
ls artifacts/quota-requests/
```

## Troubleshooting

### Quota checks return incomplete data

- Verify service principal has `Reader` role
- Check region availability for services
- Register providers: `az provider register --namespace Microsoft.App`

### Support ticket creation fails with 403

Your principal lacks `Microsoft.Support/supportTickets/*` permissions.
Use Option 1 (Portal) or Option 3 (GitHub Issue) instead.

### vCPU usage shows empty

Regional vCPU queries may not work for all subscription types. Script skips gracefully; not a hard failure.

## Documentation
