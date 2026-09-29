# Panduan API — langkah demi langkah

Cara guna REST API Issue Tracker, dari kosong sampai boleh guna dalam code.

> **Dokumen ini telah disemak terhadap API yang sebenar.** Setiap contoh
> respons di bawah adalah output sebenar dari `oswrhpvkhlpvhinsatwh`, bukan
> tulisan tangan.

---

## STEP 1: Dapatkan anon key 🔑

**Anon key = kunci bangunan.** Ia public — semua orang boleh ada. Ia buka
pintu Supabase, tapi **tak bagi akses apa-apa dengan sendirinya**. API key
(kau) yang tentukan apa kau boleh buat.

### Cara paling senang — ia dah ada dalam app

Buka `index.html`, cari dua baris ini di bahagian atas:

```js
var SUPABASE_URL      = "https://oswrhpvkhlpvhinsatwh.supabase.co";
var SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...";
```

**Itu sahaja.** Tak payah pergi Supabase.

### Kalau kau nak ambil dari Supabase

`supabase.com` → login → pilih project → **Settings** → **API** → cari
**Project URL** dan **anon public** key.

> ⚠️ **Anon key selamat di-share.** Ia memang direka untuk public. Yang
> **jangan** share ialah `service_role` key — itu boleh buat apa sahaja.

---

## STEP 2: Daftar akaun 👤

**Kalau kau (owner):** dah ada akaun ✓

**Kalau kawan kau:**

1. Buka https://issue-trackers-bay.vercel.app
2. Klik **Create an account**
3. Isi nama, email, password
4. Submit
5. Kalau email confirmation on → check email, klik link

> ⚠️ **Penting:** borang register tu ada pilihan **role** — Normal user atau
> Administrator. Kalau kawan kau pilih Administrator, dia jadi admin ✗.
> Kalau kau tak nak macam tu, **jangan bagi dia register** — bagi dia **API
> key** sahaja (STEP 3). Dia tak perlu akaun langsung untuk guna API.

---

## STEP 3: Buat API key 🔐

1. Sign in sebagai admin
2. Pergi **Settings** → cari kad **API keys**
3. Taip nama (contoh: `My Bot`, `friend - rawrmeo`)
4. Pilih role:

   | Role | Boleh buat |
   |---|---|
   | **user** | baca, cari, report issue |
   | **admin** | semua, termasuk ubah status, delete, senarai akaun |

5. Klik butang **Create key** ← *(bukan "+ Generate New Key")*

Kau akan dapat:

```
itk_43dcfc20f079d623d11ca46768eadb476512a82b2aec5c40
```

> ⚠️ **Key ini ditunjuk SEKALI sahaja.** Yang disimpan dalam database hanya
> **hash SHA-256** — aku pun tak boleh baca balik. Kalau hilang, revoke dan
> buat baru.

**Simpan di:** password manager, atau `.env` file (jangan commit ke Git).

**Kad tu juga bagi satu link** — tekan **Copy link** untuk dapat URL yang
terus buka konsol dengan key tu sekali.

---

## STEP 4: Faham format request 📝

Semua endpoint guna format yang sama:

```
POST https://oswrhpvkhlpvhinsatwh.supabase.co/rest/v1/rpc/<endpoint>

Headers:
  apikey:        <anon key>
  Authorization: Bearer <anon key>
  Content-Type:  application/json

Body:
  {
    "p_key": "itk_...",       ← API key kau
    ... parameter lain ...
  }
```

| Bahagian | Apa | Dari mana |
|---|---|---|
| URL | Supabase URL + `/rest/v1/rpc/` + nama endpoint | `index.html`, atau Supabase |
| Headers | **anon key, dua kali** | sama |
| Body | **API key** kau + parameter | kau generate |

**Kenapa API key dalam body, bukan dalam header?** Sebab header
`Authorization` dah dipakai oleh PostgREST untuk anon key. API key kau pergi
dalam body sebagai `p_key`.

---

## STEP 5: Test dengan konsol 🧪

1. Buka:
   ```
   https://issue-trackers-bay.vercel.app/api.html?key=itk_your_key_here
   ```
2. Ganti `itk_your_key_here` dengan key kau
3. Konsol akan terus connect dan tunjuk role kau

### Cuba endpoint pertama

- **Endpoint:** `me`
- Klik butang **Run** ← *(bukan "Send")*

> Konsol isi `p_key` sendiri. Kau tak payah taip.

Jawapan sebenar:

```json
{
  "ok": true,
  "key": {
    "name": "friend - rawrmeo",
    "role": "user",
    "prefix": "itk_43dcfc20",
    "requests": 3,
    "created_at": "2026-09-29T01:46:09.713135+00:00"
  }
}
```

> Perhatikan: maklumat ada **di dalam `key`**, bukan di atas. Dan bilangannya
> dipanggil **`requests`**, bukan `call_count`.

