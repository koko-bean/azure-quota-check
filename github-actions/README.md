# GitHub Actions Integration

Use this folder to integrate Azure quota checks into GitHub Actions workflows.

## Setup

### 1. Add the Workflow

Copy `workflows/azure-quota-verification.yml` to your repository:

```bash
mkdir -p .github/workflows
cp github-actions/workflows/azure-quota-verification.yml .github/workflows/
```

### 2. Create Azure Service Principal

From your Azure subscription, run:

```bash
az ad sp create-for-rbac --name "github-actions-quota-check" \
  --role Reader \
  --scopes /subscriptions/<your-subscription-id> \
  --sdk-auth -o json
```

Copy the JSON output.

### 3. Add GitHub Secret

Go to **Repository Settings → Secrets and variables → Actions → New repository secret**:
- **Name:** `AZURE_CREDENTIALS`
- **Value:** Paste the JSON from step 2

### 4. Configure Quotas

Edit `quota-config.json` in your repository root:

```json
{
  "subscriptionId": "your-subscription-id",
  "location": "eastus",
  "quotas": [
    {
      "name": "Standard D-family v5 vCPUs",
      "providerNamespace": "Microsoft.Compute",
      "vmSku": "Standard_D4s_v5",
      "resourceType": "dedicated",
      "requiredAvailable": 16
    },
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

Set `vmSku` (e.g. `Standard_D4s_v5`) instead of `resourceName` to also confirm
the exact SKU is offered in the target region/subscription before checking
its VM-family quota — see [scripts/README.md](../scripts/README.md#sku-specific-validation)
for details.

For App Service Plans, set `appServicePlanSku` (e.g. `P1V3`) and
`appServicePlanTier` (e.g. `Premium v3`) instead of `vmSku` — Microsoft.Web
isn't onboarded to `az quota`, so this checks regional plan-version
availability and tier quota through `az appservice list-locations` and the
Microsoft.Web `usages` REST API. See
[scripts/README.md](../scripts/README.md#app-service-plan-versiontier-validation)
for details. Deficits found this way require a support ticket, not
`az quota update`.

Before the workflow can run, a subscription owner must register
`Microsoft.Quota` (skipped automatically if every configured entry uses
`appServicePlanSku`). Use `az quota list` to discover valid quota resource names.

### 5. Commit & Push

Commit both files and push to a branch → open PR. The workflow runs automatically.

Or manually trigger: **Actions → azure-quota-verification → Run workflow**.

## How It Works

- Workflow runs on every PR and manual dispatch
- Authenticates with service principal using AZURE_CREDENTIALS secret
- Calls `scripts/check-azure-quotas.ps1` to validate quotas
- If quotas are insufficient, generates artifacts with 3 submission options:
  1. **Azure Portal** (manual)
  2. **CLI auto-submit** (requires Microsoft.Support permissions)
  3. **GitHub Issue** (fallback, no special permissions)
- Uploads artifacts to GitHub Actions for download

## Exit Codes

- **0**: All checks passed ✅
- **2**: Quotas insufficient; artifacts generated ⚠️
- **3+**: Script error ❌

## Troubleshooting

### "AZURE_CREDENTIALS secret not found"

- Go to **Settings → Secrets and variables → Actions**
- Verify the secret exists and contains valid JSON

### "Quota verification failed"

- Check the **quota-requests** artifact in the workflow run
- Review the summary markdown for details
- Follow one of the 3 submission options to request increases

### "Role assignment creation failed"

- Ensure your Azure account has `Owner` or `User Access Administrator` role in the subscription
- Or ask a subscription admin to run the `az ad sp create-for-rbac` command for you

## More Info

See the main [README.md](../README.md) for script details and configuration options.
