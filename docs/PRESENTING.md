# Presenting the API

A demo you can run in about two minutes, and what to say while you do.

---

## Before you start — 30 seconds

Open a terminal and run this. If it says **ALL GOOD**, everything works and you
can present without worrying.

```powershell
cd "C:\Users\HP\OneDrive\Documents\Default Project\tests"
.\check-all.ps1
```

```
ALL GOOD - 33 checks passed
The database, the API, the app and the installable bits are all working.
```

If it does **not** say that, do not present live — use the screenshots instead
(see the end).

---

## What to have open, in this order

| Tab | Address |
|---|---|
| 1 | `https://issue-trackers-bay.vercel.app/api-status` |
| 2 | `https://issue-trackers-bay.vercel.app/api?key=itk_e82bbc8d12e657adf432a0ba908078dfb1b1dedfe5579235` |
| 3 | `https://github.com/syasyaAlya/issueTrackers/blob/main/docs/API-SYSTEM.md` |
| 4 | The app itself — `https://issue-trackers-bay.vercel.app` |

---

## The demo, step by step

### 1. Tab 1 — "it is installed and working"

Point at the green banner.

> "This page checks the API without needing a key. It asks the database what
> functions and tables exist, and probes all nine endpoints. Green means every
> piece is in place."

**12 of 12 checks.** Let it run — it takes a few seconds and the checks tick in.

---

### 2. Tab 2 — "here is the API itself"

The console has the key already in the link.

> "Anyone I give a key to opens a link like this and can use the API
> immediately. It reads the endpoint list from the database, so it can never be
> out of date."

**Point out:** the badge says **USER**, and four endpoints are marked
**locked**.

> "This is a user key. It can read and report — but it cannot change a status,
> delete anything, or list accounts. Those are greyed out because the database
> told the page this key is not allowed. The browser is not deciding that; the
> database is."

---

### 3. Still on Tab 2 — run a call

Pick **`stats`**, press **Run**.

```json
{ "ok": true, "data": { "done": 2, "high": 1, "none": 1,
                        "total": 4, "users": 7, "pending": 1 } }
```

> "That is live data from the real board."

---

### 4. The best moment — swap the key

Paste the **admin** key over the user key and press **Connect**:

```
itk_61cb0403d0b59b03e056d7fe26e8ba72f316b96338e89757
```

**The locks disappear, and the role badge changes to ADMIN.**

> "Same API. Same request. The only difference is which key was used — and the
> database decides what that key may do. That is enforced in Postgres, so a
> crafted request from a browser cannot get around it."

This is the strongest 10 seconds of the demo. **The four locked endpoints unlock
in front of them.**

---

### 5. Prove it end to end — create something

Pick **`create_issue`**, fill in a title, press **Run**.

Then switch to **Tab 4** (the app) and reload.

> "That issue was never typed into the app. It came in through the API, and it
> is on the board with no status — exactly like a report from a person, and
> marked as coming from the API."

---

### 6. Tab 3 — the reference

> "Every endpoint, function, table and trigger, on one page."

---

## If someone asks...

| Question | Answer |
|---|---|
| **"Is there a server?"** | No. Every endpoint is a database function reached through Supabase's own REST layer. Nothing to deploy, nothing to keep running. |
| **"How are keys stored?"** | SHA-256 hashes only. The key is shown once when made; even I cannot read it back. |
| **"What if a key leaks?"** | Revoke it in Settings → API keys. It stops working immediately. |
| **"Can a normal user escalate?"** | No. The tier check runs inside the database, before any data is touched. It fails closed. |
| **"Does it handle webhooks?"** | Yes — created, updated and deleted. Every delivery is logged with success or the reason it failed, and a failed hook never breaks the write. |
| **"What about rate limiting?"** | **None yet.** One key can call as often as it likes. It is written down as a known limit. |
| **"Why should I trust it works?"** | Three ways: 33 checks on the whole system, 13 with a user key, 18 with an admin key — including a real create, change and delete. All runnable in front of you. |

---

## The numbers, if you want them

| | |
|---|---|
| Endpoints | **9** |
| Key tiers | **2** — user and admin |
| Database functions | **13** |
| Tables | **7** |
| Triggers | **5** |
| Webhook events | **3** |
| Round trips to change one status | **2** |
| Data fetched per call | capped at **200** rows |
| Checks that pass | **33 · 13 · 18** |

---

## If anything goes wrong on the day

Every screenshot is on your Desktop, ready to drop into slides:

| File | Shows |
|---|---|
| `demo-1-status-green.png` | the status page, all green |
| `demo-2-console.png` | the console, a user key connected |
| `demo-3-call.png` | a live call with real numbers |
| `demo-4-app.png` | the app itself |

And if the API itself ever looks off:

```powershell
cd tests
.\check-all.ps1              # the whole system
.\api-smoke.ps1 -Key itk_... # one key, live
```

---

## Two things not to say

**Do not claim rate limiting** — there is none. Say "not yet, and it is written
down as a limit."

**Do not claim keys expire** — they do not. They last until revoked.
