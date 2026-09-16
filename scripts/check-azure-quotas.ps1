param(
  [string]$ConfigPath = "quota-config.json"
)

Write-Host "Loading config: $ConfigPath"
if (-not (Test-Path $ConfigPath)) {
  Write-Error "Config not found at $ConfigPath. Copy quota-config.sample.json to $ConfigPath and edit values."
  exit 2
}

try {
  $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
} catch {
  Write-Error "Failed to parse config JSON: $_"
  exit 2
}

$location = $config.location
if (-not $location) { Write-Error "location must be set in config"; exit 2 }

Write-Host "Using subscription and location from Azure context"
$subscriptionId = az account show --query id -o tsv
if (-not $subscriptionId) { Write-Error "Unable to determine subscription id"; exit 2 }
Write-Host "Subscription: $subscriptionId, Location: $location"

$global:exitCode = 0

# vCPU check (definitive)
if ($config.vcpu -and $config.vcpu.required -ne $null) {
  $vcpuReq = [int]$config.vcpu.required
  Write-Host "Checking regional vCPU availability for $location (required: $vcpuReq)"
  $usageJson = az vm list-usage --location $location -o json | ConvertFrom-Json
  $vcpuEntry = $usageJson | Where-Object { $_.name.value -eq 'Total Regional vCPUs' }
  if ($vcpuEntry) {
    $current = [int]$vcpuEntry.currentValue
    $limit = [int]$vcpuEntry.limit
    Write-Host "vCPU current: $current, limit: $limit"
    if ($limit -gt 0 -and ($limit - $current) -lt $vcpuReq) {
      $deficit = @{ resource = 'vCPUs'; required = $vcpuReq; available = ($limit - $current); provider = 'vm.list-usage'; details = "current=$current; limit=$limit" }
      if (-not $global:deficits) { $global:deficits = @() };
      $global:deficits += $deficit
      Write-Warning "Insufficient vCPUs: needed $vcpuReq, available $(($limit - $current)) - recorded for quota request"
      $global:exitCode = 2
    } else { Write-Host "vCPU check passed" }
  } else {
    Write-Warning "Could not find vCPU usage entry. Skipping strict vCPU quota check."
  }
}

# App Service Plans: count existing plans in location
if ($config.appServicePlans -and $config.appServicePlans.required -ne $null) {
  $aspReq = [int]$config.appServicePlans.required
  Write-Host "Checking App Service Plans in $location (expected <= $aspReq)"
  $plans = az appservice plan list -o json | ConvertFrom-Json
  $locationPlans = $plans | Where-Object { $_.location -eq $location }
  $count = ($locationPlans | Measure-Object).Count
  Write-Host "Found $count App Service Plans in $location"
  if ($count -ge $aspReq) { Write-Host "Existing App Service Plans meet or exceed requested count" } else { 
    $deficit = @{ resource = 'AppServicePlans'; required = $aspReq; available = $count; provider = 'AppServicePlanList'; details = "found=$count in $location" }
    if (-not $global:deficits) { $global:deficits = @() };
    $global:deficits += $deficit
    Write-Warning "Fewer App Service Plans found than requested ($count < $aspReq) - recorded for quota request" }
}

# AKS: count clusters in location
if ($config.aks -and $config.aks.requiredClusters -ne $null) {
  $aksReq = [int]$config.aks.requiredClusters
  Write-Host "Checking AKS clusters in $location (expected <= $aksReq)"
  $aksList = az aks list -o json | ConvertFrom-Json
  $aksLocation = $aksList | Where-Object { $_.location -eq $location }
  $aksCount = ($aksLocation | Measure-Object).Count
  Write-Host "Found $aksCount AKS clusters in $location"
  if ($aksCount -ge $aksReq) { Write-Host "AKS cluster count meets or exceeds requested" } else { 
    $deficit = @{ resource = 'AKSClusters'; required = $aksReq; available = $aksCount; provider = 'AKSList'; details = "found=$aksCount in $location" }
    if (-not $global:deficits) { $global:deficits = @() };
    $global:deficits += $deficit
    Write-Warning "AKS clusters fewer than requested ($aksCount < $aksReq) - recorded for quota request" }
}

