<#
=============================================================================
  check-all.ps1 — is the whole thing working?
=============================================================================
  Checks the database, the API, the app and the installable bits, and prints a
  PASS or FAIL for each. No arguments: it mints two temporary keys, tests with
  them, and revokes them again.

  HOW TO RUN
      cd tests
      .\check-all.ps1

  Needs the Supabase CLI logged in (supabase projects list should work).
=============================================================================
#>

$ErrorActionPreference = "Continue"
$root = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
$ref = "oswrhpvkhlhinsatwh"

$script:pass = 0
$script:fail = 0
$script:warn = 0

function Ok($m)   { Write-Host ("  PASS  " + $m) -ForegroundColor Green;  $script:pass++ }
function Bad($m)  { Write-Host ("  FAIL  " + $m) -ForegroundColor Red;    $script:fail++ }
function Warn($m) { Write-Host ("  WARN  " + $m) -ForegroundColor Yellow; $script:warn++ }
function Head($m) { Write-Host ""; Write-Host $m -ForegroundColor Cyan }

# ---- project values, from the app -------------------------------------------
$index = Get-Content (Join-Path $root "index.html") -Raw
$appUrl = [regex]::Match($index, 'SUPABASE_URL\s*=\s*"([^"]+)"').Groups[1].Value
$refFromApp = [regex]::Match($appUrl, 'https://([^.]+)\.supabase\.co').Groups[1].Value
if ($refFromApp) { $ref = $refFromApp }
$anon = [regex]::Match($index, 'SUPABASE_ANON_KEY\s*=\s*"([^"]+)"').Groups[1].Value
$site = "https://issue-trackers-bay.vercel.app"

$headers = @{ apikey = $anon; Authorization = "Bearer $anon"; "Content-Type" = "application/json" }

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  Checking the whole system" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  project : $ref"
Write-Host "  site    : $site"

# ---- 1. the CLI is reachable ------------------------------------------------
Head "1. Can we reach the database?"
$canCli = $true
try {
  $probe = & cmd /c "supabase projects list 2>&1"
  if (($probe -join ' ') -notmatch 'oswrhpvkhlpvhinsatwh') { $canCli = $false }
} catch { $canCli = $false }
if ($canCli) { Ok "the Supabase CLI is logged in" }
else {
  Bad "the Supabase CLI is not logged in (run supabase-login.ps1 on the Desktop)"
  Write-Host ""
  Write-Host "  Without it, only the API checks can run." -ForegroundColor Yellow
}

function Sql([string]$q) {
  $tmp = Join-Path $env:TEMP "check-all.sql"
  Set-Content -Path $tmp -Value $q -Encoding UTF8
  $out = & cmd /c "supabase db query --linked --project-ref $ref --file `"$tmp`" 2>&1"
  $txt = ($out -join "`n")
  $m = [regex]::Match($txt, '(?s)\{.*\}')
  if (-not $m.Success) { throw "no JSON back: $txt" }
  return ($m.Value | ConvertFrom-Json).rows
}

