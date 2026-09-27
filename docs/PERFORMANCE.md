# Performance issues - Issue Tracker

Every problem in this system that makes it slower than it could be, what it
costs, how to fix it, and which tool does the fixing.

**35 issues.** Measured on the code as it stands: `index.html` is **227 KB**
(146 KB of it inline JavaScript, 38 KB inline CSS), and the whole app is one
file.

**The three numbers that explain most of the list**

| | |
|---|---|
| Issues fetched per load | **all of them** — `select *` with no limit |
| Full passes over the issue list per render | **about 8**, plus a sort |
| Requests per open tab | **4 per minute** — the 15 second poll, forever |

Priority: **P1** = fix first, **P2** = soon, **P3** = when it starts to hurt.

---

## The list

| # | Pri | Issue | Where | What it costs | How to resolve | System / tool |
|---|---|---|---|---|---|---|
| 1 | **P1** | Every issue is fetched on every load, with no limit | `listIssues()` — `select *`, no `.range()` | Payload and parse time grow with the table. 10,000 issues is several MB on every load, on a phone | Keyset pagination: order by `updated_at`, `limit(50)`, load more on scroll. Count separately | **Supabase PostgREST** `.range()` + `count: 'exact'` |
| 2 | **P1** | Every write re-fetches the whole table | `mutate()` → `refresh()` | One status change = 1 write + 1 full table read. Bulk edits multiply it | Update the changed row from the write's own response; reconcile in the background | **Supabase** `.update().select().single()`, **Realtime** |
| 3 | **P1** | A poll every 15 seconds, forever, in every open tab | `startLiveUpdates()` — `setInterval(…, 15000)` | 4 requests per minute per user, each returning every issue. 20 people = 4,800 full reads an hour | Use Realtime and drop the poll; otherwise back off to 60 s | **Supabase Realtime** |
| 4 | **P1** | Realtime events are not coalesced | `channel.on("postgres_changes", … function () { refresh(); })` | **Every** event triggers a full table read. A bulk import of 500 rows = 500 full reads | Coalesce events into one refresh on a short trailing timer | Plain JS timer |
| 5 | **P1** | `render()` makes about eight full passes over the list, plus a sort | `render()` → `updateStats()` (6 passes) + `buildRepeatIndex()` + `visibleIssues()` (filters + sort) + `baseIssues()` again | At 5,000 issues: roughly **40,000 iterations and a 5,000-element sort per keystroke**. It also runs on every poll and every write | Compute once per refresh: one reduce for the counts, one pass for the repeat index, one filtered+sorted array reused | Plain JS (single reduce), or memoise per refresh |
| 6 | **P1** | `byId()` is a linear scan, and it is called inside loops | `updateBulkBar()` — `byId(id)` per selected id; also every row click | O(selected × issues). Tick 200 rows on a 5,000-row board = 1,000,000 comparisons | Build an `id → issue` map once per refresh and look up | Plain JS `Map` |
| 7 | **P1** | Refreshes overlap | `refresh()` has no in-flight guard | A poll, a Realtime event and a write can run three full reads at once | One request at a time: keep the in-flight promise, drop or queue duplicates | Plain JS `AbortController` |
| 8 | **P1** | Search, filter and sort all run on the client | `visibleIssues()` | Only searches what was downloaded, and does it on the main thread | Move search and filtering into the query, with an index behind it | **PostgreSQL** `tsvector` + GIN, or `pg_trgm` |
| 9 | **P1** | No debounce on either search box | `el("search")`, `el("userSearch")` `input` handlers | Re-runs everything above on **every keystroke** | Debounce 150–250 ms | Plain JS |
| 10 | **P1** | Per-user report count is O(users × issues) | `renderUsers()` — `issues.filter()` inside the user map | 50 users × 5,000 issues = **250,000 comparisons per render**, and it re-renders per keystroke | Count once per user in a single pass, then look up | Plain JS (single pass), or a PostgREST aggregate view |
| 11 | **P1** | The Supabase client is a render-blocking third-party script | `<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2">` in `<head>`, no `defer` | The page cannot paint until a second DNS lookup, TLS handshake and download to jsDelivr finishes. Often 300–800 ms on a phone | Self-host or bundle it, and defer it | **Vite** / **esbuild**, or serve it from Vercel |
| 12 | **P2** | No `preconnect` to the API origin | `<head>` | The first API call pays its own DNS + TLS handshake | Add `<link rel="preconnect" href="https://<ref>.supabase.co" crossorigin>` | HTML, Vercel early hints |
| 13 | **P2** | The poll never pauses in a hidden tab | no `visibilitychange` handler | A background tab keeps making 4 requests a minute forever. Battery and mobile data | Pause while hidden; refresh once when it becomes visible | **Page Visibility API** |
| 14 | **P2** | `renderUsers()` is called from the poll too | `refresh()` → `if (view === "users") renderUsers()` | On the Users page the O(users × issues) count runs every 15 seconds, forever | Fix #10, and skip the re-render when nothing changed | Plain JS |
| 15 | **P2** | A profiles SELECT on every app open | `_ensureProfile()` — `profiles.select("*").maybeSingle()` | An extra round trip before anything renders, on every load, for every user | Trust the local session for the first paint; refresh the profile in the background | **Supabase Auth** (local session) + a cached profile |
| 16 | **P2** | Notifications are rebuilt twice on every refresh | `updateBell()` → `unreadCount()` → `buildNotifications()`, plus `renderNotifications()` | 2 × (4 × n) per refresh, every 15 s, in every tab | Build once per refresh and share the result | Plain JS memo, or a `notifications` table |
| 17 | **P2** | The whole list is re-rendered from strings | `render()` assigns `innerHTML` | Rebuilds every row, drops DOM state, forces layout on long lists | Diff and update only changed rows; virtualise | Plain JS, or CSS `content-visibility` |
| 18 | **P2** | The entire table is held in memory | `issues` array | Memory pressure and GC pauses on low-end phones | Paginate, and release pages that are off screen | Plain JS |
| 19 | **P2** | Avatars are base64 blobs inside the profile row | `saveAvatar()` → `canvas.toDataURL()` → `profiles.avatar_url` | ~8–10 KB per user, on **every** user list and profile read, re-parsed every render | Upload the file, store only a URL | **Supabase Storage** |
| 20 | **P2** | Backups copy the entire table as one JSON value | `snapshot_issues()` — `jsonb_agg(to_jsonb(i))` | On the first change of every hour the whole table is serialised and written | Snapshot only what changed, or use the platform's backups | **Supabase PITR**, or `pg_dump` on **pg_cron** |
| 21 | **P2** | Restore deletes everything, then re-inserts | `restore_backup()` | One long transaction, the table locked, a full rewrite | Restore into a staging table and swap; or use point-in-time recovery | **PostgreSQL**, **Supabase PITR** |
| 22 | **P2** | The auto-backup trigger adds a query to **every** write | `auto_snapshot()` — an `EXISTS` on `backups` per change | One extra index scan on every insert, update and delete, just to answer "is a backup due?" | Keep `last_auto_snapshot_at` in `app_settings` (one row, already read) and compare in the trigger | **PostgreSQL** |
| 23 | **P3** | `replica identity full` on `issues` | schema | Every UPDATE writes the whole previous row to the write-ahead log | Use `default` unless something needs the old row in the event | **PostgreSQL** `ALTER TABLE` |
| 24 | **P3** | `select *` on profiles and issues | `listUsers()`, `_ensureProfile()`, `listIssues()` | Sends columns nobody asked for, including the avatar blob | Name the columns each screen needs | PostgREST select list |
| 25 | **P3** | No server-side index for priority | schema | If filtering moves to the database, `priority` has no index | Indexes exist on `status`, `created_by`, `updated_at`; add `priority` when it is filtered server-side | **PostgreSQL** `CREATE INDEX` |
| 26 | **P3** | The service worker is network-first for everything | `sw.js` `fetch` handler | Every asset waits on the network; the cache is never used first | Cache-first for static files, network-first for HTML only | **Workbox** |
| 27 | **P3** | The worker clones and stores the 227 KB page on every visit | `sw.js` — `response.clone()` then `cache.put` | A memory copy plus a disk write per navigation, for a file that must revalidate anyway | Do not cache `index.html`; precache only the static files | **Workbox** |
| 28 | **P3** | No build step: one 227 KB file | `index.html` | The HTML must revalidate every load, so the JavaScript and CSS inside are **re-downloaded every time**. Nothing is minified | Split CSS and JS into separate hashed files, minify, let the browser cache them | **Vite** or **esbuild** |
| 29 | **P3** | `backdrop-filter: blur(2px)` on the modal backdrop | `.backdrop` CSS | A full-screen GPU blur; low-end phones drop frames when a dialog opens | Remove the blur, or use a solid `rgba` | CSS |
| 30 | **P3** | No `content-visibility` or `contain` on list rows | `.row` CSS | The browser lays out and paints every row, including off-screen ones | `content-visibility: auto` plus `contain-intrinsic-size` | CSS |
| 31 | **P3** | `esc()` runs a regex replace with a callback on every field | every row, every render | Tens of thousands of regex passes per render on a large board | Build rows from DOM nodes, or only escape what changed | Plain JS |
| 32 | **P3** | RLS calls `is_admin()` per row | policies on `issues` | Extra work per row on update and delete | Already `stable`, which lets the planner cache it; at scale put the role in the JWT and compare a claim | **PostgreSQL** (custom JWT claims) |
| 33 | **P3** | Demo mode re-parses the whole store on every call | `demoBackend` `read()` / `write()` | `JSON.parse` of the entire list on every call, synchronously, blocking the interface | Demo only; use IndexedDB if it matters | **IndexedDB** (`idb`) |
| 34 | **P3** | Nothing is measured | - | No query statistics, no API timings, so slow parts are invisible | Turn on query stats and watch the API logs | **pg_stat_statements**, Supabase logs, Vercel Analytics |
| 35 | **P3** | Never load-tested | - | Behaviour above a few hundred rows is unknown | Seed a few thousand rows, then measure | `EXPLAIN (ANALYZE, BUFFERS)`, **Lighthouse**, Chrome Performance |

