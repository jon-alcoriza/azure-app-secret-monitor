# ===== Define the 3 environments =====
$environments = @(
    @{ Name = "DEV"; TenantId = $env:DEV_TENANT_ID; ClientId = $env:DEV_CLIENT_ID; ClientSecret = $env:DEV_CLIENT_SECRET }
    @{ Name = "STG"; TenantId = $env:STG_TENANT_ID; ClientId = $env:STG_CLIENT_ID; ClientSecret = $env:STG_CLIENT_SECRET }
    @{ Name = "PRD"; TenantId = $env:PRD_TENANT_ID; ClientId = $env:PRD_CLIENT_ID; ClientSecret = $env:PRD_CLIENT_SECRET }
)

$confluenceEmail    = $env:CONFLUENCE_EMAIL
$confluenceApiToken = $env:CONFLUENCE_API_TOKEN
$confluenceBase     = $env:CONFLUENCE_BASE_URL
$pageId             = $env:CONFLUENCE_PAGE_ID

function Get-SecretStatus {
    param([Nullable[datetime]]$ExpirationDate)
    if (-not $ExpirationDate) { return @{ Status = "N/A"; Color = "Grey" } }

    $today = Get-Date
    $oneMonthThreshold = $today.AddMonths(1)
    $threeMonthThreshold = $today.AddMonths(3)

    if ($ExpirationDate -lt $today) {
        return @{ Status = "Expired"; Color = "Red" }
    }
    elseif ($ExpirationDate -le $oneMonthThreshold) {
        return @{ Status = "Critical - Expiring within 1 Month"; Color = "Yellow" }
    }
    elseif ($ExpirationDate -le $threeMonthThreshold) {
        return @{ Status = "Expiring Soon"; Color = "Blue" }
    }
    else {
        return @{ Status = "Valid"; Color = "Green" }
    }
}

# ===== Loop through each tenant, pull app registrations =====
$allRows = @()

foreach ($envConfig in $environments) {
    Write-Output "Pulling data for $($envConfig.Name)..."

    $tokenBody = @{
        grant_type    = "client_credentials"
        client_id     = $envConfig.ClientId
        client_secret = $envConfig.ClientSecret
        scope         = "https://graph.microsoft.com/.default"
    }
    $tokenResponse = Invoke-RestMethod -Method Post `
        -Uri "https://login.microsoftonline.com/$($envConfig.TenantId)/oauth2/v2.0/token" `
        -Body $tokenBody
    $graphHeader = @{ Authorization = "Bearer $($tokenResponse.access_token)" }

    $apps = @()
    $uri = "https://graph.microsoft.com/v1.0/applications?`$top=999"
    do {
        $resp = Invoke-RestMethod -Uri $uri -Headers $graphHeader -Method Get
        $apps += $resp.value
        $uri = $resp.'@odata.nextLink'
    } while ($uri)

    foreach ($app in $apps) {
        if (-not $app.passwordCredentials -or $app.passwordCredentials.Count -eq 0) {
            $s = Get-SecretStatus -ExpirationDate $null
            $allRows += [PSCustomObject]@{
                Environment = $envConfig.Name
                AppName = $app.displayName; AppId = $app.appId
                Secret = "N/A"; Expires = "N/A"
                Status = $s.Status; Color = $s.Color
            }
        } else {
            foreach ($secret in $app.passwordCredentials) {
                $expiry = [datetime]$secret.endDateTime
                $s = Get-SecretStatus -ExpirationDate $expiry
                $allRows += [PSCustomObject]@{
                    Environment = $envConfig.Name
                    AppName = $app.displayName; AppId = $app.appId
                    Secret = $secret.displayName
                    Expires = $expiry.ToString("yyyy-MM-dd")
                    Status = $s.Status; Color = $s.Color
                }
            }
        }
    }
}

# ===== Build the Confluence table, one section per environment =====
function Build-TableBlock {
    param($rowsForEnv, $envLabel)
    $tableRows = ""
    foreach ($row in ($rowsForEnv | Sort-Object Expires)) {
        $tableRows += @"
<tr>
<td>$($row.AppName)</td>
<td>$($row.AppId)</td>
<td>$($row.Secret)</td>
<td>$($row.Expires)</td>
<td><ac:structured-macro ac:name="status"><ac:parameter ac:name="colour">$($row.Color)</ac:parameter><ac:parameter ac:name="title">$($row.Status)</ac:parameter></ac:structured-macro></td>
</tr>
"@
    }
    return @"
<h2>$envLabel</h2>
<table>
<tbody>
<tr><th>App Name</th><th>App ID</th><th>Secret Name</th><th>Expires</th><th>Status</th></tr>
$tableRows
</tbody>
</table>
"@
}

$fullBody = (Build-TableBlock ($allRows | Where-Object Environment -eq "DEV") "DEV/QA") +
            (Build-TableBlock ($allRows | Where-Object Environment -eq "STG") "STG") +
            (Build-TableBlock ($allRows | Where-Object Environment -eq "PRD") "PRD")

# ===== Push to Confluence =====
$authHeader = @{
    Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$confluenceEmail`:$confluenceApiToken"))
}

$page = Invoke-RestMethod -Uri "$confluenceBase/rest/api/content/$pageId`?expand=version" `
    -Headers $authHeader -Method Get

$nextVersion = $page.version.number + 1

$updateBody = @{
    id      = $pageId
    type    = "page"
    title   = $page.title
    version = @{ number = $nextVersion }
    body    = @{
        storage = @{
            value          = $fullBody
            representation = "storage"
        }
    }
} | ConvertTo-Json -Depth 10

Invoke-RestMethod -Uri "$confluenceBase/rest/api/content/$pageId" `
    -Headers ($authHeader + @{ "Content-Type" = "application/json" }) `
    -Method Put -Body $updateBody

Write-Output "Confluence page updated. $($allRows.Count) secrets processed."

# ===== Flag items for email alerts =====
$urgentRows   = $allRows | Where-Object { $_.Status -in @("Expired", "Critical - Expiring within 1 Month", "Expiring Soon") }
$criticalRows = $allRows | Where-Object { $_.Status -in @("Expired", "Critical - Expiring within 1 Month") }

if ($urgentRows.Count -gt 0) {
    $summary = ($urgentRows | ForEach-Object {
        "$($_.Environment) | $($_.AppName) | $($_.Secret) | Expires: $($_.Expires) | Status: $($_.Status)"
    }) -join "`n"
    Set-Content -Path "urgent_summary.txt" -Value $summary
    "NEEDS_ALERT=true" >> $env:GITHUB_OUTPUT
} else {
    "NEEDS_ALERT=false" >> $env:GITHUB_OUTPUT
}

if ($criticalRows.Count -gt 0) {
    $criticalSummary = ($criticalRows | ForEach-Object {
        "$($_.Environment) | $($_.AppName) | $($_.Secret) | Expires: $($_.Expires) | Status: $($_.Status)"
    }) -join "`n"
    Set-Content -Path "critical_summary.txt" -Value $criticalSummary
    "NEEDS_CRITICAL_ALERT=true" >> $env:GITHUB_OUTPUT
    Write-Output "Found $($criticalRows.Count) critical item(s) (expired or within 1 month)."
} else {
    "NEEDS_CRITICAL_ALERT=false" >> $env:GITHUB_OUTPUT
}

Write-Output "Found $($urgentRows.Count) urgent item(s) total."
