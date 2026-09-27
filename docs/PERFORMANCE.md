# Performance issues - Issue Tracker

Every problem in this system that makes it slower than it could be, what it
costs, **how much fixing it would gain**, how to fix it, and which tool does
the fixing.

**35 issues.** Measured on the code as it stands: `index.html` is **227 KB**
(146 KB of it inline JavaScript, 38 KB inline CSS), and the whole app is one
file.

**The numbers that explain most of the list**

| | |
|---|---|
| Issues fetched per load | **all of them** — `select *` with no limit |
| Full passes over the issue list per render | **about 8**, plus a sort |
| Requests per open tab | **4 per minute** — the 15 second poll, forever |

Priority: **P1** = fix first, **P2** = soon, **P3** = when it starts to hurt.

---

## How the impact figures were worked out

They are **modelled from the code, not benchmarked.** The reference case is:

| | |
|---|---|
| Issues on the board | **5,000** |
| User accounts | **50** |
| People using it at once | **20** |
| Typical row in JSON | ~300 bytes |
| Avatar as a data URL | ~9 KB |

Where a figure is a percentage it compares *work done* (iterations, bytes,
requests) before the fix against after. Where it is in milliseconds it is a
network or paint estimate, and the honest way to confirm it is to measure -
see the last section.

---

## The list