if ($canCli) {
  # ---- 2. the schema --------------------------------------------------------
  Head "2. The database schema"
  try {
    $r = (Sql @"
select
  (select count(*)::int from information_schema.tables where table_schema='public')                                                    as tables,
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in
     ('api_docs','api_me','api_list_issues','api_get_issue','api_create_issue','api_stats','api_update_issue','api_delete_issue','api_list_users',
      'api_role','api_check','create_api_key','revoke_api_key'))                                                                       as functions,
  (select count(*)::int from pg_trigger where not tgisinternal and tgname in
     ('issues_guard_update','issues_touch_updated_at','issues_auto_backup','issues_webhook','profiles_guard_role'))                     as triggers,
  (select count(*)::int from pg_class where relname in ('issues','profiles','api_keys') and relrowsecurity)                              as rls_on,
  (select count(*)::int from public.issues)                                                                                            as issues,
  (select auto_backup_enabled::int from public.app_settings limit 1)                                                                   as autobackup,
  (select count(*)::int from public.backups)                                                                                           as backups
"@)[0]

    if ($r.tables -ge 7) { Ok "$($r.tables) tables" } else { Bad "only $($r.tables) tables (expected 7)" }
    if ($r.functions -ge 13) { Ok "$($r.functions) API functions" } else { Bad "only $($r.functions) API functions (expected 13)" }
    if ($r.triggers -ge 5) { Ok "$($r.triggers) triggers" } else { Bad "only $($r.triggers) triggers (expected 5)" }
    if ($r.rls_on -ge 3) { Ok "row level security is on where it matters" } else { Bad "row level security is off somewhere" }
    Write-Host "        the board holds $($r.issues) issue(s)" -ForegroundColor DarkGray
    if ($r.autobackup -eq 1) { Ok "automatic backups are switched on" } else { Warn "automatic backups are switched off" }
    if ($r.backups -gt 0) { Ok "$($r.backups) snapshot(s) stored" } else { Warn "no snapshots yet (one is taken on the next change)" }
  } catch {
    Bad "could not read the schema: $($_.Exception.Message)"
  }

  # ---- 3. temporary keys, so the API can be tested properly ------------------
  Head "3. Making two temporary keys to test the API with"
  $userKey = $null; $adminKey = $null
  try {
    $made = Sql @"
with k as (
  select 'itk_' || encode(gen_random_bytes(24),'hex') as key, 'check-all user' as name, 'user' as role
  union all
  select 'itk_' || encode(gen_random_bytes(24),'hex'), 'check-all admin', 'admin'
), ins as (
  insert into public.api_keys (name, prefix, key_hash, role)
  select name, left(key,12), encode(digest(key,'sha256'),'hex'), role from k
  returning 1
)
select key, role from k
"@
    $userKey  = ($made | Where-Object { $_.role -eq 'user'  }).key
    $adminKey = ($made | Where-Object { $_.role -eq 'admin' }).key
    if ($userKey -and $adminKey) { Ok "two temporary keys created" } else { Bad "keys were not returned" }
  } catch { Bad "could not create test keys: $($_.Exception.Message)" }
}

