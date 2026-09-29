# Tests

Two ways to check the API, and one that checks the lot. The last one needs
nothing but the Supabase CLI being logged in.

---

## 0. Check everything at once — this is the one you want

```powershell
cd tests
.\check-all.ps1
```

It checks the database, the API, the app and the installable bits, and prints a
PASS or FAIL for each. **No arguments.** It mints two temporary keys, tests with
them, and revokes them again, so it leaves nothing behind.

```
1. Can we reach the database?     CLI logged in
2. The database schema            7 tables, 13 functions, 5 triggers,
                                  RLS on, auto-backup on, snapshots stored
3. Two temporary keys             created
4. The API over HTTPS             api_docs, user key, listing, stats,
                                  tier refused where it should be,
                                  admin key, accounts, create/change/delete,
                                  a made-up key refused
5. The app and its files          the app, /api, /api-status, manifest,
                                  service worker, icons
6. Installable on a phone         standalone, 192, 512, maskable, start url,
                                  fetch handler, push handler
7. Tidying up                     temporary keys revoked
```

Expected: **`ALL GOOD - 33 checks passed`**

A `FAIL` line always says what came back. A `WARN` is something worth knowing
that does not break anything - backups switched off, no snapshots yet.

---

## 1. Offline — no database, no key, nothing to set up

Starts a throwaway PostgreSQL, applies `supabase-schema.sql` to it, and
exercises the whole API. The database lives in `.pgdata` beside this file and
is deleted when it finishes.

```powershell
cd tests
npm install      # once - this fetches PostgreSQL itself, about 30 MB
npm test
```

Expected: **39 checks pass.** It covers

- the schema applying end to end
- `api_docs()` reachable without a key
- a bad key refused on every endpoint
- only an admin being able to mint a key
- **only the hash stored** — never the key itself
- a user key reading, searching, filtering and reporting
- a user key being refused update, delete and list-users
- an admin key doing all three
- bad values refused (a status that is not one of the three)
- the call counter going up, and a revoked key stopping dead
- a webhook attempt being recorded, and **a missing `pg_net` not breaking the
  write**
- `api_keys` being unreadable from outside

If this passes, the SQL in this repository is sound. If it fails, the SQL is
wrong — nothing to do with your project.

---

## 2. Live — against your own project

Tests the deployed API with a real key. It reads the project URL and the anon
key out of `../index.html`, so there is nothing to configure.

```powershell
cd tests
.\api-smoke.ps1 -Key itk_your_key_here
```

It **only reads** by default, so it cannot change your board. Add `-Write` and
it also creates an issue, updates it and deletes it again:

```powershell
.\api-smoke.ps1 -Key itk_your_key_here -Write
```

**Before this will work, two things must be true:**

1. The API SQL is in your database — open the app, **Settings → Database setup
   → Show the setup SQL**, and run it in the Supabase SQL editor.
2. You have a key — **Settings → API keys → Create key**.

If the SQL is missing, the script says so and stops, rather than printing a
wall of confusing errors.

Expected: every line reads `PASS`, then

```
All good: 12 checks passed.
The API is working with this key.
```

A `FAIL` line always says what came back, so you can see whether it was the
key, the tier, or the database.

---

## 3. Apply the SQL with a connection string

When the Supabase CLI is not logged in and you have no access token, this still
works — it needs only the database connection string.

```powershell
cd tests
npm install
node run-sql.js "postgresql://postgres:PASSWORD@db.<ref>.supabase.co:5432/postgres"
```

The string is on the Supabase dashboard under **Project settings → Database →
Connection string → URI**. Use the **Session pooler** one if the direct
connection is not reachable from where you are; both work.

It prints what the database has **before** and **after**, so you can see it
did something:

```
Before:
  issues table    : yes
  api_keys table  : no
  api_docs()      : no

Running the schema (safe to repeat - it updates in place)...
  PASS  the schema applied without error

After:
  PASS  api_keys table
  PASS  webhooks table
  PASS  webhook_deliveries table
  PASS  api_docs()
  PASS  10 API functions
```

It never prints your password back, it is safe to run twice, and it does not
touch the issues already on the board.

---

## 4. By hand, in a browser

The quickest sanity check of all:

```
https://issue-trackers-bay.vercel.app/api.html?key=itk_your_key
```

The console reads `api_docs()` from the database, so the list it shows is
always the real one. It locks the endpoints your key cannot use, runs any of
them, and writes out the equivalent `curl` command.

---

## What each failure usually means

| What you see | What it is |
|---|---|
| `Could not find the function public.api_docs()` | The API SQL has not been run — see step 1 above |
| `Invalid or revoked API key` | The key is wrong, or was revoked — make another |
| `This endpoint needs an admin key` | Working as intended: that endpoint is admin-only |
| `Could not find the table 'public.api_keys'` | An older schema; re-run the setup SQL |
| `column ... does not exist` | Same — re-run the setup SQL, it updates in place |
| Nothing at all, a timeout | The project URL in `index.html` is wrong, or the project is paused |

---

## Why the offline test is worth having

It is the only way to prove the SQL is correct without a database to break. It
runs in about a minute, catches a mistake before it reaches your project, and
is the same set of checks that was used while building the API.
