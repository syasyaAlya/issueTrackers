<#
=============================================================================
  api-smoke.ps1 — tests the REST API on your real project.
=============================================================================
  Calls every endpoint with a key you give it and reports what happened.

  HOW TO RUN
      cd tests
      .\api-smoke.ps1 -Key itk_your_key_here

  Add -Write to also test creating, updating and deleting an issue. Without it
  the script only reads, so it cannot change anything on your board.

  It takes the project URL and the anon key straight out of ../index.html, so
  there is nothing else to configure.
=============================================================================
#>

param(
  [Parameter(Mandatory = $true)][string]$Key,
  [switch]$Write
)

$ErrorActionPreference = "Continue"
$root = Split-Path (Split-Path $PSCommandPath -Parent) -Parent

function Say($m, $c = "Gray") { Write-Host $m -ForegroundColor $c }

# ---- the two values, read from the app so they cannot drift -----------------
$indexPath = Join-Path $root "index.html"
if (-not (Test-Path $indexPath)) { Say "Run this from the tests folder inside the repo." "Red"; exit 1 }
$index = Get-Content $indexPath -Raw

$url = [regex]::Match($index, 'SUPABASE_URL\s*=\s*"([^"]+)"').Groups[1].Value
$anon = [regex]::Match($index, 'SUPABASE_ANON_KEY\s*=\s*"([^"]+)"').Groups[1].Value
if (-not $url -or -not $anon) { Say "Could not read the project URL and anon key from index.html." "Red"; exit 1 }

$headers = @{
  apikey         = $anon
  Authorization  = "Bearer $anon"
  "Content-Type" = "application/json"
}

$script:pass = 0
$script:fail = 0

function Check($name, $ok, $extra) {
  if ($ok) { $script:pass++; Say ("  PASS  " + $name) "Green" }
  else     { $script:fail++; Say ("  FAIL  " + $name + $(if ($extra) { "   -> $extra" } else { "" })) "Red" }
}
function Section($t) { Say ""; Say $t "Cyan" }

function Call-Api($endpoint, $params) {
  $body = @{ p_key = $Key }
  if ($params) { $params.GetEnumerator() | ForEach-Object { $body[$_.Key] = $_.Value } }
  $json = $body | ConvertTo-Json -Compress

  try {
    $r = Invoke-WebRequest -Uri "$url/rest/v1/rpc/$endpoint" -Method Post `
         -Headers $headers -Body $json -UseBasicParsing -TimeoutSec 30
    $parsed = $null
    try { $parsed = $r.Content | ConvertFrom-Json } catch {}
    return @{ status = [int]$r.StatusCode; ok = $true; body = $parsed; text = $r.Content }
  } catch {
    $code = 0
    try { $code = [int]$_.Exception.Response.StatusCode } catch {}
    $text = ""
    try {
      $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
      $text = $sr.ReadToEnd()
    } catch {}
    $parsed = $null
    try { $parsed = $text | ConvertFrom-Json } catch {}
    return @{ status = $code; ok = $false; body = $parsed; text = $text }
  }
}

function MessageOf($r) {
  if ($r.body -and $r.body.message) { return $r.body.message }
  if ($r.text) { return $r.text.Substring(0, [Math]::Min(140, $r.text.Length)) }
  return "no response"
}

Say ""
Say "==============================================" "Cyan"
Say "  Testing the Issue Tracker API" "Cyan"
Say "==============================================" "Cyan"
Say "  project : $url"
Say "  key     : $($Key.Substring(0, [Math]::Min(12, $Key.Length)))..."
Say "  writing : $(if ($Write) { 'yes - this will create and delete a test issue' } else { 'no - reads only' })"

# ---- does the API exist at all? --------------------------------------------
Section "1. Is the API there?"
$docs = Call-Api "api_docs" $null
if (-not $docs.ok) {
  Check "api_docs answers" $false (MessageOf $docs)
  Say ""
  Say "  The API is not in your database yet." "Yellow"
  Say "  Open the app, Settings > Database setup > Show the setup SQL," "Yellow"
  Say "  copy it into the Supabase SQL editor and press Run." "Yellow"
  Say ""
  exit 1
}
Check "api_docs answers" $true
Check "it lists the endpoints" ($docs.body.endpoints.Count -ge 9) "$($docs.body.endpoints.Count) endpoint(s)"

# ---- the key -----------------------------------------------------------------
Section "2. The key"
$me = Call-Api "api_me" $null
if (-not $me.ok) {
  Check "the key is accepted" $false (MessageOf $me)
  Say ""
  Say "  It was refused. Either it was typed wrongly, or it has been revoked." "Yellow"
  Say "  Make a new one in Settings > API keys." "Yellow"
  exit 1
}
$role = $me.body.key.role
Check "the key is accepted" $true
Check "it has a name" ($me.body.key.name -ne $null) $me.body.key.name
Say ("        key role: {0}  ({1} calls so far)" -f $role, $me.body.key.requests) "DarkGray"

# ---- reading -----------------------------------------------------------------
Section "3. Reading"
$list = Call-Api "api_list_issues" @{ p_limit = 5 }
Check "listing issues works" $list.ok (MessageOf $list)
if ($list.ok) {
  Check "the response has count / limit / offset / data" `
    ($null -ne $list.body.count -and $null -ne $list.body.limit -and $null -ne $list.body.data) `
    (($list.body | ConvertTo-Json -Compress).Substring(0, [Math]::Min(120, ($list.body | ConvertTo-Json -Compress).Length)))
  Say ("        {0} issue(s) on the board, showing {1}" -f $list.body.count, $list.body.data.Count) "DarkGray"
}

$filtered = Call-Api "api_list_issues" @{ p_status = "pending"; p_limit = 3 }
Check "filtering by status works" $filtered.ok (MessageOf $filtered)

$searched = Call-Api "api_list_issues" @{ p_q = "the"; p_limit = 3 }
Check "searching works" $searched.ok (MessageOf $searched)

$stats = Call-Api "api_stats" $null
Check "statistics work" $stats.ok (MessageOf $stats)
if ($stats.ok) { Say ("        total {0}: none {1}, pending {2}, done {3}" -f `
  $stats.body.data.total, $stats.body.data.none, $stats.body.data.pending, $stats.body.data.done) "DarkGray" }