# ---- 4. the API over HTTPS --------------------------------------------------
Head "4. The API over HTTPS"
function Api($endpoint, $body, $keyParam = 'p_key', $keyValue) {
  $b = @{}
  if ($keyValue) { $b[$keyParam] = $keyValue }
  if ($body) { $body.GetEnumerator() | ForEach-Object { $b[$_.Key] = $_.Value } }
  $json = $b | ConvertTo-Json -Compress
  try {
    $res = Invoke-WebRequest -Uri "$appUrl/rest/v1/rpc/$endpoint" -Method Post -Headers $headers -Body $json -UseBasicParsing -TimeoutSec 30
    return @{ ok = $true; body = ($res.Content | ConvertFrom-Json) }
  } catch {
    $t = ""
    try { $t = (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch {}
    if (-not $t -and $_.ErrorDetails) { $t = $_.ErrorDetails.Message }
    $p = $null; try { $p = $t | ConvertFrom-Json } catch {}
    return @{ ok = $false; body = $p; text = $t }
  }
}

$d = Api "api_docs" @{} $null $null
if ($d.ok) { Ok "api_docs answers ($($d.body.endpoints.Count) endpoints listed)" } else { Bad "api_docs: $($d.text)" }

if ($userKey) {
  $me = Api "api_me" @{} "p_key" $userKey
  if ($me.ok -and $me.body.key.role -eq 'user') { Ok "a user key is accepted" } else { Bad "user key refused" }

  $li = Api "api_list_issues" @{ p_limit = 3 } "p_key" $userKey
  if ($li.ok) { Ok "listing issues works ($($li.body.count) on the board)" } else { Bad "listing issues failed" }

  $st = Api "api_stats" @{} "p_key" $userKey
  if ($st.ok) { Ok "statistics work" } else { Bad "statistics failed" }

  $no = Api "api_update_issue" @{ p_id = "00000000-0000-0000-0000-000000000000" } "p_key" $userKey
  if (-not $no.ok -and $no.body.message -match 'admin key') { Ok "a user key is refused admin work" }
  else { Bad "a user key was NOT refused admin work" }
}

if ($adminKey) {
  $me = Api "api_me" @{} "p_key" $adminKey
  if ($me.ok -and $me.body.key.role -eq 'admin') { Ok "an admin key is accepted" } else { Bad "admin key refused" }

  $lu = Api "api_list_users" @{} "p_key" $adminKey
  if ($lu.ok) { Ok "an admin key can list accounts ($($lu.body.data.Count))" } else { Bad "listing accounts failed" }

  # a real round trip: create, change, delete
  $made = Api "api_create_issue" @{ p_title = "check-all probe"; p_priority = "low" } "p_key" $adminKey
  if ($made.ok) {
    Ok "an issue can be reported"
    $id = $made.body.data.id
    $upd = Api "api_update_issue" @{ p_id = $id; p_status = "done" } "p_key" $adminKey
    if ($upd.ok -and $upd.body.data.status -eq 'done') { Ok "it can be changed" } else { Bad "changing an issue failed" }
    $del = Api "api_delete_issue" @{ p_id = $id } "p_key" $adminKey
    if ($del.ok) { Ok "it can be deleted again" } else { Bad "deleting failed" }
  } else { Bad "reporting an issue failed: $($made.text)" }

  $bad = Api "api_me" @{} "p_key" "itk_not_a_real_key"
  if (-not $bad.ok -and $bad.body.message -match 'Invalid or revoked') { Ok "a made-up key is refused" }
  else { Bad "a made-up key was NOT refused" }
}

# ---- 5. the app and its files ----------------------------------------------
Head "5. The app and its files"
foreach ($u in @("" , "api", "api-status", "manifest.webmanifest", "sw.js", "icon-192.png", "icon-512.png")) {
  $target = if ($u -eq "") { "$site/" } else { "$site/$u" }
  try {
    $res = Invoke-WebRequest $target -UseBasicParsing -TimeoutSec 25
    if ($res.StatusCode -eq 200) { Ok "$(if ($u -eq '') { 'the app' } else { $u }) is live" } else { Bad "$u returned $($res.StatusCode)" }
  } catch { Bad "$u is not reachable" }
}

# ---- 6. the installable bits ------------------------------------------------
Head "6. Installable on a phone"
try {
  # PowerShell hands this back as bytes, so decode it properly before parsing
  $manRes = Invoke-WebRequest "$site/manifest.webmanifest" -UseBasicParsing -TimeoutSec 20
  $man = [System.Text.Encoding]::UTF8.GetString($manRes.RawContentStream.ToArray())
  $mj = $man | ConvertFrom-Json
  if ($mj.display -eq 'standalone') { Ok "the manifest says standalone" } else { Bad "manifest display is '$($mj.display)'" }
  $sizes = $mj.icons | ForEach-Object { $_.sizes }
  if ($sizes -contains '192x192' -and $sizes -contains '512x512') { Ok "192 and 512 icons declared" } else { Bad "an icon size is missing" }
  $maskable = @($mj.icons | Where-Object { "$($_.purpose)" -match 'maskable' })
  if ($maskable.Count -gt 0) { Ok "a maskable icon is declared" } else { Warn "no maskable icon" }
  if ($mj.start_url) { Ok "it has a start url" } else { Bad "no start_url in the manifest" }
} catch { Bad "could not read the manifest: $($_.Exception.Message)" }

$sw = (Invoke-WebRequest "$site/sw.js" -UseBasicParsing -TimeoutSec 20).Content
if ($sw -match 'addEventListener\("fetch"') { Ok "the service worker handles fetches" } else { Bad "the service worker does not" }
if ($sw -match 'addEventListener\("push"') { Ok "and it can receive a push" } else { Warn "no push handler" }

# ---- 7. clean up ------------------------------------------------------------
if ($userKey -or $adminKey) {
  Head "7. Tidying up"
  try {
    Sql "update public.api_keys set revoked_at = now() where name in ('check-all user','check-all admin') and revoked_at is null"
    Ok "the two temporary keys were revoked"
  } catch { Warn "could not revoke the temporary keys" }
}

# ---- result -----------------------------------------------------------------
Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
if ($script:fail -eq 0) {
  Write-Host ("  ALL GOOD - {0} checks passed" -f $script:pass) -ForegroundColor Green
  if ($script:warn) { Write-Host ("  ({0} warning(s), see above)" -f $script:warn) -ForegroundColor Yellow }
  Write-Host "  The database, the API, the app and the installable bits are all working." -ForegroundColor Green
} else {
  Write-Host ("  {0} passed, {1} FAILED" -f $script:pass, $script:fail) -ForegroundColor Red
  Write-Host "  Read the FAIL lines above; each says what came back." -ForegroundColor Yellow
}
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""