# Container Apps: count container apps in location
if ($config.containerApps -and $config.containerApps.required -ne $null) {
  $caReq = [int]$config.containerApps.required
  Write-Host "Checking Container Apps in $location (expected <= $caReq)"
  $caListJson = az containerapp list -o json 2>$null
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "'az containerapp' command not available or failed; skipping Container Apps counts"
  } else {
    $caList = $caListJson | ConvertFrom-Json
    $caLocation = $caList | Where-Object { $_.location -eq $location }
    $caCount = ($caLocation | Measure-Object).Count
    Write-Host "Found $caCount Container Apps in $location"
    if ($caCount -ge $caReq) { Write-Host "Container Apps count meets or exceeds requested" } else { 
      $deficit = @{ resource = 'ContainerApps'; required = $caReq; available = $caCount; provider = 'ContainerAppList'; details = "found=$caCount in $location" }
      if (-not $global:deficits) { $global:deficits = @() };
      $global:deficits += $deficit
      Write-Warning "Container Apps fewer than requested ($caCount < $caReq) - recorded for quota request" }
  }

  # Try provider quota API for Container Apps (Microsoft.App)
  function Invoke-AzRestSafe($uri){
    Write-Host "Calling az rest ${uri}"
    $resp = az rest --method get --uri $uri -o json 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Warning "az rest failed for ${uri}: $resp"; return $null }
    try { return $resp | ConvertFrom-Json } catch { Write-Warning "Failed to parse az rest response for ${uri}"; return $null }
  }

  $sub = $subscriptionId

  function Try-QueryProviderQuotas($namespace){
    Write-Host "Discovering provider $namespace"
    $provOut = az provider show --namespace $namespace -o json 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Warning "az provider show failed for ${namespace}: ${provOut}"; return $null }
    try { $prov = $provOut | ConvertFrom-Json } catch { Write-Warning "Failed to parse provider info for $namespace"; return $null }

    $apiVersions = @()
    if ($prov.resourceTypes) {
      foreach ($rt in $prov.resourceTypes) {
        if ($rt.apiVersions) { $apiVersions += $rt.apiVersions }
      }
    }
    $apiVersions = $apiVersions | Select-Object -Unique
    if (-not $apiVersions) { Write-Warning "No api-versions discovered for $namespace"; return $null }

    $patterns = @(
      "/subscriptions/$sub/providers/$namespace/locations/$location/quotas?api-version={0}",
      "/subscriptions/$sub/providers/$namespace/locations/$location/usages?api-version={0}",
      "/subscriptions/$sub/providers/$namespace/quotas?api-version={0}",
      "/subscriptions/$sub/providers/$namespace/usages?api-version={0}",
      "/subscriptions/$sub/providers/$namespace/providers/Microsoft.Quota/locations/$location/quotas?api-version={0}"
    )

    $maxTry = [math]::Min(4, $apiVersions.Count - 1)
    for ($i=0; $i -le $maxTry; $i++) {
      $ver = $apiVersions[$i]
      foreach ($pat in $patterns) {
        $uri = "https://management.azure.com" + ($pat -f $ver)
        $resp = Invoke-AzRestSafe $uri
        if ($resp) { return @{ uri = $uri; result = $resp } }
      }
    }
    return $null
  }

  $providerNamespaces = @(
    @{ name='Container Apps (Microsoft.App)'; ns='Microsoft.App' },
    @{ name='AKS/ContainerService (Microsoft.ContainerService)'; ns='Microsoft.ContainerService' },
    @{ name='App Service (Microsoft.Web)'; ns='Microsoft.Web' }
  )

  foreach ($p in $providerNamespaces) {
    Write-Host "Querying provider quota API: $($p.name)"
    $found = Try-QueryProviderQuotas $p.ns
    if (-not $found) { Write-Warning "No quota data returned for $($p.name) - might need different api-version or permissions"; continue }
    Write-Host "Found quota endpoint: $($found.uri)"
    $json = $found.result | ConvertTo-Json -Depth 6
    Write-Host $json
  }
}

