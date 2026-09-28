<#
=============================================================================
  apply-with-token.ps1 — puts the API into your database using an access token.
=============================================================================
  This is the route for when the Supabase CLI is not logged in. An access
  token is enough: it can run SQL through Supabase's own API, so no database
  password, no CLI and no browser is needed.

  HOW TO GET A TOKEN
      https://supabase.com/dashboard/account/tokens
      Generate new token, copy it.

  HOW TO RUN
      cd tests
      .\apply-with-token.ps1 -Token sbp_your_token

  It applies supabase-schema.sql, checks what landed, and creates one admin key
  and one user key, printing them once.
=============================================================================
#>

param(
  [Parameter(Mandatory = $true)][string]$Token,
  [switch]$NoKeys
)

$ErrorActionPreference = "Stop"
$root = Split-Path (Split-Path $PSCommandPath -Parent) -Parent

function Say($m, $c = "Gray") { Write-Host $m -ForegroundColor $c }
function Ok($m)   { Write-Host ("  PASS  " + $m) -ForegroundColor Green; $script:pass++ }
function Bad($m)  { Write-Host ("  FAIL  " + $m) -ForegroundColor Red;   $script:fail++ }
$script:pass = 0
$script:fail = 0

# ---- project, straight out of the app ---------------------------------------
$index = Get-Content (Join-Path $root "index.html") -Raw
$projectUrl = [regex]::Match($index, 'SUPABASE_URL\s*=\s*"([^"]+)"').Groups[1].Value
$ref = [regex]::Match($projectUrl, 'https://([^.]+)\.supabase\.co').Groups[1].Value
if (-not $ref) { Say "Could not work out the project ref from index.html." "Red"; exit 1 }

$schemaPath = Join-Path $root "supabase-schema.sql"
if (-not (Test-Path $schemaPath)) { Say "supabase-schema.sql is missing." "Red"; exit 1 }
$schema = Get-Content $schemaPath -Raw

$headers = @{ Authorization = "Bearer $Token"; "Content-Type" = "application/json" }

