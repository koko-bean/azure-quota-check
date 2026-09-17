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

# App Service Plan entries (appServicePlanSku) use 'az appservice' and
# 'az rest' against Microsoft.Web directly; Microsoft.Web is not onboarded to
# the Microsoft.Quota API, so the quota extension/provider registration is
# only required when at least one entry needs the real 'az quota' commands.
$needsQuotaApi = @($config.quotas | Where-Object { -not $_.appServicePlanSku }).Count -gt 0

if ($needsQuotaApi) {
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
} else {
  Write-Host "Skipping quota extension/provider registration checks: all configured quotas use appServicePlanSku (Microsoft.Web, checked via az appservice/az rest)." -ForegroundColor DarkGray
}

Write-Host "Subscription: $subscriptionId"
Write-Host "Location:     $($config.location)"
Write-Host "Principal:    $($account.user.name) ($($account.user.type))"

function Test-VmSkuAvailability {
  param(
    [Parameter(Mandatory)][string]$Sku,
    [Parameter(Mandatory)][string]$Location
  )

  $skuResult = Invoke-AzJson -Arguments @(
    'vm', 'list-skus',
    '--location', $Location,
    '--query', "[?name=='$Sku']",
    '--output', 'json'
  ) -Description "SKU availability lookup for $Sku in $Location"

  if (-not $skuResult -or $skuResult.Count -eq 0) {
    return [pscustomobject]@{ Found = $false; Family = $null; Available = $false; Restrictions = @() }
  }

  $skuInfo = $skuResult[0]
  $locationRestrictions = @($skuInfo.restrictions | Where-Object { $_.type -eq 'Location' })
  $zoneRestrictions = @($skuInfo.restrictions | Where-Object { $_.type -eq 'Zone' })

  return [pscustomobject]@{
    Found = $true
    Family = [string]$skuInfo.family
    Available = ($locationRestrictions.Count -eq 0)
    Restrictions = @($skuInfo.restrictions)
    ZoneRestricted = ($zoneRestrictions.Count -gt 0)
  }
}

function Test-AppServicePlanQuota {
  param(
    [Parameter(Mandatory)][string]$Sku,
    [Parameter(Mandatory)][string]$Tier,
    [Parameter(Mandatory)][string]$Family,
    [Parameter(Mandatory)][string]$Location,
    [Parameter(Mandatory)][string]$SubscriptionId
  )

  # App Service Plan quota is not exposed via 'az quota' (Microsoft.Web is not
  # onboarded to that API), so region availability and quota/usage are read
  # from the classic appservice CLI and the Microsoft.Web usages REST API.
  $locationsOutput = & az appservice list-locations --sku $Sku --output json 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "App Service Plan SKU location lookup for $Sku failed: $($locationsOutput -join [Environment]::NewLine)"
  }
  $locations = @(($locationsOutput -join [Environment]::NewLine) | ConvertFrom-Json)

  $candidateNames = @($Location)
  $displayNameLookup = Invoke-AzJson -Arguments @(
    'account', 'list-locations',
    '--query', "[?name=='$Location' || displayName=='$Location']",
    '--output', 'json'
  ) -Description "Location display name lookup for $Location"
  if ($displayNameLookup -and $displayNameLookup.Count -gt 0) {
    $candidateNames += [string]$displayNameLookup[0].displayName
    $candidateNames += [string]$displayNameLookup[0].name
  }
  $normalize = { param($value) ($value -replace '[\s_-]', '').ToLowerInvariant() }
  $normalizedCandidates = @($candidateNames | ForEach-Object { & $normalize $_ } | Select-Object -Unique)

  $regionAvailable = $false
  foreach ($loc in $locations) {
    $locName = if ($loc -is [string]) { $loc } else { [string]$loc.name }
    if ($normalizedCandidates -contains (& $normalize $locName)) {
      $regionAvailable = $true
      break
    }
  }

  if (-not $regionAvailable) {
    return [pscustomobject]@{ RegionAvailable = $false; Limit = $null; Usage = $null }
  }

  $usagesUri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Web/locations/$Location/usages?api-version=2023-12-01"
  $usagesOutput = & az rest --method get --uri $usagesUri --output json 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Microsoft.Web usage lookup in $Location failed: $($usagesOutput -join [Environment]::NewLine)"
  }
  $usages = @((($usagesOutput -join [Environment]::NewLine) | ConvertFrom-Json).value)
  $normalizedTier = & $normalize $Tier

  $match = $usages | Where-Object {
    $_.name.value -eq $Family -and (& $normalize $_.name.localizedValue) -eq $normalizedTier
  } | Select-Object -First 1

  if (-not $match) {
    return [pscustomobject]@{ RegionAvailable = $true; Limit = $null; Usage = $null }
  }

  return [pscustomobject]@{
    RegionAvailable = $true
    Limit = [int]$match.limit
    Usage = [int]$match.currentValue
  }
}

