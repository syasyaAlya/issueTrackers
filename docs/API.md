# Issue Tracker API

Read and report issues from another system, without signing in as a person.

> **Base:** `POST https://<project>.supabase.co/rest/v1/rpc/<endpoint>`
> **Console:** `api.html?key=<your key>` — a page that tries every endpoint for
> you, in the browser. On the deployed site the short form `/api?key=...` works
> too.

---

## 1. Getting a key

1. Sign in as an administrator.
2. **Settings → API keys**
3. Type what the key is for, pick **User** or **Admin**, press **Create key**.
4. **Copy it straight away.** Only its hash is stored, so it is shown once and
   cannot be recovered - if you lose it, revoke it and make another.

There is also a **link** next to the key. That link is the key, so send it the
same way you would send a password.

---

## 2. How a call is authenticated

Two headers and one body field:

| Header | Value |
|---|---|
| `apikey` | the project's **anon** key - the same public one the app uses |
| `Authorization` | `Bearer <anon key>` |
| body `p_key` | **your API key** |

The anon key gets you through the front door; your API key decides what you may
do. That is why the key travels in the body - the `Authorization` header has to
stay free for PostgREST itself.

**Never put an API key in a web page or a mobile app.** Anyone who views the
source can read it. Call the API from your own server.

---

## 3. The two tiers

| | **User key** | **Admin key** |
|---|---|---|
| List, read and search issues | yes | yes |
| Report an issue | yes | yes |
| Read statistics | yes | yes |
| Change status, priority, or leave a message | no | yes |
| Delete an issue | no | yes |
| List every account | no | yes |
| Manage keys and webhooks | no | no *(sign in as an admin for that)* |

A call with the wrong tier is refused with `42501` and a message that says so.
Nothing partial happens - the check runs before any data is touched.

---

## 4. Endpoints

Every endpoint is a `POST`, takes the key as `p_key`, and answers with JSON
containing `"ok": true`.

| Endpoint | Tier | Takes | Gives back |
|---|---|---|---|
| `api_me` | user | - | The key's name, prefix, role and how many calls it has made |
| `api_list_issues` | user | `p_status`, `p_priority`, `p_q`, `p_limit`, `p_offset` | `count`, `limit`, `offset`, `data[]` |
| `api_get_issue` | user | `p_id` | One issue |
| `api_create_issue` | user | `p_title`, `p_description`, `p_priority` | The issue it made |
| `api_stats` | user | - | Counts by status and priority |
| `api_update_issue` | **admin** | `p_id`, `p_status`, `p_priority`, `p_note` | The updated issue |
| `api_delete_issue` | **admin** | `p_id` | `deleted: 1` |
| `api_list_users` | **admin** | - | Every account |
| `api_docs` | none | - | This document, as JSON |

**Issues reported through the API always start with no status** (`none`), exactly
like a report from a person, and are marked as coming from the API:

```
created_by_email: "api:friend laptop"
```

Notes on the arguments:

- `p_limit` is capped at **200**, default **50**. Without it you would get the
  whole table on every call.
- `p_q` searches the title, the description and the reporter.
- `p_status` is one of `none`, `pending`, `done`; `p_priority` is one of `low`,
  `medium`, `high`. Anything else is refused with `22023`.
- `api_update_issue` only changes what you send. Omit a field and it stays as it
  was.

---

## 5. Examples

### List the issues waiting to be done

```bash
curl -X POST 'https://<project>.supabase.co/rest/v1/rpc/api_list_issues' \
  -H 'apikey: <anon key>' \
  -H 'Authorization: Bearer <anon key>' \
  -H 'Content-Type: application/json' \
  -d '{ "p_key": "itk_...", "p_status": "pending", "p_limit": 20 }'
```

```json
{
  "ok": true,
  "count": 3,
  "limit": 20,
  "offset": 0,
  "data": [
    { "id": "…", "title": "Printer on fire", "status": "pending",
      "priority": "high", "created_by_email": "user@example.com",
      "created_at": "2026-09-28T02:11:07.219Z", "updated_at": "2026-09-28T02:11:07.219Z" }
  ]
}
```

### Report an issue

```bash
curl -X POST 'https://<project>.supabase.co/rest/v1/rpc/api_create_issue' \
  -H 'apikey: <anon key>' -H 'Authorization: Bearer <anon key>' \
  -H 'Content-Type: application/json' \
  -d '{ "p_key": "itk_...", "p_title": "Uploads fail over 10 MB",
        "p_description": "Seen on the staging box", "p_priority": "high" }'
```

### Mark it done (admin key)

```bash
curl -X POST 'https://<project>.supabase.co/rest/v1/rpc/api_update_issue' \
  -H 'apikey: <anon key>' -H 'Authorization: Bearer <anon key>' \
  -H 'Content-Type: application/json' \
  -d '{ "p_key": "itk_...", "p_id": "<uuid>", "p_status": "done",
        "p_note": "Fixed in the 2.1 release" }'
```

### From JavaScript