---

## If you only do five things

| Order | Do this | Why first |
|---|---|---|
| 1 | **Debounce both search boxes** (#9) | Fewest lines, immediate feel on a phone |
| 2 | **Single-pass counts** — the render loop (#5) and the user counts (#10) | Removes ~40,000 iterations and a 250,000-comparison loop that run per keystroke |
| 3 | **Coalesce Realtime events** (#4) | Stops a bulk change turning into hundreds of full table reads |
| 4 | **Limit and paginate `listIssues`** (#1) | The one that decides whether it still works at 10,000 issues |
| 5 | **Stop the full re-read after every write** (#2) and **coalesce the refresh** (#7) | Halves the work of every action, and stops duplicates |

Items 1, 2 and 3 are front-end only and need no database work at all.

---

## How to measure, so this stops being guesswork

| What | Tool |
|---|---|
| Which query is slow | `pg_stat_statements`, and `EXPLAIN (ANALYZE, BUFFERS)` in the Supabase SQL editor |
| Which request is slow | Browser DevTools → Network, and Supabase → Logs → API |
| Which function is slow | Chrome DevTools → Performance (record, then find the long task) |
| Overall page quality | **Lighthouse** in DevTools, run in mobile mode |
| Real users over time | **Vercel Analytics** / Speed Insights |
| Is the table the problem | `select pg_size_pretty(pg_total_relation_size('public.issues'))` |
| Is it the paint, not the data | DevTools → Rendering → Paint flashing, then look at the modal and the list |

---

## Worth knowing

**None of this is a bug.** For the size this system is built for - a team
board of a few hundred issues - every item here is invisible. Each one is the
cost of a choice that keeps the app simple: one file, no build step, no
server, and everything loaded at once.

**Three of them are the real ceiling:** the unbounded fetch (#1), the render
passes (#5), and uncoalesced updates (#4). Those are what turn "fine" into
"slow" as data and users grow.

**Two of them cost nothing to fix and help immediately:** the debounce (#9)
and the single-pass counts (#5, #10). Both are front-end only.

**Nothing here needs a rewrite.** Most are query and state changes; a handful
are local edits. Only #28 (adding a build step) changes how the app is
delivered, and that can wait.