$deficits = @()
$skuIssues = @()
$checkErrors = @()

Write-Step "Checking configured quotas"
foreach ($quota in $config.quotas) {
  $displayName = if ($quota.name) { [string]$quota.name } else { [string]$quota.resourceName }
  $providerNamespace = [string]$quota.providerNamespace
  $resourceName = [string]$quota.resourceName
  $vmSku = [string]$quota.vmSku
  $appServicePlanSku = [string]$quota.appServicePlanSku
  $appServicePlanTier = [string]$quota.appServicePlanTier
  $requiredAvailable = [int]$quota.requiredAvailable
  $resourceType = if ($quota.resourceType) { [string]$quota.resourceType } else { 'dedicated' }

  Write-Host "`n[$displayName]" -ForegroundColor Yellow
  Write-Host "Provider:           $providerNamespace"

  if ($appServicePlanSku) {
    Write-Host "App Service SKU:    $appServicePlanSku"
    Write-Host "App Service tier:   $appServicePlanTier"

    if (-not $appServicePlanTier -or -not $resourceName) {
      $checkErrors += "$displayName sets appServicePlanSku but is missing appServicePlanTier or resourceName (the underlying VM family, e.g. standardDADSv5Family)."
      Write-Warning $checkErrors[-1]
      continue
    }

    try {
      $planCheck = Test-AppServicePlanQuota -Sku $appServicePlanSku -Tier $appServicePlanTier -Family $resourceName -Location $config.location -SubscriptionId $subscriptionId
    } catch {
      $checkErrors += "$displayName App Service Plan availability lookup failed: $_"
      Write-Warning $checkErrors[-1]
      continue
    }

    if (-not $planCheck.RegionAvailable) {
      $skuIssues += [pscustomobject]@{
        requestType = 'sku-unavailable'
        name = $displayName
        vmSku = $appServicePlanSku
        location = [string]$config.location
        reason = "App Service Plan SKU $appServicePlanSku ($appServicePlanTier) is not offered in $($config.location). Choose a different region or SKU; a quota increase will not resolve this."
      }
      Write-Warning "App Service Plan SKU $appServicePlanSku is not offered in $($config.location)."
      continue
    }

    if ($null -eq $planCheck.Limit) {
      $checkErrors += "${displayName}: no Microsoft.Web quota entry matched family '$resourceName' and tier '$appServicePlanTier' in $($config.location). Verify these values with 'az rest --method get --uri https://management.azure.com/subscriptions/${subscriptionId}/providers/Microsoft.Web/locations/$($config.location)/usages?api-version=2023-12-01'."
      Write-Warning $checkErrors[-1]
      continue
    }

    $limit = $planCheck.Limit
    $usage = $planCheck.Usage
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
        scope = "/subscriptions/$subscriptionId/providers/$providerNamespace/locations/$($config.location)"
        location = [string]$config.location
        currentUsage = $usage
        currentLimit = $limit
        available = $available
        requiredAvailable = $requiredAvailable
        requestedLimit = $requestedLimit
        appServicePlanSku = $appServicePlanSku
        appServicePlanTier = $appServicePlanTier
        submissionMethod = 'support-ticket'
      }
    } else {
      Write-Host "PASS: sufficient quota is available." -ForegroundColor Green
    }
    continue
  }

  if ($vmSku) {
    Write-Host "VM SKU:             $vmSku"
    try {
      $skuCheck = Test-VmSkuAvailability -Sku $vmSku -Location $config.location
    } catch {
      $checkErrors += "$displayName SKU availability lookup failed: $_"
      Write-Warning $checkErrors[-1]
      continue
    }

    if (-not $skuCheck.Found) {
      $skuIssues += [pscustomobject]@{
        requestType = 'sku-unavailable'
        name = $displayName
        vmSku = $vmSku
        location = [string]$config.location
        reason = 'SKU not returned by az vm list-skus for this location. It may not exist or may not be offered to this subscription.'
      }
      Write-Warning "SKU $vmSku was not found in $($config.location) for this subscription."
      continue
    }

    if (-not $skuCheck.Available) {
      $skuIssues += [pscustomobject]@{
        requestType = 'sku-unavailable'
        name = $displayName
        vmSku = $vmSku
        location = [string]$config.location
        reason = 'SKU is restricted for this subscription in this location. Choose a different region or request access; a quota increase will not resolve this.'
      }
      Write-Warning "SKU $vmSku is not available for this subscription in $($config.location). This is a regional/subscription restriction, not a quota limit."
      continue
    }

    if ($skuCheck.ZoneRestricted) {
      Write-Warning "SKU $vmSku has availability-zone restrictions in $($config.location). Verify the target zone before deploying."
    }

    Write-Host "VM family:          $($skuCheck.Family)"
    if (-not $resourceName) { $resourceName = $skuCheck.Family }
  }

  $scope = if ($quota.scope) {
    [string]$quota.scope
  } else {
    "/subscriptions/$subscriptionId/providers/$providerNamespace/locations/$($config.location)"
  }

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