```js
async function listPending() {
  const res = await fetch(`${PROJECT}/rest/v1/rpc/api_list_issues`, {
    method: 'POST',
    headers: {
      apikey: ANON_KEY,
      Authorization: `Bearer ${ANON_KEY}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({ p_key: API_KEY, p_status: 'pending' })
  });
  if (!res.ok) throw new Error((await res.json()).message);
  return (await res.json()).data;
}
```

### From Python

```python
import requests

def rpc(endpoint, **params):
    params["p_key"] = API_KEY
    r = requests.post(f"{PROJECT}/rest/v1/rpc/{endpoint}",
                      headers={"apikey": ANON_KEY,
                               "Authorization": f"Bearer {ANON_KEY}"},
                      json=params, timeout=15)
    r.raise_for_status()
    return r.json()

print(rpc("api_stats"))
```

---

## 6. Webhooks

A webhook is a URL you own that gets called when an issue changes, so you do not
have to poll.

Register one by signing in as an admin and inserting into `webhooks` (the console
does not create them yet):

```sql
insert into public.webhooks (url, events)
values ('https://example.com/issue-hook',
        array['issue.created', 'issue.updated', 'issue.deleted']);
```

| Event | Fires |
|---|---|
| `issue.created` | an issue is reported, from the app or the API |
| `issue.updated` | the status, priority or message changes |
| `issue.deleted` | an issue is removed |

**What arrives** — a POST with these headers and this body:

```
Content-Type:     application/json
X-Webhook-Event:  issue.updated
X-Webhook-Secret: <the secret on the webhook row>
```

```json
{
  "event": "issue.updated",
  "at": "2026-09-28T02:14:55.101Z",
  "data": { "id": "…", "title": "…", "status": "done", "priority": "high" }
}
```

**Check the secret.** Compare the `X-Webhook-Secret` header with the value on
your webhook row before trusting the body.

**Every attempt is logged** in `webhook_deliveries`, with `sent` and `error`.
A failed delivery never breaks the write that caused it - if the hook URL is
down, the issue still saves and the failure is recorded.

> Delivery needs the `pg_net` extension, which Supabase provides. Where it is
> missing, the attempt is still recorded with the reason, so nothing disappears
> silently - and, deliberately, a missing extension cannot stop the app writing.

---

## 7. Errors

Errors come back as a JSON object with a `message` and a `code`.

| Code | HTTP | Means |
|---|---|---|
| `28000` | 401 | Invalid or revoked API key |
| `42501` | 403 | The key is fine, but this needs an admin key |
| `22023` | 400 | A field is the wrong value - a status that is not one of the three, an empty title, that sort of thing |
| `P0002` | 404 | No row with that id |
| `42703`, `PGRST202`, `PGRST205` | 400/404 | The database is missing part of the schema - run the setup SQL |

```json
{ "code": "42501",
  "message": "This endpoint needs an admin key",
  "details": null, "hint": null }
```

---

## 8. Sharing a key

A key is meant to be handed to someone. Two ways:

**A link they can click.** After creating a key, **Copy link** gives:

```
https://issue-trackers-bay.vercel.app/api.html?key=itk_...
```

They open it and immediately see what the key can do, try every endpoint, and
copy ready-made `curl` commands. This is the fastest way to hand access to
someone who has their own dashboard to build.

**The key on its own.** For their code, send just the key. Treat it as a
password: send it over a channel you trust, and revoke it the moment it is not
needed.

**Housekeeping.** The API keys list shows each key's name, its first characters,
when it was made, how many calls it has taken and when it was last used. If a key
is unused, or the number looks wrong, revoke it.

---

## 9. Limits and honest notes

| | |
|---|---|
| Page size | capped at 200 per call |
| Keys per project | no limit; revoke what you do not need |
| Rate limiting | **none** - a key can call as often as it likes |
| Log of who called | `request_count` and `last_used_at` per key, nothing more |
| Deleting via the API | **permanent.** There is no recycle bin |

Things worth knowing before you build on this:

- **There is no rate limiting.** One misbehaving script can make as many calls as
  it wants. If that matters, put your own limit in front, or use a Supabase Edge
  Function as a thin proxy that counts.
- **Keys do not expire.** They last until revoked. Rotate them by hand.
- **The API sees everything.** A user key can read every issue, the same as any
  signed-in person. There is no per-key scoping yet.
- **Webhook delivery is best-effort.** Failures are logged but not retried.

---

## 10. How it is built

There is no server. Each endpoint is a database function, called through
PostgREST:

```
Caller ──HTTPS──▶ PostgREST ──▶ api_list_issues(p_key, …)
                                    │
                                    ├─ api_check()  ── is the key real, and is it enough?
                                    └─ reads/writes the tables, bypassing RLS as the owner
```

That is why no service-role key is needed anywhere and nothing has to be
deployed. The functions are `SECURITY DEFINER`, so they can read tables the
caller cannot - and every one of them starts by checking the key, so a caller
never gets to a table without passing that gate.

The tables behind it: `api_keys` (hashes only), `webhooks`, and
`webhook_deliveries`. All three are closed to `anon` by row-level security; only
the functions reach them.
