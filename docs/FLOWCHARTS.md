# Flowcharts - Issue Tracker

The whole system as diagrams. One page, no long explanations.

---

**1. System overview** - who talks to what.

```mermaid
flowchart LR
    U["Normal user"] --> APP
    A["Administrator"] --> APP

    APP["Issue Tracker app<br/>index.html + sw.js<br/>runs in the browser"]

    APP -- "demo mode<br/>(no database)" --> LS[("localStorage")]
    APP -- "real mode<br/>HTTPS" --> SB["Supabase<br/>Auth + PostgreSQL"]
    HOST["Vercel<br/>static host"] -- "serves the files" --> APP
```

---

**2. Layers** - each layer only knows the one below it.

```mermaid
flowchart TB
    P["1. Presentation<br/>sidebar, top bar, bottom bar,<br/>drawer, views, modals"] --> A
    A["2. Application<br/>state, permissions,<br/>renderers, notifications"] --> B
    B["3. Backend adapter<br/>the api object<br/>one interface, 28 methods"] --> C
    C["4. Implementations<br/>cloudBackend OR demoBackend"] --> D
    D["5. Data<br/>Supabase PostgreSQL<br/>OR localStorage"]
```

---

**3. Data model** - four tables.

```mermaid
erDiagram
    auth_users ||--|| profiles : "has one"
    auth_users ||--o{ issues : "reports"

    profiles {
        uuid id PK
        text email
        text full_name
        text role "admin or user"
        text avatar_url
        boolean notify_new_issue
        boolean notify_status_done
        boolean notify_high_priority
        timestamptz notifications_seen_at
    }

    issues {
        uuid id PK
        text title
        text description
        text status "none, pending, done"
        text priority "low, medium, high"
        uuid created_by FK
        text created_by_email
        text admin_note
        timestamptz deleted_at "soft delete"
        timestamptz created_at
        timestamptz updated_at
    }

    app_settings {
        boolean id PK
        boolean auto_backup_enabled
    }

    backups {
        uuid id PK
        timestamptz created_at
        text kind "auto or manual"
        jsonb payload "the whole issues table"
    }
```

---

**4. Roles and what each can do.**

```mermaid
flowchart TD
    S["Signed-in user"] --> Q{"profile role?"}
    Q -- "admin" --> A["Administrator"]
    Q -- "user" --> U["Normal user"]

    A --> A1["See the whole board"]
    A --> A2["Report an issue"]
    A --> A3["Change status: none / pending / done"]
    A --> A4["Change priority"]
    A --> A5["Leave a message for the reporter"]
    A --> A6["Delete to the recycle bin"]
    A --> A7["Restore, purge, empty the bin"]
    A --> A8["Manage users"]
    A --> A9["Backups and reports"]

    U --> U1["See the whole board"]
    U --> U2["Report an issue, starts as None"]
    U --> U3["Search and filter"]
    U --> U4["Delete their own issue to the bin"]
    U --> U5["See statistics"]
```

---

**5. Issue lifecycle** - the three statuses.

```mermaid
stateDiagram-v2
    [*] --> None : a user reports it
    None --> Pending : an admin picks it up
    Pending --> Done : an admin finishes it
    Done --> Pending : an admin reopens it
    Pending --> None : an admin clears it
    Done --> None : an admin clears it

    note right of None
        The default.
        Only an admin
        can move it on.
    end note
```

---

**6. Boot / startup** - opening the app.

```mermaid
flowchart TD
    A["App opens"] --> B["getSession()"]
    B --> C{"a session stored?"}
    C -- "yes" --> D["showApp()"]
    C -- "no" --> E["sign-in screen"]
    D --> F["paint avatar, name, role"]
    F --> G["show or hide the admin menu"]
    G --> H["reset view, filters, selection"]
    H --> I["listIssues()"]
    I --> J["render the board"]
    J --> K{"admin?"}
    K -- "yes" --> L["listUsers()"]
    K -- "no" --> M["done"]
    L --> M
```

---

**7. Register** - and how the role is set.

```mermaid
flowchart TD
    A["Register form<br/>email, password, name, role"] --> B["signUp()"]
    B --> C["Supabase creates the auth user"]
    C --> D["trigger on_auth_user_created"]
    D --> E["handle_new_user()<br/>creates the profiles row"]
    E --> F{"metadata role = 'admin'?"}
    F -- "yes" --> G["role = admin"]
    F -- "no, or anything else" --> H["role = user"]
    G --> I{"email confirmation on?"}
    H --> I
    I -- "yes" --> J["check your inbox"]
    I -- "no" --> K["signed in, show the board"]
```

