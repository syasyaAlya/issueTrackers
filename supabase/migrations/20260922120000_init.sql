-- =====================================================================
--  ISSUE TRACKER — SUPABASE DATABASE SCHEMA
--  ---------------------------------------------------------------------
--  This is the Supabase CLI migration. It is the same schema as
--  ../supabase-schema.sql and the SQL embedded in index.html — if you
--  change one, change all three.
--
--  CLI:      supabase link --project-ref <ref> && supabase db push
--  Or paste ../supabase-schema.sql (or this file) into the SQL Editor.
--
--  Safe to run more than once.
-- =====================================================================

-- Needed for gen_random_uuid()
create extension if not exists "pgcrypto";


-- =====================================================================
--  1. PROFILES — one row per user, holds the ROLE
-- =====================================================================
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  email      text        not null,
  full_name  text        not null default '',
  role       text        not null default 'user' check (role in ('admin','user')),
  created_at timestamptz not null default now()
);

-- Extra profile fields. "add column if not exists" means this also upgrades
-- a database that was created before these columns existed.
alter table public.profiles add column if not exists avatar_url           text        not null default '';
alter table public.profiles add column if not exists notify_new_issue     boolean     not null default true;
alter table public.profiles add column if not exists notify_status_done   boolean     not null default true;
alter table public.profiles add column if not exists notify_high_priority boolean     not null default true;
alter table public.profiles add column if not exists notifications_seen_at timestamptz not null default 'epoch';


-- =====================================================================
--  2. ISSUES — the actual tracker records
-- =====================================================================
create table if not exists public.issues (
  id               uuid primary key default gen_random_uuid(),
  title            text        not null,
  description      text        not null default '',
  status           text        not null default 'none',
  priority         text        not null default 'medium' check (priority in ('low','medium','high')),
  created_by       uuid        default auth.uid() references auth.users(id) on delete set null,
  created_by_email text        not null default '',
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

-- Status values. 'none' means no status has been set yet.
-- This replaces the older two-value constraint, so it also upgrades an
-- existing database — run it even if the table is already there.
alter table public.issues drop constraint if exists issues_status_check;
alter table public.issues add constraint issues_status_check
  check (status in ('none','pending','done'));

-- New issues start with no status: a normal user reports it and an
-- administrator moves it through Pending / Done.
alter table public.issues alter column status set default 'none';

-- Deleting a user keeps their issues on the board: the reporter link is
-- cleared instead of the issues being removed. (Older databases used
-- ON DELETE CASCADE, which would have destroyed them.)
alter table public.issues alter column created_by drop not null;
alter table public.issues drop constraint if exists issues_created_by_fkey;
alter table public.issues add constraint issues_created_by_fkey
  foreign key (created_by) references auth.users(id) on delete set null;

-- A message an administrator can leave for the reporter after fixing an
-- issue. Empty by default, so this is safe to add to an existing database.
alter table public.issues add column if not exists admin_note    text        not null default '';
alter table public.issues add column if not exists admin_note_at timestamptz not null default 'epoch';

create index if not exists issues_status_idx     on public.issues (status);
create index if not exists issues_created_by_idx on public.issues (created_by);
create index if not exists issues_updated_at_idx on public.issues (updated_at desc);


-- =====================================================================
--  3. HELPERS
-- =====================================================================
-- Is the current user an admin?
-- SECURITY DEFINER so it can read profiles without tripping RLS
-- (which would otherwise cause infinite recursion in the policies).
create or replace function public.is_admin()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = 'admin'
  );
$$;

-- Keep updated_at fresh automatically.
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- A normal user may ONLY change an issue's status.
-- Admins may change anything. Enforced in the database itself, so a
-- crafted request from the browser cannot bypass it.
create or replace function public.guard_issue_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.is_admin() then
    return new;
  end if;

  -- Non-admins may change ONLY the status column. Editing the title,
  -- description, priority or reporter is rejected by the database.
  if new.title         is distinct from old.title
     or new.description is distinct from old.description
     or new.priority    is distinct from old.priority
     or new.created_by  is distinct from old.created_by then
    raise exception 'Only an administrator can edit issue details.';
  end if;

  return new;
end;
$$;

drop trigger if exists issues_touch_updated_at on public.issues;
create trigger issues_touch_updated_at
  before update on public.issues
  for each row execute function public.touch_updated_at();

drop trigger if exists issues_guard_update on public.issues;
create trigger issues_guard_update
  before update on public.issues
  for each row execute function public.guard_issue_update();


