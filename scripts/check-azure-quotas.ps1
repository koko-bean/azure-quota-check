param(
  [string]$ConfigPath = "quota-config.json",
  [switch]$VerboseOutput
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$Message) {
  Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Invoke-AzJson {
  param(
    [Parameter(Mandatory)][string[]]$Arguments,
    [Parameter(Mandatory)][string]$Description
  )

  if ($VerboseOutput) {
    Write-Host "az $($Arguments -join ' ')" -ForegroundColor DarkGray
  }

  $output = & az @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "$Description failed: $($output -join [Environment]::NewLine)"
  }

  return ($output -join [Environment]::NewLine) | ConvertFrom-Json
}

Write-Step "Loading configuration"
if (-not (Test-Path $ConfigPath)) {
  [Console]::Error.WriteLine("Config not found at $ConfigPath. Copy quota-config.sample.json to $ConfigPath and edit it.")
  exit 2
}

try {
  $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
} catch {
  [Console]::Error.WriteLine("Failed to parse config JSON: $_")
  exit 2
}

if (-not $config.location) {
  [Console]::Error.WriteLine("location must be set in config.")
  exit 2
}
if (-not $config.quotas -or $config.quotas.Count -eq 0) {
  [Console]::Error.WriteLine("At least one entry must be present in the quotas array.")
  exit 2
}

Write-Step "Validating Azure prerequisites"
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
  [Console]::Error.WriteLine("Azure CLI is not installed or is not available on PATH.")
  exit 3
}

try {
  $account = Invoke-AzJson -Arguments @('account', 'show', '--output', 'json') -Description 'Azure account lookup'
} catch {
  [Console]::Error.WriteLine([string]$_)
  exit 3
}

$subscriptionId = if ($config.subscriptionId) { [string]$config.subscriptionId } else { [string]$account.id }
if ($account.id -ne $subscriptionId) {
  [Console]::Error.WriteLine("Active subscription $($account.id) does not match configured subscription $subscriptionId. Run 'az account set --subscription $subscriptionId'.")
  exit 3
}

$quotaExtension = & az extension show --name quota --output none 2>&1
if ($LASTEXITCODE -ne 0) {
  [Console]::Error.WriteLine("Azure CLI quota extension is required. Install it with 'az extension add --name quota'.")
  exit 3
}

$quotaProvider = Invoke-AzJson -Arguments @(
  'provider', 'show',
  '--namespace', 'Microsoft.Quota',
  '--query', '{state:registrationState}',
  '--output', 'json'
) -Description 'Microsoft.Quota provider lookup'

if ($quotaProvider.state -ne 'Registered') {
  [Console]::Error.WriteLine("Microsoft.Quota is $($quotaProvider.state). A subscription owner must run 'az provider register --namespace Microsoft.Quota'.")
  exit 3
}

Write-Host "Subscription: $subscriptionId"
Write-Host "Location:     $($config.location)"
Write-Host "Principal:    $($account.user.name) ($($account.user.type))"

$deficits = @()
$checkErrors = @()

