# The API system, on one page

Everything that makes up the REST API, listed. Taken from the live database
and the API's own `api_docs()` answer, not from memory.

---

## Where it lives

| | |
|---|---|
| **Base** | `POST https://oswrhpvkhlpvhinsatwh.supabase.co/rest/v1/rpc/<endpoint>` |
| **Status page** (no key) | https://issue-trackers-bay.vercel.app/api-status |
| **Shared dashboard** (needs a key) | https://issue-trackers-bay.vercel.app/dashboard?key=… |
| **Console** (needs a key) | https://issue-trackers-bay.vercel.app/api?key=… |
| **Reference guide** | [API.md](API.md) |
| **Step by step, in Malay** | [PANDUAN-API.md](PANDUAN-API.md) |
| **Tests** | `../tests/` — offline, live, and `check-all.ps1` for everything |

**Dashboard or console?**

| | Dashboard | Console |
|---|---|---|
| For | a person — a friend, a client | a developer |
| Shows | the board: numbers, list, filters | JSON, every endpoint, curl |
| An admin key can | change a status, delete, report | anything |

There is no server. Every endpoint is a database function reached through the
PostgREST endpoint Supabase already provides.

---

## Keys — two tiers

| Tier | Can do |
|---|---|
| **user** | list, read, search and filter issues · read statistics · report an issue |
| **admin** | all of that, **plus** change status / priority / message · delete an issue · list every account |

Only a **SHA-256 hash** is stored. The key is shown once, when it is created.
Each key tracks `last_used_at` and `request_count`, and revoking stops it
immediately.

Make and revoke them in the app: **Settings → API keys**.

---

## Endpoints — 9

All are `POST`. Send the key in the body as `p_key`.

| # | Endpoint | Tier | Arguments | Answers with |
|---|---|---|---|---|
| 1 | `api_docs` | none | — | the API describing itself |
| 2 | `api_me` | user | `p_key` | this key's name, prefix, role, call count |
| 3 | `api_list_issues` | user | `p_key`, `p_status`, `p_priority`, `p_q`, `p_limit`, `p_offset` | `count`, `limit`, `offset`, `data[]` |
| 4 | `api_get_issue` | user | `p_key`, `p_id` | one issue |
| 5 | `api_create_issue` | user | `p_key`, `p_title`, `p_description`, `p_priority` | the issue it made |
| 6 | `api_stats` | user | `p_key` | totals by status and priority |
| 7 | `api_update_issue` | **admin** | `p_key`, `p_id`, `p_status`, `p_priority`, `p_note` | the updated issue |
| 8 | `api_delete_issue` | **admin** | `p_key`, `p_id` | `deleted: 1` |
| 9 | `api_list_users` | **admin** | `p_key` | every account |

**Defaults and limits**

| Argument | Value |
|---|---|
| `p_limit` | 50 by default, capped at **200** |
| `p_offset` | 0 |
| `p_status` | `none` · `pending` · `done` |
| `p_priority` | `low` · `medium` · `high` |

Issues created through the API always start with **no status** (`none`) and are
marked `created_by_email = "api:<key name>"`.

---

## Functions — 13

**The API** (reachable from outside, with the anon key):

```
api_docs           —
api_me             p_key
api_list_issues    p_key, p_status, p_priority, p_q, p_limit, p_offset
api_get_issue      p_key, p_id
api_create_issue   p_key, p_title, p_description, p_priority
api_stats          p_key
api_update_issue   p_key, p_id, p_status, p_priority, p_note
api_delete_issue   p_key, p_id
api_list_users     p_key
```

**The gatekeepers** (internal, not granted to anyone):

```
api_role           p_key                        which tier is this key, if any
api_check          p_key, p_need_admin          fails closed before any data is touched
```

**Key management** (called by the signed-in app, admin only):

```
create_api_key     p_name, p_role               returns the plaintext once
revoke_api_key     p_id
```

---

## Tables — 7

| Table | Holds |
|---|---|
| `issues` | the board |
| `profiles` | accounts, roles, avatars, notification preferences |
| `api_keys` | name, prefix, **hash**, role, created, revoked, last used, call count |
| `webhooks` | url, secret, which events, active |
| `webhook_deliveries` | every attempt: event, payload, `sent`, error |
| `backups` | automatic snapshots (the newest 30) |
| `app_settings` | the single auto-backup on/off row |

---

## Triggers — 5

| Trigger | On | Does |
|---|---|---|
| `issues_guard_update` | `issues` update | admins only may change details |
| `issues_touch_updated_at` | `issues` update | stamps `updated_at` |
| `issues_auto_backup` | `issues` insert/update/delete | snapshot, at most once an hour |
| `issues_webhook` | `issues` insert/update/delete | calls your webhooks |
| `profiles_guard_role` | `profiles` update | only an admin may change a role |

---

## Webhooks

Register a url and the events it wants. A trigger posts to it and records every
attempt.

| Event | Fires when |
|---|---|
| `issue.created` | an issue is reported, from the app or the API |
| `issue.updated` | status, priority or message changes |
| `issue.deleted` | an issue is removed |

**What arrives** — `Content-Type: application/json` plus:

```
X-Webhook-Event:  issue.updated
X-Webhook-Secret: <the secret on the webhook row>
```

```json
{ "event": "issue.updated", "at": "...", "data": { "id": "…", "status": "done" } }
```

Delivery needs `pg_net`. Where it is missing the attempt is still recorded with
the reason — **a failed delivery never breaks the write**.

---

## Calling it

```bash
curl -X POST 'https://oswrhpvkhlpvhinsatwh.supabase.co/rest/v1/rpc/api_list_issues' \
  -H 'apikey: <anon key>' \
  -H 'Authorization: Bearer <anon key>' \
  -H 'Content-Type: application/json' \
  -d '{ "p_key": "itk_...", "p_status": "pending", "p_limit": 10 }'
```

The **anon key** opens the door — it is public and grants nothing by itself.
Your **API key** in the body decides what you may actually do.

---

## Errors

| Code | HTTP | Means |
|---|---|---|
| `28000` | 401 | invalid or revoked API key |
| `42501` | 403 | the key is fine, but this needs an admin key |
| `22023` | 400 | a value is wrong — a status that is not one of the three, an empty title |
| `P0002` | 404 | no row with that id |
| `42703` `PGRST202` `PGRST205` | 400/404 | the database is missing part of the schema — re-run the setup SQL |

---

## Verified

Last run against the live project:

| | |
|---|---|
| user key | **13 / 13 pass** |
| admin key | **18 / 18 pass** — including create, change and delete |
| status page | **12 / 12 pass** |
| the board | untouched |

Reproduce it any time:

```powershell
cd tests
.\api-smoke.ps1 -Key itk_your_user_key
.\api-smoke.ps1 -Key itk_your_admin_key -Write
```

---

## Honest limits

| | |
|---|---|
| Rate limiting | **none** — a key can call as often as it likes |
| Key expiry | **none** — a key lasts until revoked |
| Scoping | a user key reads **every** issue, like any signed-in person |
| Webhook retries | failures are logged, not retried |
| Deleting | **permanent** — there is no recycle bin |