# Public IPs: optional check
if ($config.publicIpAddresses -and $config.publicIpAddresses.required -ne $null) {
  $ipReq = [int]$config.publicIpAddresses.required
  Write-Host "Checking Public IP addresses in subscription (required: $ipReq)"
  $ips = az network public-ip list -o json | ConvertFrom-Json
  $ipsInLocation = $ips | Where-Object { $_.location -eq $location }
  $ipCount = ($ipsInLocation | Measure-Object).Count
  Write-Host "Found $ipCount Public IPs in $location"
  if ($ipCount -ge $ipReq) { Write-Host "Public IP count meets or exceeds requested" } else { 
    $deficit = @{ resource = 'PublicIPAddresses'; required = $ipReq; available = $ipCount; provider = 'Network.PublicIPList'; details = "found=$ipCount in $location" }
    if (-not $global:deficits) { $global:deficits = @() };
    $global:deficits += $deficit
    Write-Warning "Public IPs fewer than requested ($ipCount < $ipReq) - recorded for quota request" }
}

# After all checks, if deficits found write quota request artifacts
if ($global:deficits -and $global:deficits.Count -gt 0) {
  $artDir = Join-Path (Get-Location) 'artifacts\quota-requests'
  if (-not (Test-Path $artDir)) { New-Item -ItemType Directory -Path $artDir -Force | Out-Null }
  $time = Get-Date -Format 'yyyyMMdd-HHmmss'
  $summaryPath = Join-Path $artDir "quota-request-summary-$time.md"

  $sb = New-Object System.Text.StringBuilder
  $sb.AppendLine("# Quota request summary - $time") | Out-Null
  $sb.AppendLine('') | Out-Null
  foreach ($d in $global:deficits) {
    $sb.AppendLine("## Resource: $($d.resource)") | Out-Null
    $sb.AppendLine("Required: $($d.required)") | Out-Null
    $sb.AppendLine("Available: $($d.available)") | Out-Null
    $sb.AppendLine("Provider: $($d.provider)") | Out-Null
    $sb.AppendLine("Details: $($d.details)") | Out-Null
    $sb.AppendLine('') | Out-Null

    $itemJson = @{ resource = $d.resource; required = $d.required; available = $d.available; provider = $d.provider; details = $d.details } | ConvertTo-Json -Depth 5
    $itemPath = Join-Path $artDir "quota-request-$($d.resource)-$time.json"
    $itemJson | Out-File -FilePath $itemPath -Encoding utf8
  }

  $sb.AppendLine('---') | Out-Null
  $sb.AppendLine('## To request quota increases:') | Out-Null
  $sb.AppendLine('') | Out-Null
  $sb.AppendLine('### Option 1: Azure Portal (Manual)') | Out-Null
  $sb.AppendLine('1) Go to Help + support → New support request') | Out-Null
  $sb.AppendLine('2) Select "Quotas"') | Out-Null
  $sb.AppendLine('3) Attach the corresponding JSON files from this folder') | Out-Null
  $sb.AppendLine('') | Out-Null
  $sb.AppendLine('### Option 2: CLI (Automated, requires permissions)') | Out-Null
  $sb.AppendLine('```bash') | Out-Null
  $sb.AppendLine("pwsh ./scripts/submit-azure-support-ticket.ps1 -ContactName 'Your Name' -ContactEmail 'your.email@example.com' -AutoConfirm") | Out-Null
  $sb.AppendLine('```') | Out-Null
  $sb.AppendLine('') | Out-Null
  $sb.AppendLine('### Option 3: GitHub Issue (Fallback)') | Out-Null
  $sb.AppendLine('```bash') | Out-Null
  $sb.AppendLine("pwsh ./scripts/create-github-quota-issue.ps1 -Owner 'your-org' -Repo 'your-repo' -RepoToken `$env:GITHUB_TOKEN") | Out-Null
  $sb.AppendLine('```') | Out-Null
  $sb.AppendLine('') | Out-Null
  $sb.AppendLine('---') | Out-Null
  $sb.AppendLine('Copy the block below to email or issue tracker:') | Out-Null
  $sb.AppendLine('') | Out-Null
  foreach ($d in $global:deficits) { $sb.AppendLine("- $($d.resource): request increase to $($d.required) (available $($d.available))") | Out-Null }
  $sb.ToString() | Out-File -FilePath $summaryPath -Encoding utf8

  Write-Host "Generated quota request artifacts in: $artDir";
  Write-Host "Summary: $summaryPath";
  exit 2
}

Write-Host "Quota checks completed successfully"; exit 0