---

**8. Sign in and sign out.**

```mermaid
flowchart TD
    A["Email + password"] --> B["signIn()"]
    B --> C{"correct?"}
    C -- "yes" --> D["show the board"]
    C -- "no" --> E["Incorrect email or password"]
    D --> F["Sign out"]
    F --> G["signOut()"]
    G --> H["back to the sign-in screen"]

    I["Session expires elsewhere"] --> H
```

---

**9. Password reset.**

```mermaid
flowchart LR
    A["Forgot password"] --> B["sendReset(email)"]
    B --> C["email with a link"]
    C --> D["opens the link"]
    D --> E["PASSWORD_RECOVERY event"]
    E --> F["reset screen"]
    F --> G["new password twice"]
    G --> H["updatePassword()"]
    H --> I["signed in again"]
```

---

**10. Report an issue.**

```mermaid
flowchart TD
    A["Report an issue"] --> B["title, description, priority"]
    B --> C{"who is reporting?"}
    C -- "normal user" --> D["status forced to None<br/>no status control shown"]
    C -- "admin" --> E["may also pick a status"]
    D --> F["createIssue()"]
    E --> F
    F --> G["DB: RLS requires<br/>auth.uid() = created_by"]
    G --> H["DB: status defaults to None"]
    H --> I["DB: backup trigger fires"]
    I --> J["reload the board"]
    J --> K["Issue reported"]
```

---

**11. Edit an issue and change status.**

```mermaid
flowchart TD
    A["An admin opens an existing issue"] --> B["Title and description<br/>are read-only"]
    B --> C["They can change<br/>status, priority, message"]
    C --> D["updateIssue()"]
    D --> E["DB: RLS issues_update_admin<br/>admins only"]
    E --> F["DB: guard_issue_update<br/>second check"]
    F --> G["DB: touch updated_at"]
    G --> H["DB: backup trigger"]
    H --> I["reload the board"]

    J["A normal user tries"] --> K["No update policy matches<br/>+ no status control"]
    K --> L["Rejected by the database"]
```

---

**12. Delete, recycle bin, restore, purge.**

```mermaid
flowchart TD
    A["Delete an issue"] --> B["soft_delete_issue()"]
    B --> C{"reported by you,<br/>or are you an admin?"}
    C -- "no" --> D["rejected"]
    C -- "yes" --> E["deleted_at = now()"]

    E --> F["The row fails the select policy,<br/>so it vanishes from EVERY list<br/>with no query changed"]

    F --> G["Admin opens the Recycle bin"]
    G --> H["list_deleted_issues()<br/>admins only"]
    H --> I{"what next?"}
    I -- "Restore" --> J["restore_issue()<br/>deleted_at = null"]
    I -- "Delete for good" --> K["purge_issue()<br/>row removed for ever"]
    I -- "Empty the bin" --> L["empty_recycle_bin()<br/>all binned rows removed"]

    J --> M["back on the board"]
```

---

**13. Permission enforcement** - the same rule, three times.

```mermaid
flowchart TD
    A["User clicks something"] --> B{"1. Interface<br/>is the control rendered?"}
    B -- "hidden" --> Z["nothing to click"]
    B -- "shown" --> C{"2. App logic<br/>can() / isAdmin()"}
    C -- "no" --> Y["blocked with a message"]
    C -- "yes" --> D["the request is sent"]
    D --> E{"3. DATABASE<br/>does an RLS policy match?"}
    E -- "no" --> F["rejected"]
    E -- "yes" --> G{"triggers allow it?"}
    G -- "no" --> H["exception, write rolled back"]
    G -- "yes" --> I["the write happens"]

    style E fill:#ffe0e0
    style G fill:#ffe0e0
    style I fill:#e0ffe4
```

> Only step 3 is a real security boundary. Steps 1 and 2 just keep the
> interface honest.

---

**14. Automatic backups** - done by the database, not the browser.

```mermaid
flowchart TD
    A["Any insert / update / delete on issues"] --> B["trigger issues_auto_backup"]
    B --> C["auto_snapshot()"]
    C --> D{"auto backup switched on?"}
    D -- "no" --> E["do nothing"]
    D -- "yes" --> F{"already backed up<br/>in the last hour?"}
    F -- "yes" --> G["throttled, do nothing"]
    F -- "no" --> H["snapshot_issues()"]
    H --> I["store the whole issue list as JSON"]
    I --> J["keep only the newest 30"]
    J --> K["done"]

    L["pg_cron 02:00 nightly"] --> C
```