function Run-Sql([string]$sql) {
  $body = @{ query = $sql } | ConvertTo-Json -Compress -Depth 4
  return Invoke-RestMethod -Uri "https://api.supabase.com/v1/projects/$ref/database/query" `
    -Headers $headers -Method Post -Body $body -TimeoutSec 120
}

Say ""
Say "==============================================" "Cyan"
Say "  Applying the schema with an access token" "Cyan"
Say "==============================================" "Cyan"
Say "  project : $ref"
Say "  schema  : $([math]::Round($schema.Length / 1KB, 1)) KB"

# ---- is the token good? ------------------------------------------------------
Say ""
Say "Checking the token..." "Cyan"
try {
  $projects = Invoke-RestMethod -Uri "https://api.supabase.com/v1/projects" -Headers $headers -Method Get -TimeoutSec 60
} catch {
  Bad "the token was refused: $($_.Exception.Message)"
  Say ""
  Say "  Make sure it is an access token from" "Yellow"
  Say "    https://supabase.com/dashboard/account/tokens" "Yellow"
  Say "  and not the anon key or the service_role key." "Yellow"
  exit 1
}
$mine = $projects | Where-Object { $_.id -eq $ref }
if (-not $mine) {
  Bad "this token cannot see project $ref"
  Say "  It can see:" "Yellow"
  $projects | ForEach-Object { Say ("    - {0}  ({1})" -f $_.name, $_.id) "Yellow" }
  exit 1
}
Ok "the token works, and can see $($mine.name)"

# ---- what is there now -------------------------------------------------------
Say ""
Say "Before:" "Cyan"
try {
  $before = Run-Sql @"
select
  (select count(*) from information_schema.tables where table_schema='public' and table_name='issues')     as issues,
  (select count(*) from information_schema.tables where table_schema='public' and table_name='api_keys')   as api_keys,
  (select count(*) from pg_proc where proname='api_docs')                                                  as api_docs
"@
  $b = $before[0]
  Say ("  issues table  : " + $(if ($b.issues) { "yes" } else { "no" }))
  Say ("  api_keys      : " + $(if ($b.api_keys) { "yes" } else { "no" }))
  Say ("  api_docs()    : " + $(if ($b.api_docs) { "yes" } else { "no" }))
} catch {
  Bad "could not read the database: $($_.Exception.Message)"
  exit 1
}

# ---- apply -------------------------------------------------------------------
Say ""
Say "Applying the schema (safe to repeat)..." "Cyan"
try {
  Run-Sql $schema | Out-Null
  Ok "the schema applied without error"
} catch {
  $msg = $_.Exception.Message
  if ($_.ErrorDetails) { $msg = $_.ErrorDetails.Message }
  Bad "the database rejected it: $msg"
  exit 1
}

try { Run-Sql "notify pgrst, 'reload schema';" | Out-Null; Ok "told PostgREST to re-read the schema" }
catch { Say "  (could not send the reload - not fatal)" "Yellow" }

# ---- check -------------------------------------------------------------------
Say ""
Say "After:" "Cyan"
$after = Run-Sql @"
select
  (select count(*) from information_schema.tables where table_schema='public' and table_name='api_keys')            as api_keys,
  (select count(*) from information_schema.tables where table_schema='public' and table_name='webhooks')            as webhooks,
  (select count(*) from information_schema.tables where table_schema='public' and table_name='webhook_deliveries')  as deliveries,
  (select count(*) from pg_proc where proname='api_docs')                                                           as api_docs,
  (select count(*) from pg_proc where proname like 'api\_%')                                                        as endpoints,
  (select count(*) from public.issues)                                                                              as issues_kept
"@
$a = $after[0]
if ($a.api_keys)   { Ok "api_keys table" }   else { Bad "api_keys table" }
if ($a.webhooks)   { Ok "webhooks table" }   else { Bad "webhooks table" }
if ($a.deliveries) { Ok "webhook_deliveries table" } else { Bad "webhook_deliveries table" }
if ($a.api_docs)   { Ok "api_docs()" }       else { Bad "api_docs()" }
if ($a.endpoints -ge 10) { Ok "$($a.endpoints) API functions" } else { Bad "only $($a.endpoints) API functions" }
Say ""
Say "  issues still on the board : $($a.issues_kept)" "DarkGray"

# ---- keys --------------------------------------------------------------------
if (-not $NoKeys -and $script:fail -eq 0) {
  Say ""
  Say "Creating keys..." "Cyan"

  $live = Run-Sql "select count(*)::int as n from public.api_keys where revoked_at is null"
  if ($live[0].n -gt 0) {
    Say "  $($live[0].n) key(s) already exist - not making more." "Yellow"
  } else {
    $made = Run-Sql @"
with k as (
  select 'itk_' || encode(gen_random_bytes(24), 'hex') as key, 'admin - full control' as name, 'admin' as role
  union all
  select 'itk_' || encode(gen_random_bytes(24), 'hex'), 'shared with a friend', 'user'
), ins as (
  insert into public.api_keys (name, prefix, key_hash, role)
  select name, left(key, 12), encode(digest(key, 'sha256'), 'hex'), role from k
  returning 1
)
select key, name, role from k
"@
    $adminKey = ($made | Where-Object { $_.role -eq 'admin' }).key
    $userKey  = ($made | Where-Object { $_.role -eq 'user'  }).key
    $console = "https://issue-trackers-bay.vercel.app/api.html?key=$userKey"

    Say ""
    Say "==============================================" "Green"
    Say "  YOUR KEYS - copy them now" "Green"
    Say "==============================================" "Green"
    Say ""
    Say "  ADMIN  (change, delete, list accounts)" "White"
    Say "    $adminKey" "White"
    Say ""
    Say "  USER   (read, search, report)" "White"
    Say "    $userKey" "White"
    Say ""
    Say "  Only the hash is stored. They are not shown again." "DarkGray"
    Say ""
    Say "  Console, straight in:" "Cyan"
    Say "    $console" "Cyan"
    Say ""
    Say "  Test them:" "Cyan"
    Say "    .\api-smoke.ps1 -Key $userKey"
    Say "    .\api-smoke.ps1 -Key $adminKey -Write"
    Say ""
  }
}

Say ""
Say "==============================================" "Cyan"
if ($script:fail -eq 0) { Say "  Done. The API is in the database." "Green" }
else { Say "  $($script:fail) check(s) failed - see above." "Red" }
Say "==============================================" "Cyan"
Say ""