Write-Step "Checking configured quotas"
foreach ($quota in $config.quotas) {
  $displayName = if ($quota.name) { [string]$quota.name } else { [string]$quota.resourceName }
  $providerNamespace = [string]$quota.providerNamespace
  $resourceName = [string]$quota.resourceName
  $requiredAvailable = [int]$quota.requiredAvailable
  $resourceType = if ($quota.resourceType) { [string]$quota.resourceType } else { 'dedicated' }
  $scope = if ($quota.scope) {
    [string]$quota.scope
  } else {
    "/subscriptions/$subscriptionId/providers/$providerNamespace/locations/$($config.location)"
  }

  Write-Host "`n[$displayName]" -ForegroundColor Yellow
  Write-Host "Provider:           $providerNamespace"
  Write-Host "Quota resource:     $resourceName"
  Write-Host "Required available: $requiredAvailable"
  Write-Host "Scope:              $scope"

  if (-not $providerNamespace -or -not $resourceName -or $requiredAvailable -lt 0) {
    $checkErrors += "$displayName has an invalid providerNamespace, resourceName, or requiredAvailable value."
    Write-Warning $checkErrors[-1]
    continue
  }

  try {
    $limitResult = Invoke-AzJson -Arguments @(
      'quota', 'show',
      '--resource-name', $resourceName,
      '--scope', $scope,
      '--output', 'json'
    ) -Description "Quota limit lookup for $displayName"

    $usageResult = Invoke-AzJson -Arguments @(
      'quota', 'usage', 'show',
      '--resource-name', $resourceName,
      '--scope', $scope,
      '--output', 'json'
    ) -Description "Quota usage lookup for $displayName"

    $limit = [int]$limitResult.properties.limit.value
    $usage = [int]$usageResult.properties.usages.value
    $available = $limit - $usage

    Write-Host "Current usage:      $usage"
    Write-Host "Current limit:      $limit"
    Write-Host "Available:          $available"

    if ($available -lt $requiredAvailable) {
      $requestedLimit = $usage + $requiredAvailable
      Write-Warning "Insufficient quota. Requested limit must be at least $requestedLimit."
      $deficits += [pscustomobject]@{
        requestType = 'quota'
        name = $displayName
        providerNamespace = $providerNamespace
        resourceName = $resourceName
        resourceType = $resourceType
        scope = $scope
        location = [string]$config.location
        currentUsage = $usage
        currentLimit = $limit
        available = $available
        requiredAvailable = $requiredAvailable
        requestedLimit = $requestedLimit
      }
    } else {
      Write-Host "PASS: sufficient quota is available." -ForegroundColor Green
    }
  } catch {
    $message = "$displayName could not be checked: $_"
    $checkErrors += $message
    Write-Warning $message
  }
}

if ($checkErrors.Count -gt 0) {
  Write-Step "Quota checks incomplete"
  $checkErrors | ForEach-Object { Write-Host "- $_" -ForegroundColor Red }
  [Console]::Error.WriteLine("One or more quota checks could not be completed. No deployment decision should be made from partial results.")
  exit 3
}

if ($deficits.Count -eq 0) {
  Write-Step "Quota validation passed"
  Write-Host "All configured quotas have sufficient available capacity." -ForegroundColor Green
  exit 0
}

Write-Step "Writing quota request artifacts"
$artifactDirectory = Join-Path (Get-Location) 'artifacts\quota-requests'
New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$summaryPath = Join-Path $artifactDirectory "quota-request-summary-$timestamp.md"
$summary = New-Object System.Text.StringBuilder
$summary.AppendLine("# Quota request summary - $timestamp") | Out-Null
$summary.AppendLine() | Out-Null

foreach ($deficit in $deficits) {
  $safeName = $deficit.resourceName -replace '[^A-Za-z0-9._-]', '-'
  $artifactPath = Join-Path $artifactDirectory "quota-request-$safeName-$timestamp.json"
  $deficit | ConvertTo-Json -Depth 8 | Out-File -FilePath $artifactPath -Encoding utf8

  $summary.AppendLine("## $($deficit.name)") | Out-Null
  $summary.AppendLine("- Provider: $($deficit.providerNamespace)") | Out-Null
  $summary.AppendLine("- Quota resource: $($deficit.resourceName)") | Out-Null
  $summary.AppendLine("- Current usage: $($deficit.currentUsage)") | Out-Null
  $summary.AppendLine("- Current limit: $($deficit.currentLimit)") | Out-Null
  $summary.AppendLine("- Available: $($deficit.available)") | Out-Null
  $summary.AppendLine("- Required available: $($deficit.requiredAvailable)") | Out-Null
  $summary.AppendLine("- Requested limit: $($deficit.requestedLimit)") | Out-Null
  $summary.AppendLine() | Out-Null
}

$summary.AppendLine("## Next steps") | Out-Null
$summary.AppendLine("1. Preview quota updates: ``pwsh ./scripts/request-azure-quota.ps1``") | Out-Null
$summary.AppendLine("2. Submit adjustable quota updates: ``pwsh ./scripts/request-azure-quota.ps1 -Submit``") | Out-Null
$summary.AppendLine("3. Preview support-ticket fallback: ``pwsh ./scripts/submit-azure-support-ticket.ps1 -ContactName 'Your Name' -ContactEmail 'you@example.com' -Country 'USA' -TimeZone 'Eastern Standard Time'``") | Out-Null
$summary.ToString() | Out-File -FilePath $summaryPath -Encoding utf8

Write-Host "Generated $($deficits.Count) request artifact(s)."
Write-Host "Summary: $summaryPath"
exit 2