| # | Pri | Issue | Where | What it costs | Impact if fixed | How to resolve | Tool |
|---|---|---|---|---|---|---|---|
| 1 | **P1** | Every issue is fetched on every load, no limit | `listIssues()` — `select *`, no `.range()` | ~1.5 MB and a full parse, per load, per person | **−99% data** (1.5 MB → ~15 KB). Load stops growing with the board | Keyset pagination: order by `updated_at`, `limit(50)`, load more on scroll | **Supabase PostgREST** `.range()` |
| 2 | **P1** | Every write re-fetches the whole table | `mutate()` → `refresh()` | 2 round trips and 1.5 MB per action | **−50% round trips, −99.98% data** (1.5 MB → one row) | Update the changed row from the write's own response | **Supabase** `.update().select().single()` |
| 3 | **P1** | A poll every 15 s, forever, in every open tab | `startLiveUpdates()` — `setInterval` | 4 requests/min per user: **4,800 full reads an hour at 20 people** | **−75% to −100%** of background traffic (240 → 0–60 requests per hour per user) | Use Realtime and drop the poll; or back off to 60 s | **Supabase Realtime** |
| 4 | **P1** | Realtime events are not coalesced | `channel.on("postgres_changes", … refresh())` | A 500-row import = **500 full reads = ~750 MB** | **−99.8%** on a bulk change (500 reads → 1) | Coalesce events into one refresh on a short trailing timer | Plain JS timer |
| 5 | **P1** | `render()` makes ~8 full passes over the list, plus a sort | `render()` → `updateStats` (6) + `buildRepeatIndex` (1) + `visibleIssues` (1 + sort) | **~121,000 operations per render** at 5,000 issues, per keystroke | **−45% immediately**; **−95%** once the sort leaves the keystroke path | One reduce for the counts, one pass for the repeat index, reuse one filtered array | Plain JS (single reduce) |
| 6 | **P1** | `byId()` is a linear scan, called inside a loop | `updateBulkBar()` — `byId(id)` per selected id | Ticking 200 rows = **1,000,000 comparisons** | **−99.98%** on that path (1,000,000 → 200 lookups) | Build an `id → issue` map once per refresh | Plain JS `Map` |
| 7 | **P1** | Refreshes overlap | `refresh()` has no in-flight guard | Up to 3 full reads running at once | **−66% concurrent load**, and no triple payload | One at a time: keep the in-flight promise, drop duplicates | Plain JS `AbortController` |
| 8 | **P1** | Search, filter, sort all on the client | `visibleIssues()` | Only searches what was downloaded; O(n) scan per keystroke | No direct speed-up - it is **what makes #1's −99% possible** while keeping search | Move search into the query, with an index behind it | **PostgreSQL** `tsvector` + GIN |
| 9 | **P1** | No debounce on either search box | `el("search")`, `el("userSearch")` | Every keystroke runs the whole of #5 | **−80% render work while typing** (7 renders for a 7-letter word → 1) | Debounce 150–250 ms | Plain JS |
| 10 | **P1** | Per-user report count is O(users × issues) | `renderUsers()` — `issues.filter()` in the user map | **250,000 comparisons per render**, per keystroke | **−98%** (250,000 → 5,050) | Count once per user in a single pass, then look up | Plain JS (single pass) |
| 11 | **P1** | Supabase client is a render-blocking third-party script | `<script src="cdn.jsdelivr.net/…">` in `<head>`, no `defer` | The page cannot paint until a second DNS + TLS + download finishes | **−300 to −800 ms to first paint** (~400 ms typical on a phone) | Self-host or bundle it, and defer it | **Vite** / **esbuild** |
| 12 | **P2** | No `preconnect` to the API origin | `<head>` | First API call pays its own DNS + TLS | **−100 to −300 ms**, once per load | `<link rel="preconnect" href="https://<ref>.supabase.co" crossorigin>` | HTML, Vercel early hints |
| 13 | **P2** | The poll never pauses in a hidden tab | no `visibilitychange` handler | A background tab keeps making 4 requests a minute | **−100% of background traffic while hidden** | Pause hidden; refresh once on becoming visible | **Page Visibility API** |
| 14 | **P2** | `renderUsers()` is called from the poll too | `refresh()` → `if (view === "users") renderUsers()` | 250,000 comparisons **every 15 seconds**, forever | **−98% every 15 s** on the Users page | Fix #10, and skip the re-render when nothing changed | Plain JS |
| 15 | **P2** | A profiles SELECT on every app open | `_ensureProfile()` | An extra round trip before anything renders, per load, per person | **−100 to −300 ms to first render** | Trust the local session for first paint; refresh in the background | **Supabase Auth** (local session) |
| 16 | **P2** | Notifications rebuilt twice per refresh | `updateBell()` → `unreadCount()` → `buildNotifications()`, plus `renderNotifications()` | 40,000 rule checks per refresh, every 15 s, in every tab | **−50%** (two builds → one) | Build once per refresh and share it | Plain JS memo, or a `notifications` table |
| 17 | **P2** | The whole list is re-rendered from strings | `render()` assigns `innerHTML` | Every row rebuilt and re-laid-out, even when one changed | **−90%+ of DOM work per update** (one row out of 5,000) | Diff and update only changed rows; virtualise | Plain JS, or CSS `content-visibility` |
| 18 | **P2** | The entire table is held in memory | `issues` array | ~1.5 MB of data plus a large DOM on every device | **−90% memory** with a 50-row page (1.5 MB → ~15 KB) | Paginate, and release pages off screen | Plain JS |
| 19 | **P2** | Avatars are base64 blobs in the profile row | `saveAvatar()` → `profiles.avatar_url` | **~450 KB per user list** (9 KB × 50) | **−99% of the users payload** (450 KB → ~3 KB) | Upload the file, store only a URL | **Supabase Storage** |
| 20 | **P2** | Backups copy the whole table as one JSON value | `snapshot_issues()` — `jsonb_agg` | A ~1.5 MB write on the first change of every hour | **−99% on the backup write**, and the hourly spike goes | Snapshot only what changed, or use platform backups | **Supabase PITR**, `pg_dump` on **pg_cron** |
| 21 | **P2** | Restore deletes everything, then re-inserts | `restore_backup()` | The board is unavailable for the whole transaction | **Lock time from seconds to milliseconds** | Restore into a staging table and swap in one step | **PostgreSQL**, **Supabase PITR** |
| 22 | **P2** | The auto-backup trigger adds a query to every write | `auto_snapshot()` — an `EXISTS` on `backups` | One extra index scan per insert, update and delete | **−100% of that scan** (~0.2 ms × every write) | Keep `last_auto_snapshot_at` in `app_settings` and compare | **PostgreSQL** |
| 23 | **P3** | `replica identity full` on `issues` | schema | The whole previous row written to the WAL on every update | **−95% WAL per update** (~300 bytes → ~16) | Use `default` unless the old row is needed | **PostgreSQL** `ALTER TABLE` |
| 24 | **P3** | `select *` on profiles and issues | `listUsers()`, `_ensureProfile()`, `listIssues()` | Sends every column, including the avatar blob | Mostly #19's win; **−20 to −30%** on the rest | Name the columns each screen needs | PostgREST select list |
| 25 | **P3** | No server-side index for priority | schema | A sequential scan if priority is filtered in the database | **−99% rows scanned** for that filter (5,000 → ~50) | Add the index when filtering moves server-side | **PostgreSQL** `CREATE INDEX` |
| 26 | **P3** | The service worker is network-first for everything | `sw.js` `fetch` handler | Every asset waits on the network before the cache is considered | **−50 to −200 ms per asset**, a few hundred ms per load | Cache-first for static files, network-first for HTML | **Workbox** |
| 27 | **P3** | The worker clones and stores the 227 KB page every visit | `sw.js` — `response.clone()` + `cache.put` | A memory copy plus a disk write per navigation | **−100% of that write** (~10–30 ms per navigation) | Do not cache `index.html`; precache only static files | **Workbox** |
| 28 | **P3** | No build step: one 227 KB file | `index.html` | The HTML must revalidate, so the JS and CSS inside are **re-downloaded every load** | **−60% bytes on first load** (227 KB → ~50 KB minified+brotli), **−90% on repeat loads** once files are cached separately | Split CSS and JS into hashed files, minify | **Vite** or **esbuild** |
| 29 | **P3** | `backdrop-filter: blur(2px)` on the modal backdrop | `.backdrop` CSS | A full-screen GPU blur; low-end phones drop frames | Removes a **5–20 ms per frame** cost while a dialog is open | Remove the blur, or use a solid `rgba` | CSS |
| 30 | **P3** | No `content-visibility` or `contain` on rows | `.row` CSS | Lays out and paints every row, including off-screen ones | **−90%+ paint** on long lists (5,000 rows painted → the ~10 visible) | `content-visibility: auto` + `contain-intrinsic-size` | CSS |
| 31 | **P3** | `esc()` regexes every field of every row | every row, every render | ~40,000 regex passes per render (8 fields × 5,000) | **−100% of the escaping cost** - part of #5's win | Build rows from DOM nodes, or escape only what changed | Plain JS |
| 32 | **P3** | RLS calls `is_admin()` per row | policies on `issues` | Extra work per row on update and delete | **Low** - already `stable`, so the planner caches it. Only visible at scale | Put the role in the JWT and compare a claim | **PostgreSQL** (JWT claims) |
| 33 | **P3** | Demo mode re-parses the whole store per call | `demoBackend` `read()` / `write()` | A synchronous `JSON.parse` of the whole list per call | **−1 to −3 ms per call** at 5,000 rows. Demo only | Use IndexedDB if it matters | **IndexedDB** (`idb`) |
| 34 | **P3** | Nothing is measured | - | No query statistics, no API timings, so slow parts are invisible | **Indirect** - it is how the real figures replace the estimates here | Turn on query stats and watch the API logs | **pg_stat_statements**, Supabase logs |
| 35 | **P3** | Never load-tested | - | Behaviour above a few hundred rows is unknown | **Indirect** - it confirms or corrects every number in this table | Seed a few thousand rows, then measure | `EXPLAIN (ANALYZE, BUFFERS)`, **Lighthouse** |