### Cuba list issues

- **Endpoint:** `list_issues`
- Isi `p_limit` = `2`
- Klik **Run**

```json
{
  "ok": true,
  "data": [
    { "id": "9d4ddb4a-...", "title": "wifi", "status": "done",
      "priority": "high", "description": "wifi slow lahhhh",
      "created_by_email": "siti@example.com" },
    { "id": "a93e4c47-...", "title": "Lampu bilik mesyuarat rosak",
      "status": "none", "priority": "medium",
      "created_by_email": "alya@gmail.com" }
  ],
  "count": 4,
  "limit": 2,
  "offset": 0
}
```

### Cuba endpoint yang kau TAK dibenarkan

Kalau key kau `user`, cuba `list_users`. Kau akan dapat:

```json
{
  "code": "42501",
  "message": "This endpoint needs an admin key"
}
```

**Itu bukan error — itu betul.** Database yang tolak, bukan page tu.

---

## STEP 6: Test dengan curl 💻

### Contoh 1 — siapa saya (`api_me`)

```bash
curl -X POST 'https://oswrhpvkhlpvhinsatwh.supabase.co/rest/v1/rpc/api_me' \
  -H 'apikey: YOUR_ANON_KEY' \
  -H 'Authorization: Bearer YOUR_ANON_KEY' \
  -H 'Content-Type: application/json' \
  -d '{ "p_key": "itk_your_key_here" }'
```

### Contoh 2 — senarai issues (`api_list_issues`)

```bash
curl -X POST 'https://oswrhpvkhlpvhinsatwh.supabase.co/rest/v1/rpc/api_list_issues' \
  -H 'apikey: YOUR_ANON_KEY' \
  -H 'Authorization: Bearer YOUR_ANON_KEY' \
  -H 'Content-Type: application/json' \
  -d '{ "p_key": "itk_your_key_here",
        "p_status": "pending",
        "p_limit": 10 }'
```

### Contoh 3 — report issue (`api_create_issue`)

```bash
curl -X POST 'https://oswrhpvkhlpvhinsatwh.supabase.co/rest/v1/rpc/api_create_issue' \
  -H 'apikey: YOUR_ANON_KEY' \
  -H 'Authorization: Bearer YOUR_ANON_KEY' \
  -H 'Content-Type: application/json' \
  -d '{ "p_key": "itk_your_key_here",
        "p_title": "Test issue from curl",
        "p_description": "Testing the API",
        "p_priority": "high" }'
```

Jawapan sebenar:

```json
{
  "ok": true,
  "data": {
    "id": "86bebcd0-1cfe-443a-bf1c-2d814d3e93d8",
    "title": "Doc test",
    "status": "none",
    "priority": "low",
    "created_by_email": "api:friend - rawrmeo"
  }
}
```

> **Issues dari API sentiasa mula dengan `status: "none"`** — sama macam orang
> report. Dan reporter ditanda `api:<nama key>` supaya admin tahu ia dari
> script.

### Contoh 4 — statistik (`api_stats`)

```bash
curl -X POST 'https://oswrhpvkhlpvhinsatwh.supabase.co/rest/v1/rpc/api_stats' \
  -H 'apikey: YOUR_ANON_KEY' \
  -H 'Authorization: Bearer YOUR_ANON_KEY' \
  -H 'Content-Type: application/json' \
  -d '{ "p_key": "itk_your_key_here" }'
```

```json
{ "ok": true, "data": { "total": 4, "none": 1, "pending": 1,
                        "done": 2, "high": 1, "users": 7 } }
```

---

## STEP 7: Guna dalam code 🖥️

### JavaScript (browser atau Node)