if ($deficits.Count -eq 0 -and $skuIssues.Count -eq 0) {
  Write-Step "Quota validation passed"
  Write-Host "All configured quotas have sufficient available capacity and all requested SKUs are available." -ForegroundColor Green
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

if ($skuIssues.Count -gt 0) {
  $summary.AppendLine("## SKU availability issues (not fixable by quota request)") | Out-Null
  $summary.AppendLine() | Out-Null
  foreach ($issue in $skuIssues) {
    $safeName = $issue.vmSku -replace '[^A-Za-z0-9._-]', '-'
    $artifactPath = Join-Path $artifactDirectory "sku-issue-$safeName-$timestamp.json"
    $issue | ConvertTo-Json -Depth 8 | Out-File -FilePath $artifactPath -Encoding utf8

    $summary.AppendLine("### $($issue.name)") | Out-Null
    $summary.AppendLine("- VM SKU: $($issue.vmSku)") | Out-Null
    $summary.AppendLine("- Location: $($issue.location)") | Out-Null
    $summary.AppendLine("- Issue: $($issue.reason)") | Out-Null
    $summary.AppendLine() | Out-Null
  }
  Write-Warning "$($skuIssues.Count) SKU availability issue(s) found. These require a different region or SKU; a quota increase will not help."
}

foreach ($deficit in $deficits) {
  $safeName = $deficit.resourceName -replace '[^A-Za-z0-9._-]', '-'
  $artifactPath = Join-Path $artifactDirectory "quota-request-$safeName-$timestamp.json"
  $deficit | ConvertTo-Json -Depth 8 | Out-File -FilePath $artifactPath -Encoding utf8

  $summary.AppendLine("## $($deficit.name)") | Out-Null
  $summary.AppendLine("- Provider: $($deficit.providerNamespace)") | Out-Null
  $summary.AppendLine("- Quota resource: $($deficit.resourceName)") | Out-Null
  if ($deficit.appServicePlanSku) {
    $summary.AppendLine("- App Service Plan SKU: $($deficit.appServicePlanSku) ($($deficit.appServicePlanTier))") | Out-Null
  }
  $summary.AppendLine("- Current usage: $($deficit.currentUsage)") | Out-Null
  $summary.AppendLine("- Current limit: $($deficit.currentLimit)") | Out-Null
  $summary.AppendLine("- Available: $($deficit.available)") | Out-Null
  $summary.AppendLine("- Required available: $($deficit.requiredAvailable)") | Out-Null
  $summary.AppendLine("- Requested limit: $($deficit.requestedLimit)") | Out-Null
  if ($deficit.submissionMethod -eq 'support-ticket') {
    $summary.AppendLine("- Submission method: Azure support ticket (Microsoft.Web is not adjustable via 'az quota update')") | Out-Null
  }
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