-- =====================================================================
--  4. AUTO-CREATE A PROFILE WHEN SOMEONE SIGNS UP
--     The role chosen on the register form arrives in user metadata.
-- =====================================================================
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, full_name, role)
  values (
    new.id,
    coalesce(new.email, ''),
    coalesce(new.raw_user_meta_data->>'full_name', ''),
    case when new.raw_user_meta_data->>'role' = 'admin' then 'admin' else 'user' end
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();


-- =====================================================================
--  4b. ONLY ADMINISTRATORS MAY CHANGE ROLES
--      profiles_update_self lets a user touch their own row (their
--      display name). This trigger stops that being used to promote
--      themselves to admin.
-- =====================================================================
create or replace function public.guard_profile_role()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.role is distinct from old.role and not public.is_admin() then
    raise exception 'Only an administrator can change roles.';
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_guard_role on public.profiles;
create trigger profiles_guard_role
  before update on public.profiles
  for each row execute function public.guard_profile_role();


-- =====================================================================
--  ADMINS CAN DELETE A USER
--  Deleting the auth.users row also removes the matching profile row
--  (ON DELETE CASCADE on profiles.id) while the user's issues stay on
--  the board, because issues.created_by is now ON DELETE SET NULL.
--  SECURITY DEFINER is what lets this reach the auth schema; the admin
--  check inside is what keeps it safe to expose over the public API.
-- =====================================================================
create or replace function public.admin_delete_user(target uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Only an administrator can delete users.';
  end if;
  if target = auth.uid() then
    raise exception 'You cannot delete your own account.';
  end if;
  -- Detach their issues first, so they survive even on a database that
  -- still has the older ON DELETE CASCADE constraint.
  update public.issues set created_by = null where created_by = target;
  delete from auth.users where id = target;
end;
$$;

revoke all on function public.admin_delete_user(uuid) from public;
grant execute on function public.admin_delete_user(uuid) to authenticated;


-- =====================================================================
--  5. ROW LEVEL SECURITY
-- =====================================================================
alter table public.profiles enable row level security;
alter table public.issues   enable row level security;

-- ---------- profiles ----------
drop policy if exists profiles_select_self   on public.profiles;
drop policy if exists profiles_select_admin  on public.profiles;
drop policy if exists profiles_insert_self   on public.profiles;
drop policy if exists profiles_update_self   on public.profiles;
drop policy if exists profiles_update_admin  on public.profiles;
drop policy if exists profiles_delete_admin  on public.profiles;

create policy profiles_select_self on public.profiles
  for select using (id = auth.uid());

create policy profiles_select_admin on public.profiles
  for select using (public.is_admin());

-- A user creates their own profile row (fallback if the trigger is absent).
create policy profiles_insert_self on public.profiles
  for insert with check (id = auth.uid());

-- A user may fix their own display name...
create policy profiles_update_self on public.profiles
  for update using (id = auth.uid()) with check (id = auth.uid());

-- ...but only an admin may change roles (their own or anyone's).
create policy profiles_update_admin on public.profiles
  for update using (public.is_admin());

create policy profiles_delete_admin on public.profiles
  for delete using (public.is_admin());

-- ---------- issues ----------
drop policy if exists issues_select_auth     on public.issues;
drop policy if exists issues_insert_auth     on public.issues;
drop policy if exists issues_update_admin    on public.issues;
drop policy if exists issues_update_own      on public.issues;
drop policy if exists issues_delete_admin    on public.issues;

-- Any signed-in user sees the whole board.
create policy issues_select_auth on public.issues
  for select using (auth.uid() is not null);

-- Any signed-in user can report an issue as themselves.
create policy issues_insert_auth on public.issues
  for insert with check (auth.uid() = created_by);

-- Admins can update anything.
create policy issues_update_admin on public.issues
  for update using (public.is_admin());

-- Normal users cannot update issues at all. They report them with the
-- status "None", and an administrator moves them through Pending / Done.
-- (guard_issue_update stays as a second line of defence.)

-- Only admins can delete.
create policy issues_delete_admin on public.issues
  for delete using (public.is_admin());


-- =====================================================================
--  6. OPTIONAL — make yourself the first admin
--     After you register in the app, run this with your own email:
--
--     update public.profiles set role = 'admin'
--     where email = 'you@example.com';
-- =====================================================================


-- ============================================================================
--  GRANTS
--    Supabase grants table privileges to anon / authenticated by default, so
--    the earlier sections never needed to say so. Stating them here keeps this
--    schema self-sufficient: it can be run on a plain PostgreSQL and still
--    work, which is exactly how it is tested.
-- ============================================================================
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on public.profiles to authenticated;
grant select, insert, update, delete on public.issues   to authenticated;


-- ============================================================================
--  AUTOMATIC BACKUPS
-- ----------------------------------------------------------------------------
--  WHY THE DATABASE DOES IT
--    A browser cannot reliably write a backup in the background. A trigger
--    can, so the snapshotting lives here, and it works with nobody watching.
--
--  WHAT IT ADDS
--    * public.backups       one row per snapshot: the whole issues table as
--                           JSON, so a restore is exact
--    * public.app_settings  a single row holding the admin on/off switch
--    * auto_snapshot()      one place that decides whether a backup is due
--    * create_backup()      admin: back up now
--    * restore_backup()     admin: put it back
--    * a trigger on issues  backs up on any change, at most once an hour
--    * an optional nightly pg_cron job for quiet days
-- ============================================================================

create table if not exists public.app_settings (
  id                  boolean primary key default true check (id),
  auto_backup_enabled boolean not null default true,
  updated_at          timestamptz not null default now()
);

insert into public.app_settings (id) values (true) on conflict (id) do nothing;

alter table public.app_settings enable row level security;

drop policy if exists "admins read settings" on public.app_settings;
create policy "admins read settings"
  on public.app_settings for select
  to authenticated
  using (public.is_admin());

drop policy if exists "admins change settings" on public.app_settings;
create policy "admins change settings"
  on public.app_settings for update
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

grant select, update on public.app_settings to authenticated;


create table if not exists public.backups (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  kind        text not null default 'auto' check (kind in ('auto','manual')),
  issue_count integer not null default 0,
  payload     jsonb not null default '[]'::jsonb
);

create index if not exists backups_created_at_idx on public.backups (created_at desc);

alter table public.backups enable row level security;

-- Take a snapshot. Internal: the browser must never reach this directly, or a
-- reporter could fill the table.
create or replace function public.snapshot_issues(p_kind text default 'auto')
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_id uuid;
  n_keep integer := 30;      -- how many snapshots to keep
begin
  insert into public.backups (kind, issue_count, payload)
  select
    case when p_kind = 'manual' then 'manual' else 'auto' end,
    count(*),
    coalesce(jsonb_agg(to_jsonb(i) order by i.created_at), '[]'::jsonb)
  from public.issues i
  returning id into new_id;

  -- Retention: drop everything past the newest n_keep.
  delete from public.backups
  where id in (
    select id from public.backups order by created_at desc offset n_keep
  );

  return new_id;
end;
$$;

revoke all on function public.snapshot_issues(text) from public;

-- Is a backup due? One place, so the trigger and the nightly job cannot drift.
create or replace function public.auto_snapshot()
returns uuid
language plpgsql
security definer
set search_path = public
as $$
begin
  if not coalesce((select auto_backup_enabled from public.app_settings limit 1), true) then
    return null;                       -- switched off by an admin
  end if;

  if exists (
    select 1 from public.backups
    where kind = 'auto' and created_at > now() - interval '1 hour'
  ) then
    return null;                       -- already took one this hour
  end if;

  return public.snapshot_issues('auto');
end;
$$;

revoke all on function public.auto_snapshot() from public;

create or replace function public.auto_backup_on_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.auto_snapshot();
  return null;
end;
$$;

drop trigger if exists issues_auto_backup on public.issues;
create trigger issues_auto_backup
  after insert or update or delete on public.issues
  for each statement execute function public.auto_backup_on_change();


-- "Back up now"
create or replace function public.create_backup()
returns uuid
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Only an administrator can create a backup'
      using errcode = '42501';
  end if;
  return public.snapshot_issues('manual');
end;
$$;

revoke all on function public.create_backup() from public;
grant execute on function public.create_backup() to authenticated;


-- "Put it back": replaces the issues with the snapshot.
-- Takes a safety snapshot first, so a restore can itself be undone.
create or replace function public.restore_backup(p_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n_restored integer := 0;
  n_total    integer := 0;
  n_usable   integer := 0;
begin
  if not public.is_admin() then
    raise exception 'Only an administrator can restore a backup'
      using errcode = '42501';
  end if;

  if not exists (select 1 from public.backups where id = p_id) then
    raise exception 'That backup no longer exists';
  end if;

  select jsonb_array_length(payload) into n_total
  from public.backups where id = p_id;

  select count(*) into n_usable
  from jsonb_array_elements((select payload from public.backups where id = p_id)) as elem
  where exists (
    select 1 from auth.users u where u.id = (elem ->> 'created_by')::uuid
  );

  -- Guard against a silent wipe: a snapshot that names issues, but whose
  -- reporters have all been deleted, would otherwise clear the whole board
  -- and report "0 restored".
  if n_total > 0 and n_usable = 0 then
    raise exception 'This backup only references accounts that no longer exist, so restoring it would empty the board. Nothing was changed.';
  end if;

  -- Safety net: never let a restore destroy the only copy.
  perform public.snapshot_issues('auto');

  delete from public.issues;

  -- Column-agnostic on purpose: jsonb_populate_record maps the stored JSON
  -- straight back onto the table, so a snapshot restores correctly whether it
  -- was taken before or after a column was added.
  insert into public.issues
  select r2.*
  from jsonb_array_elements(
         (select payload from public.backups where id = p_id)
       ) as elem
  cross join lateral jsonb_populate_record(null::public.issues, elem) as r2
  where exists (
    select 1 from auth.users u where u.id = (elem ->> 'created_by')::uuid
  );

  get diagnostics n_restored = row_count;
  return n_restored;
end;
$$;

revoke all on function public.restore_backup(uuid) from public;
grant execute on function public.restore_backup(uuid) to authenticated;


drop policy if exists "admins read backups" on public.backups;
create policy "admins read backups"
  on public.backups for select
  to authenticated
  using (public.is_admin());

drop policy if exists "admins delete backups" on public.backups;
create policy "admins delete backups"
  on public.backups for delete
  to authenticated
  using (public.is_admin());

grant select, delete on public.backups to authenticated;


-- ============================================================================
--  OPTIONAL — A NIGHTLY BACKUP ON QUIET DAYS
--    The trigger only fires when something changes. pg_cron must be enabled
--    once in the dashboard (Database -> Extensions -> pg_cron). If it is not,
--    this block does nothing and the trigger still covers you.
-- ============================================================================
do $$
begin
  begin
    create extension if not exists pg_cron;
  exception when others then null;
  end;

  begin
    perform cron.unschedule('issue-tracker-auto-backup');
  exception when others then null;
  end;

  begin
    perform cron.schedule(
      'issue-tracker-auto-backup',
      '0 2 * * *',
      $job$select public.auto_snapshot()$job$
    );
  exception when others then null;
  end;
end $$;


-- ============================================================================
--  Realtime: send the whole old row on update and delete.
--  Without this an update event cannot say what the status WAS, and a delete
--  event arrives with no title. Costs a little more write-ahead log per
--  update, which is nothing at this size.
-- ============================================================================
alter table public.issues replica identity full;


-- ============================================================================
--  Realtime: let the browser subscribe to changes on issues, so the board and
--  the notification bell update on their own instead of waiting for a reload.
--  Guarded twice over: a plain PostgreSQL has no supabase_realtime publication,
--  and adding the same table to it twice is an error.
-- ============================================================================
do $$
begin
  begin
    alter publication supabase_realtime add table public.issues;
  exception when others then null;
  end;
end $$;


-- ============================================================================
--  TELL PostgREST TO RE-READ THE SCHEMA.
--  PostgREST caches the shape of the database. A function created moments ago
--  can stay invisible to the API until that cache refreshes, and then every
--  call to it fails with:
--      Could not find the function public.<name>() in the schema cache
--  Supabase usually reloads on its own, but not always and not instantly.
--  This one line makes it immediate. Harmless elsewhere: it is only a
--  notification, and nothing is listening on a plain PostgreSQL.
-- ============================================================================
-- ============================================================================
--  REST API  —  keys, endpoints and webhooks
-- ----------------------------------------------------------------------------
--  Other systems talk to this app over HTTPS, with an API key, instead of
--  signing in as a person.
--
--  WHY IT LIVES HERE AND NOT ON A SERVER
--    There is no server to run. Each endpoint is a database function, called
--    through PostgREST, which Supabase already exposes:
--
--      POST https://<project>.supabase.co/rest/v1/rpc/api_list_issues
--      apikey: <anon key>
--      { "p_key": "itk_...", "p_status": "pending" }
--
--    That means no service-role key is needed anywhere, nothing has to be
--    deployed, and a call costs one round trip to the database that already
--    holds the data.
--
--  KEYS
--    * two tiers: 'user' (read and report) and 'admin' (everything)
--    * the key is shown once, when it is created, and never stored - only its
--      SHA-256 hash is kept, so a database leak does not hand out working keys
--    * every call stamps last_used_at and bumps request_count
--
--  WEBHOOKS
--    A registered URL is called when an issue changes. Delivery needs the
--    pg_net extension; without it the trigger still records what it would
--    have sent, so nothing is lost and the app keeps working.
-- ============================================================================

create extension if not exists "pgcrypto";


-- ----------------------------------------------------------------------------
--  The keys themselves
-- ----------------------------------------------------------------------------
create table if not exists public.api_keys (
  id               uuid primary key default gen_random_uuid(),
  name             text        not null default '',
  prefix           text        not null default '',
  key_hash         text        not null,
  role             text        not null default 'user' check (role in ('user','admin')),
  created_by       uuid        references auth.users(id) on delete set null,
  created_by_email text        not null default '',
  created_at       timestamptz not null default now(),
  revoked_at       timestamptz,
  last_used_at     timestamptz,
  request_count    bigint      not null default 0
);

create unique index if not exists api_keys_hash_idx    on public.api_keys (key_hash);
create index        if not exists api_keys_created_idx on public.api_keys (created_at desc);

alter table public.api_keys enable row level security;

drop policy if exists "admins read keys"   on public.api_keys;
create policy "admins read keys"
  on public.api_keys for select to authenticated
  using (public.is_admin());

drop policy if exists "admins delete keys" on public.api_keys;
create policy "admins delete keys"
  on public.api_keys for delete to authenticated
  using (public.is_admin());

grant select, delete on public.api_keys to authenticated;


-- ----------------------------------------------------------------------------
--  Is this key good, and what may it do?
-- ----------------------------------------------------------------------------
create or replace function public.api_role(p_key text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
  v_id   uuid;
begin
  if p_key is null or length(p_key) < 12 then
    return null;                       -- obviously not a key; do not even look
  end if;

  select k.role, k.id into v_role, v_id
  from public.api_keys k
  where k.key_hash = encode(digest(p_key, 'sha256'), 'hex')
    and k.revoked_at is null;

  if v_id is null then
    return null;
  end if;

  -- Cheap bookkeeping: who is using which key, and how much.
  update public.api_keys
     set last_used_at = now(),
         request_count = request_count + 1
   where id = v_id;

  return v_role;
end;
$$;

revoke all on function public.api_role(text) from public;


/* Every endpoint starts with this. Fails closed: no key, or not enough
   permission, raises before any data is touched. */
create or replace function public.api_check(p_key text, p_need_admin boolean default false)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
begin
  v_role := public.api_role(p_key);

  if v_role is null then
    raise exception 'Invalid or revoked API key'
      using errcode = '28000', hint = 'Send it in the request body as p_key.';
  end if;

  if p_need_admin and v_role <> 'admin' then
    raise exception 'This endpoint needs an admin key'
      using errcode = '42501';
  end if;

  return v_role;
end;
$$;

revoke all on function public.api_check(text, boolean) from public;


-- ----------------------------------------------------------------------------
--  Managing keys (from the app, where the person is signed in as an admin)
-- ----------------------------------------------------------------------------
create or replace function public.create_api_key(p_name text default '', p_role text default 'user')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key  text;
  v_id   uuid;
  v_name text;
begin
  if not public.is_admin() then
    raise exception 'Only an administrator can create API keys' using errcode = '42501';
  end if;

  if p_role not in ('user', 'admin') then
    raise exception 'A key is either a user key or an admin key';
  end if;

  v_name := coalesce(nullif(trim(coalesce(p_name, '')), ''), 'Untitled key');
  v_key  := 'itk_' || encode(gen_random_bytes(24), 'hex');

  insert into public.api_keys (name, prefix, key_hash, role, created_by, created_by_email)
  values (
    v_name,
    left(v_key, 12),
    encode(digest(v_key, 'sha256'), 'hex'),
    p_role,
    auth.uid(),
    coalesce((select email from public.profiles where id = auth.uid()), '')
  )
  returning id into v_id;

  -- The plaintext key is returned exactly once. It is not stored anywhere.
  return jsonb_build_object(
    'id', v_id,
    'name', v_name,
    'role', p_role,
    'key', v_key,
    'prefix', left(v_key, 12)
  );
end;
$$;

revoke all on function public.create_api_key(text, text) from public;
grant execute on function public.create_api_key(text, text) to authenticated;


create or replace function public.revoke_api_key(p_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n integer := 0;
begin
  if not public.is_admin() then
    raise exception 'Only an administrator can revoke API keys' using errcode = '42501';
  end if;

  update public.api_keys
     set revoked_at = now()
   where id = p_id and revoked_at is null;

  get diagnostics n = row_count;
  return n;
end;
$$;

revoke all on function public.revoke_api_key(uuid) from public;
grant execute on function public.revoke_api_key(uuid) to authenticated;


-- ----------------------------------------------------------------------------
--  WEBHOOKS
-- ----------------------------------------------------------------------------
create table if not exists public.webhooks (
  id         uuid primary key default gen_random_uuid(),
  url        text        not null,
  secret     text        not null default encode(gen_random_bytes(16), 'hex'),
  events     text[]      not null default array['issue.created','issue.updated','issue.deleted'],
  active     boolean     not null default true,
  created_by uuid        references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.webhook_deliveries (
  id         bigserial primary key,
  webhook_id uuid        references public.webhooks(id) on delete cascade,
  event      text        not null,
  payload    jsonb       not null default '{}'::jsonb,
  sent       boolean     not null default false,
  error      text        not null default '',
  created_at timestamptz not null default now()
);

create index if not exists webhook_deliveries_at_idx on public.webhook_deliveries (created_at desc);

alter table public.webhooks           enable row level security;
alter table public.webhook_deliveries enable row level security;

drop policy if exists "admins read webhooks" on public.webhooks;
create policy "admins read webhooks"
  on public.webhooks for select to authenticated
  using (public.is_admin());

drop policy if exists "admins write webhooks" on public.webhooks;
create policy "admins write webhooks"
  on public.webhooks for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists "admins read deliveries" on public.webhook_deliveries;
create policy "admins read deliveries"
  on public.webhook_deliveries for select to authenticated
  using (public.is_admin());

grant select, insert, update, delete on public.webhooks to authenticated;
grant select on public.webhook_deliveries to authenticated;


/* Fires on every change to an issue, for every active webhook that asked for
   that event. Delivery uses pg_net where it exists; where it does not, the
   attempt is still recorded, so nothing disappears silently and - importantly
   - a missing extension can never break a write. */
create or replace function public.webhook_on_issue()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event   text;
  v_payload jsonb;
  v_ok      boolean;
  v_err     text;
  w         record;
begin
  v_event := case tg_op
               when 'INSERT' then 'issue.created'
               when 'UPDATE' then 'issue.updated'
               else               'issue.deleted'
             end;

  v_payload := jsonb_build_object(
    'event', v_event,
    'at',    now(),
    'data',  coalesce(to_jsonb(new), to_jsonb(old))
  );

  for w in select * from public.webhooks
            where active and v_event = any(events)
  loop
    v_ok := false;
    v_err := '';

    begin
      perform net.http_post(
        w.url,
        v_payload,
        '{}'::jsonb,
        jsonb_build_object(
          'Content-Type',      'application/json',
          'X-Webhook-Event',   v_event,
          'X-Webhook-Secret',  w.secret
        )
      );
      v_ok := true;
    exception when others then
      v_err := sqlerrm;                       -- pg_net absent, or a bad URL
    end;

    insert into public.webhook_deliveries (webhook_id, event, payload, sent, error)
    values (w.id, v_event, v_payload, v_ok, v_err);
  end loop;

  return null;
end;
$$;

drop trigger if exists issues_webhook on public.issues;
create trigger issues_webhook
  after insert or update or delete on public.issues
  for each row execute function public.webhook_on_issue();


-- Best effort at pg_net. Supabase ships it; a plain PostgreSQL does not, and
-- the guarded trigger above already copes with that.
do $$
begin
  begin
    create extension if not exists pg_net;
  exception when others then null;
  end;
end $$;


-- ----------------------------------------------------------------------------
--  THE ENDPOINTS
--  All of them take the key as p_key, check it, and answer with JSON.
-- ----------------------------------------------------------------------------
create or replace function public.api_me(p_key text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  k record;
begin
  perform public.api_check(p_key);

  select name, prefix, role, created_at, last_used_at, request_count
    into k
  from public.api_keys
  where key_hash = encode(digest(p_key, 'sha256'), 'hex')
    and revoked_at is null;

  return jsonb_build_object(
    'ok', true,
    'key', jsonb_build_object(
      'name', k.name, 'prefix', k.prefix, 'role', k.role,
      'created_at', k.created_at, 'requests', k.request_count
    )
  );
end;
$$;


create or replace function public.api_list_issues(
  p_key      text,
  p_status   text    default null,
  p_priority text    default null,
  p_q        text    default null,
  p_limit    integer default 50,
  p_offset   integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_limit  integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_q      text    := nullif(lower(trim(coalesce(p_q, ''))), '');
  v_total  integer;
  v_data   jsonb;
begin
  perform public.api_check(p_key);

  select count(*) into v_total
  from public.issues i
  where (p_status   is null or i.status   = p_status)
    and (p_priority is null or i.priority = p_priority)
    and (v_q is null or lower(i.title || ' ' || i.description || ' ' || i.created_by_email) like '%' || v_q || '%');

  select coalesce(jsonb_agg(to_jsonb(x) order by x.updated_at desc), '[]'::jsonb)
    into v_data
  from (
    select i.id, i.title, i.description, i.status, i.priority,
           i.created_by_email, i.created_at, i.updated_at
    from public.issues i
    where (p_status   is null or i.status   = p_status)
      and (p_priority is null or i.priority = p_priority)
      and (v_q is null or lower(i.title || ' ' || i.description || ' ' || i.created_by_email) like '%' || v_q || '%')
    order by i.updated_at desc
    limit v_limit offset v_offset
  ) x;

  return jsonb_build_object(
    'ok', true,
    'count', v_total,
    'limit', v_limit,
    'offset', v_offset,
    'data', v_data
  );
end;
$$;


create or replace function public.api_get_issue(p_key text, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb;
begin
  perform public.api_check(p_key);

  select to_jsonb(x) into v
  from (
    select id, title, description, status, priority,
           created_by_email, created_at, updated_at
    from public.issues where id = p_id
  ) x;

  if v is null then
    raise exception 'No issue with that id' using errcode = 'P0002';
  end if;

  return jsonb_build_object('ok', true, 'data', v);
end;
$$;


create or replace function public.api_create_issue(
  p_key         text,
  p_title       text,
  p_description text default '',
  p_priority    text default 'medium'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_title text := trim(coalesce(p_title, ''));
  v_role  text;
  v_name  text;
  v_row   jsonb;
begin
  v_role := public.api_check(p_key);

  if v_title = '' then
    raise exception 'A title is required' using errcode = '22023';
  end if;
  if coalesce(p_priority, 'medium') not in ('low', 'medium', 'high') then
    raise exception 'Priority must be low, medium or high' using errcode = '22023';
  end if;

  select name into v_name from public.api_keys
   where key_hash = encode(digest(p_key, 'sha256'), 'hex');

  insert into public.issues (title, description, status, priority, created_by, created_by_email)
  values (
    v_title,
    coalesce(p_description, ''),
    'none',                              -- the API never sets a status
    coalesce(p_priority, 'medium'),
    null,
    'api:' || coalesce(v_name, 'key')
  )
  returning jsonb_build_object(
    'id', id, 'title', title, 'description', description,
    'status', status, 'priority', priority,
    'created_by_email', created_by_email,
    'created_at', created_at, 'updated_at', updated_at
  ) into v_row;

  return jsonb_build_object('ok', true, 'data', v_row);
end;
$$;


create or replace function public.api_update_issue(
  p_key      text,
  p_id       uuid,
  p_status   text    default null,
  p_priority text    default null,
  p_note     text    default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb;
begin
  perform public.api_check(p_key, true);        -- admin only

  if p_status is not null and p_status not in ('none', 'pending', 'done') then
    raise exception 'Status must be none, pending or done' using errcode = '22023';
  end if;
  if p_priority is not null and p_priority not in ('low', 'medium', 'high') then
    raise exception 'Priority must be low, medium or high' using errcode = '22023';
  end if;

  update public.issues
     set status     = coalesce(p_status,   status),
         priority   = coalesce(p_priority, priority),
         admin_note = coalesce(p_note,     admin_note),
         admin_note_at = case when p_note is null then admin_note_at else now() end
   where id = p_id;

  if not found then
    raise exception 'No issue with that id' using errcode = 'P0002';
  end if;

  select to_jsonb(x) into v
  from (
    select id, title, description, status, priority,
           created_by_email, admin_note, created_at, updated_at
    from public.issues where id = p_id
  ) x;

  return jsonb_build_object('ok', true, 'data', v);
end;
$$;


create or replace function public.api_delete_issue(p_key text, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  n integer := 0;
begin
  perform public.api_check(p_key, true);        -- admin only

  delete from public.issues where id = p_id;
  get diagnostics n = row_count;

  if n = 0 then
    raise exception 'No issue with that id' using errcode = 'P0002';
  end if;

  return jsonb_build_object('ok', true, 'deleted', n);
end;
$$;


create or replace function public.api_stats(p_key text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.api_check(p_key);

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'total',   (select count(*) from public.issues),
    'none',    (select count(*) from public.issues where status = 'none'),
    'pending', (select count(*) from public.issues where status = 'pending'),
    'done',    (select count(*) from public.issues where status = 'done'),
    'high',    (select count(*) from public.issues where priority = 'high' and status <> 'done'),
    'users',   (select count(*) from public.profiles)
  ));
end;
$$;


create or replace function public.api_list_users(p_key text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb;
begin
  perform public.api_check(p_key, true);        -- admin only

  select coalesce(jsonb_agg(to_jsonb(x) order by x.email), '[]'::jsonb) into v
  from (select id, email, full_name, role, created_at from public.profiles) x;

  return jsonb_build_object('ok', true, 'data', v);
end;
$$;


-- ----------------------------------------------------------------------------
--  The API describes itself, so the console page never drifts from the code
-- ----------------------------------------------------------------------------
create or replace function public.api_docs()
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'name', 'Issue Tracker API',
    'version', '1',
    'base', 'POST https://<project>.supabase.co/rest/v1/rpc/<endpoint>',
    'auth', jsonb_build_object(
      'header', 'apikey: <anon key>  and  Authorization: Bearer <api key>',
      'or', 'send the key in the body as p_key',
      'tiers', jsonb_build_object(
        'user',  'read issues, read stats, create issues',
        'admin', 'everything, including update, delete and listing users'
      )
    ),
    'endpoints', jsonb_build_array(
      jsonb_build_object('name','api_me',            'tier','user',  'about','Who is this key, and what has it done?'),
      jsonb_build_object('name','api_list_issues',   'tier','user',  'about','List issues. p_status, p_priority, p_q, p_limit, p_offset'),
      jsonb_build_object('name','api_get_issue',     'tier','user',  'about','One issue by id'),
      jsonb_build_object('name','api_create_issue',  'tier','user',  'about','Report an issue. It starts with no status'),
      jsonb_build_object('name','api_stats',         'tier','user',  'about','Counts by status and priority'),
      jsonb_build_object('name','api_update_issue',  'tier','admin', 'about','Set status, priority or a message'),
      jsonb_build_object('name','api_delete_issue',  'tier','admin', 'about','Delete an issue for good'),
      jsonb_build_object('name','api_list_users',    'tier','admin', 'about','Everyone with an account'),
      jsonb_build_object('name','api_docs',          'tier','none',  'about','This document')
    )
  );
$$;


-- ----------------------------------------------------------------------------
--  Grants: the API is reached with the public anon key, so anon may call it.
--  The key check inside each function is what actually protects the data.
-- ----------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'api_role(text)',
    'api_check(text, boolean)',
    'api_me(text)',
    'api_list_issues(text, text, text, text, integer, integer)',
    'api_get_issue(text, uuid)',
    'api_create_issue(text, text, text, text)',
    'api_update_issue(text, uuid, text, text, text)',
    'api_delete_issue(text, uuid)',
    'api_stats(text)',
    'api_list_users(text)',
    'api_docs()'
  ]
  loop
    begin
      execute format('revoke all on function public.%s from public', f);
    exception when others then null;
    end;
  end loop;
end $$;

grant execute on function public.api_me(text)                                      to anon, authenticated;
grant execute on function public.api_list_issues(text, text, text, text, integer, integer) to anon, authenticated;
grant execute on function public.api_get_issue(text, uuid)                         to anon, authenticated;
grant execute on function public.api_create_issue(text, text, text, text)          to anon, authenticated;
grant execute on function public.api_stats(text)                                   to anon, authenticated;
grant execute on function public.api_update_issue(text, uuid, text, text, text)    to anon, authenticated;
grant execute on function public.api_delete_issue(text, uuid)                      to anon, authenticated;
grant execute on function public.api_list_users(text)                              to anon, authenticated;
grant execute on function public.api_docs()                                        to anon, authenticated;


notify pgrst, 'reload schema';