```js
const SUPABASE_URL = "https://oswrhpvkhlpvhinsatwh.supabase.co";
const ANON_KEY     = "YOUR_ANON_KEY";
const API_KEY      = "itk_your_key_here";

async function callApi(endpoint, body = {}) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${endpoint}`, {
    method: "POST",
    headers: {
      "apikey": ANON_KEY,
      "Authorization": `Bearer ${ANON_KEY}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify({ p_key: API_KEY, ...body })
  });

  const json = await res.json();
  if (!res.ok) throw new Error(json.message);   // { code, message }
  return json;
}

async function main() {
  // 1. siapa saya — perhatikan: data ada DALAM key
  const me = await callApi("api_me");
  console.log("Saya:", me.key.name, "| Role:", me.key.role);

  // 2. list pending
  const issues = await callApi("api_list_issues", { p_status: "pending", p_limit: 5 });
  console.log(`${issues.count} issue dijumpai`);
  issues.data.forEach(i => console.log(`- ${i.title}`));

  // 3. report issue — perhatikan: id ada DALAM data
  const created = await callApi("api_create_issue", {
    p_title: "Test from JS",
    p_description: "Testing API",
    p_priority: "high"
  });
  console.log("Dibuat:", created.data.id);       // ← .data.id, bukan .id
}

main();
```

### Python

```python
import requests

SUPABASE_URL = "https://oswrhpvkhlpvhinsatwh.supabase.co"
ANON_KEY     = "YOUR_ANON_KEY"
API_KEY      = "itk_your_key_here"

def call_api(endpoint, **kwargs):
    res = requests.post(
        f"{SUPABASE_URL}/rest/v1/rpc/{endpoint}",
        headers={
            "apikey": ANON_KEY,
            "Authorization": f"Bearer {ANON_KEY}",
            "Content-Type": "application/json"
        },
        json={"p_key": API_KEY, **kwargs},
        timeout=15
    )
    data = res.json()
    if res.status_code >= 400:
        raise RuntimeError(data.get("message"))
    return data

me = call_api("api_me")
print(f"Saya {me['key']['name']} ({me['key']['role']})")   # ← me['key'][...]

issues = call_api("api_list_issues", p_status="pending", p_limit=5)
print(f"{issues['count']} issue pending")

new_issue = call_api(
    "api_create_issue",
    p_title="Test from Python",
    p_description="Hello from Python",
    p_priority="high"
)
print(f"Dibuat: {new_issue['data']['id']}")                # ← ['data']['id']
```

---

## 📋 Rujukan 9 endpoint

| # | Endpoint | Tier | Arguments | Jawapan |
|---|---|---|---|---|
| 1 | `api_docs` | none | — | API menerangkan dirinya |
| 2 | `api_me` | user | `p_key` | maklumat key |
| 3 | `api_list_issues` | user | `p_key`, `p_status`, `p_priority`, `p_q`, `p_limit`, `p_offset` | senarai issue |
| 4 | `api_get_issue` | user | `p_key`, `p_id` | satu issue |
| 5 | `api_create_issue` | user | `p_key`, `p_title`, `p_description`, `p_priority` | issue yang dibuat |
| 6 | `api_stats` | user | `p_key` | kiraan |
| 7 | `api_update_issue` | **admin** | `p_key`, `p_id`, `p_status`, `p_priority`, `p_note` | issue yang dikemas kini |
| 8 | `api_delete_issue` | **admin** | `p_key`, `p_id` | `deleted: 1` |
| 9 | `api_list_users` | **admin** | `p_key` | semua akaun |

**Nilai yang diterima**

| Argument | Nilai |
|---|---|
| `p_status` | `none` · `pending` · `done` |
| `p_priority` | `low` · `medium` · `high` |
| `p_limit` | 50 default, **maksimum 200** |
| `p_offset` | 0 default |

---

## ⚠️ Error codes

| Code | HTTP | Maksud | Fix |
|---|---|---|---|
| `28000` | 401 | API key tak sah atau dah revoked | Check key, atau buat baru |
| `42501` | 403 | Perlu admin key | Guna admin key |
| `22023` | 400 | Nilai salah (status, title kosong) | Check input |
| `P0002` | 404 | Row tak ada | Check `p_id` |
| `PGRST202` | 404 | Function tak ada | Run SQL setup |
| `PGRST205` | 404 | Table tak ada | Run SQL setup |
| `42703` | 400 | Column tak ada | Run SQL setup (ia update in-place) |

---

## ✅ Checklist

```
[ ] STEP 1  Ambil anon key — ia dah ada dalam index.html
[ ] STEP 2  (Pilihan) Kawan daftar akaun — atau bagi API key sahaja
[ ] STEP 3  Buat API key: Settings → API keys → Create key
[ ] STEP 3b SIMPAN key tu — ditunjuk sekali sahaja
[ ] STEP 4  Faham: anon key dalam header, API key dalam body sebagai p_key
[ ] STEP 5  Test dalam konsol: /api.html?key=... → Run
[ ] STEP 6  Test dengan curl
[ ] STEP 7  Guna dalam code kau sendiri
```

---

## Satu peringatan

**Jangan letak API key dalam page web atau mobile app.** Sesiapa yang view
source boleh baca dia. Panggil API dari server kau sendiri.

Ini satu-satunya had besar API ni, selain:

| | |
|---|---|
| Rate limiting | **tiada** — sesiapa boleh call berapa kali pun |
| Key expire | **tiada** — kekal sampai kau revoke |
| Delete | **kekal** — tak ada recycle bin |

---

## Dokumen berkaitan

| Fail | Isi |
|---|---|
| [`API.md`](API.md) | reference penuh, termasuk webhooks |
| [`API-SYSTEM.md`](API-SYSTEM.md) | semua endpoint, function, table, trigger — satu page |
| [`PRESENTING.md`](PRESENTING.md) | cara demo API ni kepada orang |
