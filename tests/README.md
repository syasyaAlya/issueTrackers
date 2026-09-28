# Tests

Two ways to check the REST API. One needs nothing but Node, the other checks
your real project.

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

## 3. By hand, in a browser

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