$one = $null
if ($list.ok -and $list.body.data.Count -gt 0) {
  $one = Call-Api "api_get_issue" @{ p_id = $list.body.data[0].id }
  Check "fetching one issue by id works" $one.ok (MessageOf $one)
} else {
  Say "  SKIP  fetching one issue (the board is empty)" "DarkGray"
}

# ---- the tier ----------------------------------------------------------------
Section "4. What this key is allowed to do"
$refusedStatus = Call-Api "api_update_issue" @{ p_id = "00000000-0000-0000-0000-000000000000"; p_status = "done" }
$refusedUsers  = Call-Api "api_list_users" $null

if ($role -eq "admin") {
  Check "an admin key can reach api_list_users" $refusedUsers.ok (MessageOf $refusedUsers)
  Check "an admin key is not refused by api_update_issue" `
    ($refusedStatus.ok -or ($refusedStatus.body.message -notmatch "admin key")) (MessageOf $refusedStatus)
} else {
  Check "a user key is refused api_update_issue" `
    (-not $refusedStatus.ok -and $refusedStatus.body.message -match "admin key") (MessageOf $refusedStatus)
  Check "a user key is refused api_list_users" `
    (-not $refusedUsers.ok -and $refusedUsers.body.message -match "admin key") (MessageOf $refusedUsers)
}

# ---- a bad key ---------------------------------------------------------------
Section "5. A made-up key is refused"
$bad = Call-Api "api_me" @{ p_key = "itk_not_a_real_key_at_all" }
Check "a wrong key is refused" (-not $bad.ok -and $bad.body.message -match "Invalid or revoked") (MessageOf $bad)

# ---- writing (opt in) ---------------------------------------------------------
if ($Write) {
  Section "6. Writing (you asked for this with -Write)"

  $made = Call-Api "api_create_issue" @{
    p_title = "Test issue from api-smoke"; p_description = "Created by tests/api-smoke.ps1"; p_priority = "low"
  }
  Check "an issue can be reported" $made.ok (MessageOf $made)

  if ($made.ok) {
    $newId = $made.body.data.id
    Check "it starts with no status" ($made.body.data.status -eq "none") $made.body.data.status
    Check "it is marked as coming from the API" ($made.body.data.created_by_email -match "^api:") $made.body.data.created_by_email

    if ($role -eq "admin") {
      $upd = Call-Api "api_update_issue" @{ p_id = $newId; p_status = "done"; p_note = "checked by api-smoke" }
      Check "an admin key can change it" ($upd.ok -and $upd.body.data.status -eq "done") (MessageOf $upd)

      $del = Call-Api "api_delete_issue" @{ p_id = $newId }
      Check "an admin key can delete it again" $del.ok (MessageOf $del)
    } else {
      Say "  SKIP  updating and deleting (a user key cannot)" "DarkGray"
      Say "        the test issue it created is still on your board" "Yellow"
    }
  }
} else {
  Section "6. Writing"
  Say "  SKIPPED - run with -Write to test creating, updating and deleting." "DarkGray"
}

# ---- result -------------------------------------------------------------------
Say ""
Say "==============================================" "Cyan"
if ($script:fail -eq 0) {
  Say "  All good: $($script:pass) checks passed." "Green"
  Say "  The API is working with this key." "Green"
} else {
  Say "  $($script:pass) passed, $($script:fail) failed." "Red"
  Say "  Read the FAIL lines above; each one says what came back." "Yellow"
}
Say "==============================================" "Cyan"
Say ""
