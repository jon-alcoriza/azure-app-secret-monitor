# App Secret Expiry Monitor

Automatically checks Entra ID (Azure AD) app registration client secret expiration dates across multiple environments (DEV/QA, STG, PRD — each in its own tenant), publishes a color-coded status table to Confluence, and sends email alerts when secrets are expiring or expired.

Runs entirely on GitHub Actions — no Azure subscription or server required.

---

## How it works

1. GitHub Actions triggers on a schedule (default: every Monday 6am UTC)
2. A PowerShell script authenticates to each of your 3 Entra tenants (DEV/QA, STG, PRD) using a dedicated app registration per tenant
3. It pulls all app registrations + their client secret expiration dates via Microsoft Graph
4. Each secret gets a status:
   - **Red — Expired**: expiration date has passed
   - **Yellow — Critical**: expires within 1 month
   - **Blue — Expiring Soon**: expires within 3 months
   - **Green — Valid**: expires more than 3 months out
   - **Grey — N/A**: no secret / no expiration date
5. The script builds an HTML table (using Confluence's `status` macro for colored lozenges) and pushes it to a Confluence page, one section per environment
6. Two separate email alerts fire depending on severity:
   - **Standard alert** — sent when any secret is Red, Yellow, or Blue (inside the 3-month window)
   - **Critical alert** — sent additionally when any secret is Red or Yellow (expired or expiring within 1 month), so the most urgent items don't get lost among longer-lead-time items

---

## Prerequisites

- Admin rights in each of the 3 Entra directories (DEV/QA, STG, PRD)
- A Confluence page where the table will be published, and edit access to it
- A GitHub account (free tier is sufficient)
- A Gmail (or other SMTP-capable) account to use as the sender for alert emails — the recipient can be any email, including your corporate address

---

## Step 1 — Create an app registration in each Entra tenant

Repeat this once per tenant (switch directories via the top-right selector in the Azure Portal). If DEV and QA share the same tenant, you only need to do this once for that combined environment.

1. Go to **portal.azure.com** → **Entra ID** → **App registrations** → **New registration**
2. Name it e.g. `SecretExpiryMonitor-DEV` (or `-STG`, `-PRD`)
3. Supported account types: **Single tenant**
4. Redirect URI: leave blank
5. Click **Register**
6. Note down the **Application (client) ID** and **Directory (tenant) ID** from the overview page
7. Go to **Certificates & secrets** → **New client secret** → set an expiration (12–24 months) → **Add**
8. **Copy the secret value immediately** — it's only shown once
9. Go to **API permissions** → **Add a permission** → **Microsoft Graph** → **Application permissions** → search and select `Application.Read.All` → **Add permissions**
10. Click **Grant admin consent for [tenant]**

At the end of this step you should have **9 values total**: Tenant ID, Client ID, and Client Secret for each of DEV/QA, STG, and PRD.

---

## Step 2 — Get your Confluence credentials

**API Token**
1. Go to `id.atlassian.com/manage-profile/security/api-tokens`
2. **Create API token** → label it → **Create**
3. Copy the token immediately (shown only once)

**Base URL**
From your Confluence page URL, take everything up through `/wiki`:
```
https://yourcompany.atlassian.net/wiki/spaces/TEAM/pages/123456789/Page+Title
                                   ^^^^^^^^^^^^^^^^^^^^^^ this part is the base URL
```
→ `CONFLUENCE_BASE_URL = https://yourcompany.atlassian.net/wiki`

**Page ID**
The number right after `/pages/` in the URL above.
→ `CONFLUENCE_PAGE_ID = 123456789`

**Email**
The Atlassian account email tied to the API token.

---

## Step 3 — Create a Gmail App Password (for sending alert emails)

1. Go to `myaccount.google.com` → **Security**
2. Turn on **2-Step Verification** if not already on
3. Search "App passwords" → `myaccount.google.com/apppasswords`
4. Name it `github-actions-expiry-monitor` → **Create**
5. Copy the 16-character password shown

The recipient email (`NOTIFY_EMAIL_TO`) can be any address — including your corporate email — regardless of which account sends it. Multiple recipients are supported (see Step 5 note below).

---

## Step 4 — Create the GitHub repository

1. Sign up / log in at `github.com`
2. Click **+** → **New repository**
3. Name it e.g. `app-secret-monitor`
4. Set visibility to **Private**
5. Check **Add a README file** → **Create repository**

---

## Step 5 — Add all secrets to GitHub

Repo → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**, one at a time. Use **Repository secrets** (not Environment secrets — this workflow doesn't use GitHub Environments, so Environment secrets wouldn't be reachable without extra config that isn't needed here):

| Secret name | Value |
|---|---|
| `DEV_TENANT_ID` | DEV/QA directory's tenant ID |
| `DEV_CLIENT_ID` | DEV/QA app registration's client ID |
| `DEV_CLIENT_SECRET` | DEV/QA app registration's client secret |
| `STG_TENANT_ID` | STG directory's tenant ID |
| `STG_CLIENT_ID` | STG app registration's client ID |
| `STG_CLIENT_SECRET` | STG app registration's client secret |
| `PRD_TENANT_ID` | PRD directory's tenant ID |
| `PRD_CLIENT_ID` | PRD app registration's client ID |
| `PRD_CLIENT_SECRET` | PRD app registration's client secret |
| `CONFLUENCE_EMAIL` | Your Atlassian account email |
| `CONFLUENCE_API_TOKEN` | Confluence API token |
| `CONFLUENCE_BASE_URL` | e.g. `https://yourcompany.atlassian.net/wiki` |
| `CONFLUENCE_PAGE_ID` | Target Confluence page ID |
| `SMTP_USERNAME` | Gmail address used to send alerts |
| `SMTP_PASSWORD` | Gmail app password from Step 3 |
| `NOTIFY_EMAIL_TO` | Recipient email(s) — comma-separated for multiple, e.g. `person1@company.com,person2@company.com` |

> Note: the `DEV_*` secret names stay as-is even though the table label is "DEV/QA" — the secret name is just an internal key, unrelated to the display label shown on the Confluence page.

---

## Step 6 — Add the PowerShell script

In the repo root, click **Add file** → **Create new file** → name it `check-expiry.ps1` → paste the following:

```powershell
# ===== Define the environments =====
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
```

Commit the file directly to `main`.

---

## Step 7 — Create the GitHub Actions workflow

In the repo, click **Add file** → **Create new file** → type the filename `.github/workflows/expiry-check.yml` (the `/` auto-creates the folder) → paste the following:

```yaml
name: App Secret Expiry Check

on:
  schedule:
    - cron: "0 6 * * 1"    # every Monday at 6am UTC
  workflow_dispatch:        # allows manual trigger from the Actions tab

jobs:
  run-check:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repo
        uses: actions/checkout@v4

      - name: Run expiry check script
        id: check
        shell: pwsh
        env:
          DEV_TENANT_ID: ${{ secrets.DEV_TENANT_ID }}
          DEV_CLIENT_ID: ${{ secrets.DEV_CLIENT_ID }}
          DEV_CLIENT_SECRET: ${{ secrets.DEV_CLIENT_SECRET }}
          STG_TENANT_ID: ${{ secrets.STG_TENANT_ID }}
          STG_CLIENT_ID: ${{ secrets.STG_CLIENT_ID }}
          STG_CLIENT_SECRET: ${{ secrets.STG_CLIENT_SECRET }}
          PRD_TENANT_ID: ${{ secrets.PRD_TENANT_ID }}
          PRD_CLIENT_ID: ${{ secrets.PRD_CLIENT_ID }}
          PRD_CLIENT_SECRET: ${{ secrets.PRD_CLIENT_SECRET }}
          CONFLUENCE_EMAIL: ${{ secrets.CONFLUENCE_EMAIL }}
          CONFLUENCE_API_TOKEN: ${{ secrets.CONFLUENCE_API_TOKEN }}
          CONFLUENCE_BASE_URL: ${{ secrets.CONFLUENCE_BASE_URL }}
          CONFLUENCE_PAGE_ID: ${{ secrets.CONFLUENCE_PAGE_ID }}
        run: pwsh -File ./check-expiry.ps1

      - name: Send alert email
        if: steps.check.outputs.NEEDS_ALERT == 'true'
        uses: dawidd6/action-send-mail@v3
        with:
          server_address: smtp.gmail.com
          server_port: 465
          username: ${{ secrets.SMTP_USERNAME }}
          password: ${{ secrets.SMTP_PASSWORD }}
          subject: "Warning: App Secret Expiry Alert"
          to: ${{ secrets.NOTIFY_EMAIL_TO }}
          from: App Secret Monitor
          body: file://urgent_summary.txt

      - name: Send critical alert email
        if: steps.check.outputs.NEEDS_CRITICAL_ALERT == 'true'
        uses: dawidd6/action-send-mail@v3
        with:
          server_address: smtp.gmail.com
          server_port: 465
          username: ${{ secrets.SMTP_USERNAME }}
          password: ${{ secrets.SMTP_PASSWORD }}
          subject: "URGENT: App Secret Expired or Expiring Within 1 Month"
          to: ${{ secrets.NOTIFY_EMAIL_TO }}
          from: App Secret Monitor
          body: file://critical_summary.txt
```

Commit directly to `main`.

**Notes on the YAML:**
- Paste this directly (Ctrl+V), don't retype it manually — retyping in the browser editor can introduce curly quotes that break YAML parsing
- Both email steps only run when their respective flag is `true` — no email on clean runs
- If you previously had a file named `main.yml` in this folder, delete it so only `expiry-check.yml` remains (Repo → `.github/workflows/main.yml` → trash icon → commit)

---

## Email Notification Setup (summary)

Two separate alerts exist, both built from the same pieces:

**1. Sender account & app password (Step 3)**
- A Gmail App Password, used only to *send* — doesn't need to be a recipient

**2. GitHub secrets (Step 5)**
| Secret name | Value |
|---|---|
| `SMTP_USERNAME` | the Gmail address sending the alert |
| `SMTP_PASSWORD` | the 16-character Gmail App Password |
| `NOTIFY_EMAIL_TO` | recipient address(es) — comma-separated for multiple |

**3. Trigger logic in `check-expiry.ps1` (Step 6, bottom of script)**
Two independent checks decide whether each alert fires:
- `NEEDS_ALERT` → true if anything is Red, Yellow, or Blue (standard alert)
- `NEEDS_CRITICAL_ALERT` → true if anything is Red or Yellow (critical alert, subset of the above)

**4. Two send steps in `expiry-check.yml` (Step 7)** — one per flag, each with its own subject line and summary file (`urgent_summary.txt` vs `critical_summary.txt`)

**If the email doesn't arrive:** check the recipient inbox's spam/junk folder first — first-time mail from an unfamiliar external sender (e.g. Gmail → corporate domain) is sometimes filtered. Marking it "not spam" typically fixes future deliveries.

---

## Step 8 — Test it

1. Go to the repo's **Actions** tab
2. Click **App Secret Expiry Check** in the left sidebar
3. Click **Run workflow** → **Run workflow** (green button)
4. Click into the running job to watch live logs
5. Expand **Run expiry check script** — confirm it ends with `Confluence page updated.` and either `Found X urgent item(s)` or `No urgent items`
6. If urgent or critical items were found, check the recipient inbox (and spam folder) for the corresponding alert email(s)
7. Check the Confluence page to confirm the DEV/QA / STG / PRD tables rendered with correct colored status lozenges

---

## Schedule

Once committed, the workflow runs automatically on GitHub's infrastructure — no manual action, and no local machine needed.

Current schedule: **every Monday at 6:00 AM UTC**.

To change the frequency, edit the `cron` line in `expiry-check.yml`:

| Frequency | Cron expression |
|---|---|
| Daily, 6am UTC | `0 6 * * *` |
| Every weekday, 6am UTC | `0 6 * * 1-5` |
| Twice a week (Mon & Thu) | `0 6 * * 1,4` |
| Monthly (1st of month) | `0 6 1 * *` |

---

## Managing repo access

To let someone else help maintain this repo:

1. Repo → **Settings** → **Collaborators and teams** → **Add people**
2. Enter their GitHub username or account email
3. Choose a role:
   - **Write** — can edit the script/workflow, sufficient for day-to-day maintenance
   - **Admin** — full control, same as the original owner (can manage secrets, collaborators, delete the repo)
4. They accept the emailed invitation to activate access

No collaborator, regardless of role, can view existing secret values — only overwrite or delete them.

---

## Important notes

- **This tool only reads and reports** — it never modifies, renews, or rotates the actual secrets in Entra ID. Renewing secrets is a manual step, done by DevOps (see the accompanying runbook for the full remediation process).
- **This runs entirely on GitHub's infrastructure.** Your local machine does not need to be on, and no Azure subscription or server of your own is required.
- **The monitoring app's own client secrets also expire** (per Step 1, set to 12–24 months) — keep a reminder to rotate those, since they're not covered by their own monitoring.
- Secrets stored in GitHub Actions are masked in logs and only injected as environment variables during a run — never written into the repo code.
- Use **Repository secrets**, not Environment secrets — this workflow has no `environment:` key, so Environment secrets wouldn't be reachable without adding unnecessary deployment-gate configuration.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `No event triggers defined in 'on'` | YAML formatting broke, usually curly quotes or lost indentation. Delete and re-paste the workflow file content directly. |
| `401` from Microsoft Graph | Check tenant/client ID/secret values; confirm admin consent was granted on `Application.Read.All` for that tenant. |
| `401`/`403` from Confluence | Check `CONFLUENCE_EMAIL` and `CONFLUENCE_API_TOKEN` match, and the account has edit access to the page. |
| Confluence update returns version conflict | Someone edited the page between fetch and push — just re-run. |
| Alert email not received | Check spam/junk folder first; mark as "not spam" for future delivery. |
