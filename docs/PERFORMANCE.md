# Performance issues - Issue Tracker

Every problem in this system that makes it slower than it could be, what it
costs, how to fix it, and which tool does the fixing.

Measured on the code as it stands: `index.html` is **227 KB** (146 KB of it
inline JavaScript, 38 KB inline CSS), and the whole app is one file.

**Key facts used below**

| | |
|---|---|
| Issues fetched per load | **all of them** — `select *` with no limit |
| Database round trips to change one status | **2** — the write, then a full re-read |
| Requests per open tab | **4 per minute** — the 15 second poll, forever |

---

## 1. The list

Priority: **P1** = do it first, **P2** = soon, **P3** = when it hurts.

| # | Pri | Issue | Where | What it costs | How to resolve | System / tool |
|---|---|---|---|---|---|---|
| 1 | **P1** | Every issue is fetched on every load, with no limit | `listIssues()` — `select *`, no `.range()` | Payload and parse time grow with the table. 10,000 issues is several MB on every screen load, on a phone | Add keyset pagination: order by `updated_at`, `limit(50)`, and load more on scroll. Keep a count separately | **Supabase PostgREST** `.range()` + `count: 'exact'` |
| 2 | **P1** | Every write re-fetches the whole table | `mutate()` → `refresh()` | One status change = 1 write + 1 full table read. Admins doing bulk edits multiply this | Patch the changed row from the write's own response; reconcile in the background | **Supabase** `.update().select().single()`, **Realtime** |
| 3 | **P1** | A poll every 15 seconds, forever, in every open tab | `startLiveUpdates()` — `setInterval(…, 15000)` | 4 requests per minute per user, each returning the whole issue list. 20 people = 4,800 full reads an hour | Where Realtime works, drop the poll. Otherwise back off to 60 s and skip while the tab is hidden | **Supabase Realtime**, `visibilitychange` |
| 4 | **P1** | Refreshes overlap | `refresh()` has no in-flight guard | A poll, a Realtime event and a write can fire three full reads at once | One request at a time: keep the in-flight promise and drop or queue duplicates | Plain JS `AbortController` |
| 5 | **P1** | Search, filter and sort all run on the client | `visibleIssues()`, `render()` | Only searches what was downloaded, and does it on the main thread on every keystroke | Move search and filtering into the query, with an index behind it | **PostgreSQL** `tsvector` + GIN index, or `pg_trgm` |
| 6 | **P1** | No debounce on either search box | `el("search")`, `el("userSearch")` `input` handlers | Re-renders the entire list on **every keystroke** | Debounce 150–250 ms | Plain JS |
| 7 | **P1** | Per-user report count is O(users × issues) | `renderUsers()` — `issues.filter()` inside the user map | 50 users × 5,000 issues = **250,000 comparisons per render**, and it re-renders on every search keystroke | Count once per user in a single pass over `issues`, then look up | Plain JS (single pass), or a PostgREST aggregate view |
| 8 | **P2** | Notifications are rebuilt twice on every refresh | `updateBell()` → `unreadCount()` → `buildNotifications()`, plus `renderNotifications()` | 2 × (4 × n) per refresh, every 15 seconds, in every open tab | Build once per refresh and share the result | Plain JS memo, or a `notifications` table |
| 9 | **P2** | The whole list is re-rendered from strings | `render()` assigns `innerHTML` | Rebuilds every row, drops DOM state, and forces layout on long lists | Diff and update only changed rows; or virtualise the list | Plain JS, or CSS `content-visibility: auto` |
| 10 | **P2** | The entire table is held in memory | `issues` array | Memory pressure and GC pauses on low-end phones | Paginate, and release pages that are off screen | Plain JS |
| 11 | **P2** | Avatars are base64 blobs inside the profile row | `saveAvatar()` → `canvas.toDataURL()` → `profiles.avatar_url` | ~8–10 KB per user, sent on **every** user list and profile read, and re-parsed every render | Upload the file, store only a URL | **Supabase Storage** |
| 12 | **P2** | Backups copy the entire table as one JSON value | `snapshot_issues()` — `jsonb_agg(to_jsonb(i))` | On the first change of every hour, the whole table is serialised and written, then old rows deleted | Snapshot only what changed, or use the platform's own backups | **Supabase PITR**, or `pg_dump` on **pg_cron** |
| 13 | **P2** | Restore deletes everything, then re-inserts | `restore_backup()` | One long transaction, the table locked, a full rewrite | Restore into a staging table, then swap in one step. Or use point-in-time recovery instead | **PostgreSQL**, **Supabase PITR** |
| 14 | **P3** | `replica identity full` on `issues` | schema | Every UPDATE writes the whole previous row to the write-ahead log | Use `default` unless something really needs the old row in the event | **PostgreSQL** `ALTER TABLE` |
| 15 | **P3** | `select *` on profiles and issues | `listUsers()`, `_ensureProfile()`, `listIssues()` | Sends columns nobody asked for, including the avatar blob | Name the columns each screen needs | PostgREST select list |
| 16 | **P3** | No server-side filter indexes for priority | schema | If filtering moves to the database, `priority` has no index | Indexes already exist on `status`, `created_by`, `updated_at` | **PostgreSQL** `CREATE INDEX` |
| 17 | **P3** | The service worker is network-first for everything | `sw.js` `fetch` handler | Every asset waits on the network before the cache is even considered, and the cache is written on every request | Cache-first for static files (icons, manifest), network-first for HTML only | **Workbox** |
| 18 | **P3** | No build step: 227 KB single file | `index.html` | The HTML must revalidate every load, so the JavaScript and CSS inside it are **re-downloaded every time**. Nothing is minified | Split CSS and JS into separate hashed files, minify, let the browser cache them | **Vite** or **esbuild** |
| 19 | **P3** | Row-level security calls `is_admin()` per row | policies on `issues` | Extra work per row on update and delete | Already `stable`, which lets the planner cache it; at scale, put the role in the JWT and compare a claim | **PostgreSQL** (custom JWT claims) |
| 20 | **P3** | Demo mode re-parses the whole store on every call | `demoBackend` `read()` / `write()` | `JSON.parse` of the entire list on every call, synchronously, blocking the interface | Only affects the demo; use IndexedDB if it matters | **IndexedDB** (`idb`) |
| 21 | **P3** | Nothing is measured | - | No query statistics, no API timings, so slow parts are invisible | Turn on query stats and keep an eye on API logs | **pg_stat_statements**, Supabase logs, Vercel Analytics |
| 22 | **P3** | Never load-tested | - | Behaviour above a few hundred rows is unknown | Seed a few thousand rows, then measure properly | `EXPLAIN (ANALYZE, BUFFERS)`, **Lighthouse**, Chrome Performance |