---

## Where the gain is, in one table

Totals for the reference case: 20 people online, 5,000 issues, one working hour.

| Measure | Today | After the P1 fixes | Gain |
|---|---|---|---|
| Data moved per load | ~1.5 MB | ~15 KB | **−99%** |
| Full table reads per hour, 20 people | **4,800** | 0 | **−100%** |
| Round trips per write | 2 | 1 | **−50%** |
| Work per keystroke in the search box | ~121,000 ops | ~5,000 ops | **−96%** |
| Work per 15 s on the Users page | 250,000 comparisons | ~5,000 | **−98%** |
| A 500-row bulk change | 500 full reads, ~750 MB | 1 read, ~15 KB | **−99.98%** |
| First paint, phone | +300–800 ms blocked | not blocked | **−400 ms typical** |
| Repeat visit download | the whole app again | JS and CSS from cache | **−90%** |

---

## If you only do five things

| Order | Do this | Impact | Effort |
|---|---|---|---|
| 1 | **Debounce both search boxes** (#9) | −80% render work while typing | Minutes |
| 2 | **Single-pass counts** — the render loop (#5) and the users count (#10) | −96% and −98% on the two hot paths | An hour |
| 3 | **Coalesce Realtime events** (#4) | −99.98% on any bulk change | An hour |
| 4 | **Limit and paginate `listIssues`** (#1) | −99% data, load stops growing | A day |
| 5 | **Stop the full re-read after writes** (#2), **single-flight refresh** (#7) | −50% round trips, −66% concurrent load | A day |

Items 1, 2 and 3 are front-end only, need no database work, and deliver most
of the everyday feel.

---

## How to measure, so these stop being estimates

| What | Tool |
|---|---|
| Which query is slow | `pg_stat_statements`, and `EXPLAIN (ANALYZE, BUFFERS)` in the Supabase SQL editor |
| Which request is slow | Browser DevTools → Network, and Supabase → Logs → API |
| Which function is slow | Chrome DevTools → Performance (record, find the long task) |
| Overall page quality | **Lighthouse** in DevTools, run in mobile mode |
| Real users over time | **Vercel Analytics** / Speed Insights |
| Is the table the problem | `select pg_size_pretty(pg_total_relation_size('public.issues'))` |
| Is it paint, not data | DevTools → Rendering → Paint flashing, then open the modal and the list |

The cheapest honest check on this whole document: **seed 5,000 issues, open
DevTools → Performance, and type in the search box.** That single recording
either confirms the numbers above or corrects them.

---

## Worth knowing

**None of this is a bug.** For the size this system is built for - a team
board of a few hundred issues - every item is invisible. Each is the cost of a
choice that keeps the app simple: one file, no build step, no server, and
everything loaded at once.

**The three biggest single wins are #1 (−99% data), #11 (−400 ms to first
paint) and #5 (−96% per keystroke).** The first two are also the cheapest.

**The impact figures here are modelled, not measured.** They come from reading
the code and counting the work, which is enough to rank the list and choose
what to fix - but they are estimates, and the section above says how to turn
them into facts.

**Nothing here needs a rewrite.** Most are query and state changes; a handful
are local edits. Only #28 (a build step) changes how the app is delivered, and
that can wait.
