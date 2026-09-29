# Cara nak present — run sheet

Ikut je. Tak payah hafal apa-apa.

**Masa: 3 minit.** Yang penting: **dashboard** — sebab orang boleh nampak dengan mata.

---

## ⏰ SEBELUM MULA (5 minit)

### 1. Admin key untuk demo — **dah siap** ✅

Aku dah buatkan satu, nama `present`:

```
itk_de985e14ac268a364b3efeff5c09c7dee6db6ab55a3bd54c
```

**Dashboard link untuk Tab 1:**
```
https://issue-trackers-bay.vercel.app/dashboard?key=itk_de985e14ac268a364b3efeff5c09c7dee6db6ab55a3bd54c
```

*(Kalau kau nak buat sendiri pun boleh — Settings → API keys → Create key.
Tapi yang ni dah siap, terus boleh guna.)*

### 2. Sediakan 4 tab

Susun macam ni, dari kiri:

| Tab | URL |
|---|---|
| **1** | `https://issue-trackers-bay.vercel.app/dashboard?key=<ADMIN KEY KAU>` |
| **2** | `https://issue-trackers-bay.vercel.app/dashboard?key=itk_e82bbc8d12e657adf432a0ba908078dfb1b1dedfe5579235` |
| **3** | `https://issue-trackers-bay.vercel.app/api?key=<ADMIN KEY KAU>` |
| **4** | `https://issue-trackers-bay.vercel.app/api-status` |

### 3. Test dulu

```powershell
cd "C:\Users\HP\OneDrive\Documents\Default Project\tests"
.\check-all.ps1
```

Kalau keluar **`ALL GOOD - 33 checks passed`** → kau selamat. Kalau tak, guna screenshot (di bawah).

---

## 🎬 SKRIP

### TAB 1 — Dashboard (ADMIN key)

Buka. Tunggu nombor muncul.

**Cakap:**
> "Ini dashboard. Kawan saya boleh buka link ni terus — tak payah daftar akaun, tak payah apa-apa."

**Tunjuk nombor:**
> "Total 4 issue. 1 pending, 2 done, 1 belum ada status, 1 high priority yang masih terbuka."

**Tunjuk list:**
> "Semua issue dari board, boleh search, boleh filter."

### ⭐ Tukar status — LIVE

Tengok satu issue. Tukar dropdown dari `pending` → `done`.

**Nombor atas terus berubah.**

**Cakap:**
> "Tengok — nombor atas berubah sendiri. Saya baru ubah status dari sini."

*(Ini yang paling orang suka. Bukan slide, tapi benda betul bergerak.)*

### TAB 2 — Dashboard (USER key)

Buka. Nampak board yang sama.

**Cakap:**
> "Ini dashboard yang SAMA. Tapi kali ni guna user key."

**Tunjuk:**
- Badge tukar jadi **USER**
- Subtitle: **"read only"**
- **Dropdown status hilang**
- **Butang delete hilang**

**Cakap:**
> "User key tak boleh ubah apa-apa. Butang tu bukan disorok — database yang tolak. Kalau dia paksa hantar request, tetap gagal."

### TAB 3 — API Console

**Cakap:**
> "Ini untuk developer. Semua 9 endpoint ada."

- Pilih **`stats`** → tekan **Run** → JSON keluar

**Cakap:**
> "Data betul dari board. Ini yang kawan kau guna kalau dia nak bina app sendiri."

### TAB 4 — Status page

**Cakap:**
> "Dan ini page yang check semuanya berfungsi — tanpa perlu key."

Tunggu → **12/12 hijau** ✓

> "Mana-mana orang boleh buka link ni bila-bila masa, dan tahu system OK ke tak."

---

## 🎯 Ayat penutup

> "Semuanya jalan atas database yang sama. Tiga cara masuk — app untuk manusia, dashboard untuk kawan, API untuk program. Dan database yang tentukan siapa boleh buat apa."

---

## ❓ Kalau orang tanya

| Soalan | Jawab |
|---|---|
| Ada server? | **Takde.** Semua dalam database. |
| Key disimpan macam mana? | **Hash sahaja.** Ditunjuk sekali. |
| Kalau key bocor? | Revoke dalam Settings. Terus mati. |
| User boleh jadi admin? | **Tak.** Database yang tolak. |
| Ada rate limit? | **Belum ada.** Ada tulis dalam dokumen. |
| Key expire? | **Tak.** Sampai kau revoke. |
| Kenapa takde recycle bin? | Sengaja buang — delete terus kekal. |

---

## 🚨 Kalau wifi mati

Screenshot dalam Desktop, terus masukkan dalam slide:

| Fail | Tunjuk apa |
|---|---|
| `dashboard-shared.png` | dashboard, user key |
| `dashboard-admin.png` | dashboard, admin key — ada dropdown & delete |
| `demo-1-status-green.png` | status page, semua hijau |
| `demo-2-console.png` | API console |
| `demo-3-call.png` | call betul dengan nombor sebenar |
| `where-api-key.png` | macam mana nak buat key |

---

## ⚠️ Jangan cakap

| Jangan | Sebab |
|---|---|
| "Ada rate limiting" | **Takde.** |
| "Key expire" | **Takde.** |
| "Boleh sambung GraphQL" | Boleh, tapi **belum ON**. |

---

## Kalau tersekat

```powershell
cd "C:\Users\HP\OneDrive\Documents\Default Project\tests"
.\check-all.ps1                       # system OK ke tak
.\api-smoke.ps1 -Key <key>            # satu key, live
```

Dokumen penuh: [`API-SYSTEM.md`](API-SYSTEM.md) · [`PANDUAN-API.md`](PANDUAN-API.md)