---

## 2. If you only do five things

| Order | Do this | Why first |
|---|---|---|
| 1 | Debounce both search boxes (#6) | Fewest lines, immediate feel on a phone |
| 2 | Fix the per-user count to one pass (#7) | Removes a 250,000-comparison loop that runs per keystroke |
| 3 | Add a limit and pagination to `listIssues` (#1) | The one that decides whether it still works at 10,000 issues |
| 4 | Stop the full re-read after every write (#2) | Halves the work of every action users take |
| 5 | Replace the 15 second poll with Realtime (#3) | Removes 4 requests per minute per person, for good |

Items 1 and 2 are front-end only and need no database work at all.

---

## 3. How to measure, so this stops being guesswork

| What | Tool |
|---|---|
| Which query is slow | `pg_stat_statements`, and `EXPLAIN (ANALYZE, BUFFERS)` in the Supabase SQL editor |
| Which request is slow | Browser DevTools → Network, and Supabase → Logs → API |
| Which function is slow | Chrome DevTools → Performance (record, then find the long task) |
| Overall page quality | **Lighthouse** in DevTools (run it in mobile mode) |
| Real users over time | **Vercel Analytics** / Speed Insights |
| Is the table the problem | `select pg_size_pretty(pg_total_relation_size('public.issues'))` |

---

## 4. Worth knowing

**None of this is a bug.** For the size this system is built for - a team
board of hundreds of issues - every item above is invisible. They are the
costs of the design choices that make it simple: one file, no build step, no
server, and everything loaded at once.

**The three that bite first are #1, #3 and #7.** They are the ones that turn
"fine" into "slow" as the data and the number of users grow, and all three are
straightforward to fix.

**Nothing here needs a rewrite.** Items 1, 2, 3, 5 and 6 are query and state
changes. Items 7, 8 and 9 are local edits. Only #18 (a build step) changes how
the app is delivered, and that can wait.
