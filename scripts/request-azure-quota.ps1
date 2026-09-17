param(
  [string]$ArtifactDirectory = 'artifacts\quota-requests',
  [switch]$Submit,
  [switch]$AutoConfirm,
  [switch]$VerboseOutput
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$Message) {
  Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
  [Console]::Error.WriteLine("Azure CLI is not installed or is not available on PATH.")
  exit 3
}
if (-not (Test-Path $ArtifactDirectory)) {
  [Console]::Error.WriteLine("Artifacts folder not found: $ArtifactDirectory")
  exit 3
}

$extensionOutput = & az extension show --name quota --output none 2>&1
if ($LASTEXITCODE -ne 0) {
  [Console]::Error.WriteLine("Azure CLI quota extension is required. Install it with 'az extension add --name quota'.")
  exit 3
}

$providerOutput = & az provider show --namespace Microsoft.Quota --query registrationState --output tsv 2>&1
$quotaProviderRegistered = $LASTEXITCODE -eq 0 -and ($providerOutput -join '').Trim() -eq 'Registered'
if (-not $quotaProviderRegistered -and $Submit) {
  [Console]::Error.WriteLine("Microsoft.Quota must be registered before quota requests can be submitted.")
  exit 3
}
if (-not $quotaProviderRegistered) {
  Write-Warning "Microsoft.Quota is not registered. Dry-run output will be generated, but submission is unavailable."
}

$summaryFile = Get-ChildItem -Path $ArtifactDirectory -Filter 'quota-request-summary-*.md' -File |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1
if (-not $summaryFile) {
  [Console]::Error.WriteLine("No quota request summary was found in $ArtifactDirectory.")
  exit 3
}

$timestamp = $summaryFile.BaseName -replace '^quota-request-summary-', ''
$requestFiles = Get-ChildItem -Path $ArtifactDirectory -Filter "quota-request-*-$timestamp.json" -File
if ($requestFiles.Count -eq 0) {
  [Console]::Error.WriteLine("No quota request JSON files matched summary batch $timestamp.")
  exit 3
}

$skippedRequests = @()
$requests = foreach ($file in $requestFiles) {
  $request = Get-Content $file.FullName -Raw | ConvertFrom-Json

  if ($request.submissionMethod -eq 'support-ticket') {
    # e.g. App Service Plan quota: Microsoft.Web is not onboarded to the
    # self-service Microsoft.Quota API, so 'az quota update' cannot request
    # it. Route these to submit-azure-support-ticket.ps1 instead.
    $skippedRequests += $request
    continue
  }

  foreach ($property in @('resourceName', 'resourceType', 'scope', 'requestedLimit')) {
    if ($null -eq $request.$property -or [string]::IsNullOrWhiteSpace([string]$request.$property)) {
      [Console]::Error.WriteLine("$($file.Name) is missing required property '$property'.")
      exit 3
    }
  }
  $request
}

if ($skippedRequests.Count -gt 0) {
  Write-Step "Skipping requests that require a support ticket"
  foreach ($skipped in $skippedRequests) {
    Write-Warning "$($skipped.name) cannot be requested via 'az quota update' ($($skipped.providerNamespace) is not adjustable through the Quota API). Use submit-azure-support-ticket.ps1 instead."
  }
}

if ($requests.Count -eq 0) {
  Write-Host "`nNo adjustable quota requests remain after excluding support-ticket-only items." -ForegroundColor Yellow
  exit 0
}

Write-Step "Prepared quota updates"
foreach ($request in $requests) {
  Write-Host "`nQuota:           $($request.name)" -ForegroundColor Yellow
  Write-Host "Resource name:   $($request.resourceName)"
  Write-Host "Scope:           $($request.scope)"
  Write-Host "Current limit:   $($request.currentLimit)"
  Write-Host "Requested limit: $($request.requestedLimit)"
  Write-Host "Command: az quota update --resource-name $($request.resourceName) --scope $($request.scope) --limit-object value=$($request.requestedLimit) --resource-type $($request.resourceType)"
}

if (-not $Submit) {
  Write-Host "`nDRY RUN: no quota updates were submitted. Add -Submit to request them." -ForegroundColor Green
  exit 0
}

if (-not $AutoConfirm) {
  $confirmation = Read-Host "Submit $($requests.Count) quota increase request(s)? (y/N)"
  if ($confirmation -ne 'y') {
    Write-Host "Submission cancelled."
    exit 0
  }
}

Write-Step "Submitting quota updates"
foreach ($request in $requests) {
  $arguments = @(
    'quota', 'update',
    '--resource-name', [string]$request.resourceName,
    '--scope', [string]$request.scope,
    '--limit-object', "value=$($request.requestedLimit)",
    '--resource-type', [string]$request.resourceType,
    '--output', 'json'
  )
  if ($VerboseOutput) {
    Write-Host "az $($arguments -join ' ')" -ForegroundColor DarkGray
  }
  $response = & az @arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("Quota request failed for $($request.name): $($response -join [Environment]::NewLine)")
    exit 5
  }
  Write-Host "Submitted quota request for $($request.name)." -ForegroundColor Green
}

Write-Step "Request status"
$scopes = $requests.scope | Select-Object -Unique
foreach ($scope in $scopes) {
  & az quota request status list --scope $scope --output table
}