---

**15. Manual backup and restore.**

```mermaid
flowchart TD
    A["Admin: Back up now"] --> B["create_backup()"]
    B --> C["admins only"]
    C --> D["snapshot stored"]

    E["Admin: Restore a snapshot"] --> F["restore_backup()"]
    F --> G["admins only, snapshot exists?"]
    G --> H{"are the reporters<br/>still real accounts?"}
    H -- "no, all deleted" --> I["REFUSE<br/>restoring would empty the board"]
    H -- "yes" --> J["take a safety snapshot FIRST"]
    J --> K["delete all issues"]
    K --> L["re-insert from the JSON"]
    L --> M["report how many were restored"]

    I --> N["nothing was changed"]
```

---

**16. Notifications** - the in-app bell, and the device notification.

```mermaid
flowchart TD
    subgraph IN["In the app - the bell and the list"]
        A["issues[]"] --> B["for each issue"]
        B --> C["new issue reported"]
        B --> D["marked as done"]
        B --> E["high priority, still open"]
        B --> F["message from an admin"]
        C --> G["filter by the user's<br/>notification preferences"]
        D --> G
        E --> G
        F --> G
        G --> H["newest first"]
        H --> I["unread = newer than<br/>notifications_seen_at"]
        I --> J["badge on the bell"]
    end

    subgraph OUT["On the device - a real notification"]
        K["A change made by someone else"] --> L{"how does it arrive?"}
        L -- "connected" --> M["Supabase Realtime"]
        L -- "otherwise" --> N["poll every 15 seconds"]
        M --> O["refresh()"]
        N --> O
        O --> P["compare with what was on screen"]
        P --> Q{"did we cause it?"}
        Q -- "yes" --> R["stay quiet"]
        Q -- "no" --> S{"allowed, and switched on?"}
        S -- "no" --> T["in-app toast instead"]
        S -- "yes" --> U["service worker<br/>showNotification()"]
        U --> V["tapping it brings the app forward"]
    end
```

> The bell is in-app and always works. The device notification needs
> permission, asked for from Settings when the button is pressed.
>
> A notification reaches a **closed** app only from a server holding a push
> subscription. Nothing sends one yet - the service worker's `push` handler is
> in place for when that exists.

---

**17. What the database decides** - the rules that cannot be bypassed.

```mermaid
flowchart TD
    DB["PostgreSQL"]

    DB --> P1["Who can SEE an issue<br/>issues_select_auth"]
    DB --> P2["Who can REPORT, and in whose name<br/>issues_insert_auth"]
    DB --> P3["Who can EDIT<br/>issues_update_admin"]
    DB --> P4["What an edit may change<br/>guard_issue_update"]
    DB --> P5["Who can delete for good<br/>issues_delete_admin"]
    DB --> P6["Who can see or empty the bin<br/>is_admin() re-checked"]
    DB --> P7["Which role a new account gets<br/>handle_new_user"]
    DB --> P8["Whether a role may change<br/>guard_profile_role"]
    DB --> P9["Whether a backup is due<br/>auto_snapshot"]
    DB --> P10["How many snapshots are kept<br/>newest 30"]
```

---

**18. Install and offline.**

```mermaid
flowchart TD
    A["Open the app"] --> B["service worker caches the shell"]
    B --> C{"already installed?"}
    C -- "yes" --> D["no Install button"]
    C -- "no" --> E["Install button always shown"]
    E --> F{"browser offers<br/>beforeinstallprompt?"}
    F -- "yes" --> G["Install, Accept, done"]
    F -- "no, Safari or Firefox" --> H["wait up to 2s, then<br/>explain the manual steps"]

    I["Later, with no network"] --> J["the cached shell still loads"]
    J --> K["database actions fail<br/>with a clear message"]
```

---

**19. Deployment.**

```mermaid
flowchart LR
    A["Your folder<br/>index.html"] --> B["GitHub<br/>syasyaAlya/issueTrackers"]
    B -- "push to main" --> C["Vercel"]
    C --> D["issue-trackers-bay.vercel.app"]

    E["Local copy"] --> F["python -m http.server"]
    F --> G["browser on your machine"]

    H["Demo copy<br/>URL and key blanked"] --> I["automated browser tests"]
```
