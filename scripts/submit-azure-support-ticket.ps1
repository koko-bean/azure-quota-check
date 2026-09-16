param(
  [Parameter(Mandatory)][string]$ContactName,
  [Parameter(Mandatory)][string]$ContactEmail,
  [Parameter(Mandatory)][string]$Country,
  [Parameter(Mandatory)][string]$TimeZone,
  [ValidateSet('minimal', 'moderate', 'critical')][string]$Severity = 'minimal',
  [string]$PreferredSupportLanguage = 'en-US',
  [string]$ArtifactDirectory = 'artifacts\quota-requests',
  [switch]$Submit,
  [switch]$AutoConfirm,
  [switch]$VerboseOutput
)

$ErrorActionPreference = 'Stop'
$apiVersion = '2024-04-01'
$quotaServiceId = '/providers/Microsoft.Support/services/06bfd9d3-516b-d5c6-5802-169c800dec89'

$classificationMap = @{
  'Microsoft.Compute' = '/providers/Microsoft.Support/services/06bfd9d3-516b-d5c6-5802-169c800dec89/problemClassifications/e12e3d1d-7fa0-af33-c6d0-3c50df9658a3'
  'Microsoft.ContainerService' = '/providers/Microsoft.Support/services/06bfd9d3-516b-d5c6-5802-169c800dec89/problemClassifications/fbd21b88-0472-3179-e69b-f6b3b607cda7'
  'Microsoft.App' = '/providers/Microsoft.Support/services/06bfd9d3-516b-d5c6-5802-169c800dec89/problemClassifications/46b44c30-f436-775f-ab8e-b718d9c219a2'
  'Microsoft.Web' = '/providers/Microsoft.Support/services/06bfd9d3-516b-d5c6-5802-169c800dec89/problemClassifications/c51897a3-cf1b-7444-30d9-532e0d8895d1'
  'Microsoft.Network' = '/providers/Microsoft.Support/services/06bfd9d3-516b-d5c6-5802-169c800dec89/problemClassifications/4b994745-d2fe-c6cf-00d0-b358c8526f2d'
}

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

$accountOutput = & az account show --output json 2>&1
if ($LASTEXITCODE -ne 0) {
  [Console]::Error.WriteLine("Unable to determine Azure subscription: $($accountOutput -join [Environment]::NewLine)")
  exit 3
}
$account = ($accountOutput -join [Environment]::NewLine) | ConvertFrom-Json

$nameParts = $ContactName.Trim().Split(' ', 2, [System.StringSplitOptions]::RemoveEmptyEntries)
if ($nameParts.Count -eq 0) {
  [Console]::Error.WriteLine("ContactName must contain at least a first name.")
  exit 2
}
$firstName = $nameParts[0]
$lastName = if ($nameParts.Count -gt 1) { $nameParts[1] } else { '-' }

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

Write-Step "Validating Azure Support discovery APIs"
$serviceOutput = & az rest --method get --uri "https://management.azure.com${quotaServiceId}?api-version=$apiVersion" --output json 2>&1
if ($LASTEXITCODE -ne 0) {
  [Console]::Error.WriteLine("Unable to read the Azure quota support service: $($serviceOutput -join [Environment]::NewLine)")
  exit 4
}
Write-Host "PASS: Azure Support quota service is readable." -ForegroundColor Green

$preparedTickets = @()
foreach ($file in $requestFiles) {
  $request = Get-Content $file.FullName -Raw | ConvertFrom-Json
  $classificationId = $classificationMap[[string]$request.providerNamespace]
  if (-not $classificationId) {
    [Console]::Error.WriteLine("No support problem classification is mapped for provider $($request.providerNamespace).")
    exit 4
  }

  $classificationOutput = & az rest --method get --uri "https://management.azure.com${classificationId}?api-version=$apiVersion" --output json 2>&1
  if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("Unable to validate classification for $($request.name): $($classificationOutput -join [Environment]::NewLine)")
    exit 4
  }
  $classification = ($classificationOutput -join [Environment]::NewLine) | ConvertFrom-Json

  $ticketName = "quota-$($request.resourceName -replace '[^A-Za-z0-9-]', '-')-$(Get-Date -Format 'yyyyMMddHHmmss')"
  $uri = "https://management.azure.com/subscriptions/$($account.id)/providers/Microsoft.Support/supportTickets/${ticketName}?api-version=$apiVersion"
  $description = @"
Request an Azure quota increase.

Quota: $($request.name)
Provider: $($request.providerNamespace)
Quota resource: $($request.resourceName)
Location: $($request.location)
Current usage: $($request.currentUsage)
Current limit: $($request.currentLimit)
Available: $($request.available)
Required available capacity: $($request.requiredAvailable)
Requested limit: $($request.requestedLimit)
Scope: $($request.scope)
"@

  $body = @{
    location = 'global'
    properties = @{
      advancedDiagnosticConsent = 'No'
      contactDetails = @{
        country = $Country
        firstName = $firstName
        lastName = $lastName
        preferredContactMethod = 'email'
        preferredSupportLanguage = $PreferredSupportLanguage
        preferredTimeZone = $TimeZone
        primaryEmailAddress = $ContactEmail
      }
      description = $description
      problemClassificationId = $classificationId
      serviceId = $quotaServiceId
      severity = $Severity
      title = "Quota increase: $($request.name) in $($request.location)"
    }
  }

  $preparedTickets += [pscustomobject]@{
    Name = $ticketName
    Classification = $classification.properties.displayName
    Uri = $uri
    Body = $body
  }
}

Write-Step "Prepared support ticket payloads"
foreach ($ticket in $preparedTickets) {
  Write-Host "`nTicket:         $($ticket.Name)" -ForegroundColor Yellow
  Write-Host "Classification: $($ticket.Classification)"
  Write-Host "Endpoint:       $($ticket.Uri)"
  Write-Host ($ticket.Body | ConvertTo-Json -Depth 10)
}

if (-not $Submit) {
  Write-Host "`nDRY RUN: no support tickets were created. Add -Submit to create them." -ForegroundColor Green
  exit 0
}

if (-not $AutoConfirm) {
  $confirmation = Read-Host "Create $($preparedTickets.Count) Azure support ticket(s)? (y/N)"
  if ($confirmation -ne 'y') {
    Write-Host "Submission cancelled."
    exit 0
  }
}

Write-Step "Submitting support tickets"
foreach ($ticket in $preparedTickets) {
  if ($VerboseOutput) {
    Write-Host "PUT $($ticket.Uri)" -ForegroundColor DarkGray
  }
  $bodyJson = $ticket.Body | ConvertTo-Json -Depth 10 -Compress
  $response = & az rest --method put --uri $ticket.Uri --body $bodyJson --output json 2>&1
  if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("Failed to create $($ticket.Name): $($response -join [Environment]::NewLine)")
    exit 5
  }
  Write-Host "Submitted $($ticket.Name)." -ForegroundColor Green
}
