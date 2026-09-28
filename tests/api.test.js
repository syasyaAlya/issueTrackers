/* ============================================================================
 *  api.test.js — tests the REST API without touching your real database.
 *
 *  Starts a throwaway PostgreSQL, applies supabase-schema.sql to it, and then
 *  exercises the whole API: keys, both tiers, every endpoint, revoking, and a
 *  webhook. Nothing is installed and nothing is spent - the database lives in
 *  a folder beside this file and is deleted at the end.
 *
 *  Run it:
 *      cd tests
 *      npm install          (once - fetches PostgreSQL itself)
 *      npm test
 *
 *  This is the same set of checks that was used while building the API, so a
 *  green run means the SQL in this repository is sound.
 * ========================================================================= */

const pgMod = require('embedded-postgres');
const EmbeddedPostgres = pgMod.default || pgMod;
const fs = require('fs');
const path = require('path');

const REPO = path.resolve(__dirname, '..');
const SCHEMA = path.join(REPO, 'supabase-schema.sql');
const DATA = path.join(__dirname, '.pgdata');

const ADMIN = 'aaaaaaaa-0000-0000-0000-000000000001';
const USER = 'bbbbbbbb-0000-0000-0000-000000000002';

let pass = 0, fail = 0;
function check(name, ok, extra) {
  if (ok) { pass++; console.log('  \u001b[32mPASS\u001b[0m  ' + name); }
  else { fail++; console.log('  \u001b[31mFAIL\u001b[0m  ' + name + (extra ? '   -> ' + extra : '')); }
}
const section = (t) => console.log('\n' + t);

(async () => {
  if (!fs.existsSync(SCHEMA)) {
    console.log('Could not find supabase-schema.sql next to this folder.');
    process.exit(2);
  }
  if (fs.existsSync(DATA)) fs.rmSync(DATA, { recursive: true, force: true });

  console.log('Starting a throwaway PostgreSQL...');
  const pg = new EmbeddedPostgres({
    databaseDir: DATA, user: 'postgres', password: 'postgres',
    port: 55460, persistent: false, onLog: () => {}, onError: () => {}
  });

  await pg.initialise();
  await pg.start();
  await pg.createDatabase('api');

  const client = pg.getPgClient();
  await client.connect();
  const q = (sql) => client.query(sql);

  const asAnon  = async () => { await q('reset role'); await q(`set "test.uid" = ''`);        await q('set role anon'); };
  const asAdmin = async () => { await q('reset role'); await q(`set "test.uid" = '${ADMIN}'`); await q('set role authenticated'); };
  const asUser  = async () => { await q('reset role'); await q(`set "test.uid" = '${USER}'`);  await q('set role authenticated'); };
  const asSuper = async () => { await q('reset role'); await q(`set "test.uid" = ''`); };

  async function call(fn, args = '') {
    try {
      const r = await q(`select public.${fn}(${args}) as v`);
      return { ok: true, v: r.rows[0].v };
    } catch (e) {
      return { ok: false, error: e.message };
    }
  }

  try {
    section('Setting up a database that has never seen this app');
    await q(`
      create role anon; create role authenticated;
      create schema auth;
      create table auth.users (id uuid primary key, email text,
                               raw_user_meta_data jsonb default '{}'::jsonb);
      create or replace function auth.uid() returns uuid language sql stable as $fn$
        select nullif(current_setting('test.uid', true), '')::uuid $fn$;
      grant usage on schema auth to anon, authenticated;
      grant select on auth.users to anon, authenticated;
    `);

    await q(fs.readFileSync(SCHEMA, 'utf8'));
    check('supabase-schema.sql applies end to end', true);

    await q(`insert into auth.users (id, email, raw_user_meta_data) values
             ('${ADMIN}', 'admin@x.com', '{"role":"admin","full_name":"Admin"}'),
             ('${USER}',  'user@x.com',  '{"role":"user","full_name":"User"}')`);

    section('The API describes itself to anyone');
    await asAnon();
    let r = await call('api_docs');
    check('anon can read api_docs()', r.ok, r.error);
    check('and it lists the endpoints', r.ok && r.v.endpoints.length >= 9, r.ok ? String(r.v.endpoints.length) : '');
    check('and names the two tiers', r.ok && Boolean(r.v.auth.tiers.user && r.v.auth.tiers.admin));

    section('Nothing works without a key');
    for (const [fn, args] of [
      ['api_me', "'itk_nothing'"],
      ['api_list_issues', "'itk_nothing'"],
      ['api_create_issue', "'itk_nothing', 'x'"],
      ['api_stats', "'itk_nothing'"],
      ['api_delete_issue', "'itk_nothing', gen_random_uuid()"]
    ]) {
      r = await call(fn, args);
      check('a bad key is refused on ' + fn, !r.ok && /Invalid or revoked/.test(r.error || ''), r.error || 'it was allowed!');
    }

    section('Only an admin can mint a key');
    await asUser();
    r = await call('create_api_key', "'friend', 'user'");
    check('a normal user cannot create a key', !r.ok && /administrator/i.test(r.error || ''), r.error || 'it was allowed!');

    await asAdmin();
    r = await call('create_api_key', "'friend laptop', 'user'");
    check('an admin can create a user key', r.ok && /^itk_/.test(r.v.key || ''), r.error || JSON.stringify(r.v));
    const userKey = r.ok ? r.v.key : '';

    r = await call('create_api_key', "'ops box', 'admin'");
    check('an admin can create an admin key', r.ok && /^itk_/.test(r.v.key || ''), r.error);
    const adminKey = r.ok ? r.v.key : '';
    const adminKeyId = r.ok ? r.v.id : '';

    check('the key is long enough to be worth hashing', userKey.length >= 40, String(userKey.length));
    const stored = (await q("select key_hash from public.api_keys where role='admin'")).rows[0];
    check('only the hash is stored, never the key itself',
      stored && stored.key_hash !== adminKey && stored.key_hash.length === 64, JSON.stringify(stored));

    section('A user key can read and report');
    r = await call('api_me', `'${userKey}'`);
    check('api_me answers', r.ok && r.v.key.role === 'user', r.error || JSON.stringify(r.v));

    r = await call('api_create_issue', `'${userKey}', 'From the API', 'made by a script', 'high'`);
    check('a user key can report an issue', r.ok, r.error);
    check('and it starts with no status', r.ok && r.v.data.status === 'none', r.ok ? r.v.data.status : '');
    check('and is marked as coming from the API', r.ok && /^api:/.test(r.v.data.created_by_email || ''), r.ok ? r.v.data.created_by_email : '');
    const issueId = r.ok ? r.v.data.id : '';

    r = await call('api_list_issues', `'${userKey}'`);
    check('a user key can list issues', r.ok && r.v.count === 1, r.error || JSON.stringify(r.v && r.v.count));
    check('the response carries count / limit / offset', r.ok && r.v.limit === 50 && r.v.offset === 0);

    r = await call('api_list_issues', `'${userKey}', 'pending', null, null, 10, 0`);
    check('filtering by status works', r.ok && r.v.count === 0, r.error || String(r.v && r.v.count));

    r = await call('api_list_issues', `'${userKey}', null, null, 'script', null, null`);
    check('free text search works', r.ok && r.v.count === 1, r.error || String(r.v && r.v.count));

    r = await call('api_get_issue', `'${userKey}', '${issueId}'`);
    check('a user key can fetch one issue', r.ok && r.v.data.title === 'From the API', r.error);

    r = await call('api_stats', `'${userKey}'`);
    check('a user key can read stats', r.ok && r.v.data.total === 1, r.error || JSON.stringify(r.v && r.v.data));

    section('A user key cannot do admin work');
    r = await call('api_update_issue', `'${userKey}', '${issueId}', 'done'`);
    check('a user key cannot change a status', !r.ok && /admin key/i.test(r.error || ''), r.error || 'it was allowed!');

    r = await call('api_delete_issue', `'${userKey}', '${issueId}'`);
    check('a user key cannot delete', !r.ok && /admin key/i.test(r.error || ''), r.error || 'it was allowed!');

    r = await call('api_list_users', `'${userKey}'`);
    check('a user key cannot list users', !r.ok && /admin key/i.test(r.error || ''), r.error || 'it was allowed!');

    section('An admin key can do everything');
    r = await call('api_update_issue', `'${adminKey}', '${issueId}', 'done', 'low', 'Fixed by the API'`);
    check('an admin key can set status, priority and a message',
      r.ok && r.v.data.status === 'done' && r.v.data.priority === 'low' && r.v.data.admin_note === 'Fixed by the API',
      r.error || JSON.stringify(r.v && r.v.data));

    r = await call('api_list_users', `'${adminKey}'`);
    check('an admin key can list users', r.ok && r.v.data.length === 2, r.error || String(r.v && r.v.data.length));

    r = await call('api_update_issue', `'${adminKey}', '${issueId}', 'nonsense'`);
    check('a bad status is refused', !r.ok && /Status must be/.test(r.error || ''), r.error || 'it was allowed!');

    r = await call('api_delete_issue', `'${adminKey}', gen_random_uuid()`);
    check('deleting something that is not there says so', !r.ok && /No issue with that id/.test(r.error || ''), r.error);

    section('Keys are counted, and can be revoked');
    await asSuper();
    const used = (await q("select request_count from public.api_keys where role='user'")).rows[0].request_count;
    check('using a key counts the calls', Number(used) > 0, String(used));

    await asAdmin();
    r = await call('revoke_api_key', `'${adminKeyId}'`);
    check('an admin can revoke a key', r.ok && r.v === 1, r.error || JSON.stringify(r.v));

    r = await call('api_me', `'${adminKey}'`);
    check('a revoked key is refused', !r.ok && /Invalid or revoked/.test(r.error || ''), r.error || 'it still worked!');

    section('Webhooks');
    await asSuper();
    await q(`insert into public.webhooks (url, events) values ('https://example.com/hook', array['issue.created'])`);

    await asAdmin();
    r = await call('api_create_issue', `'${userKey}', 'Webhook test'`);
    check('creating an issue still works with a webhook registered', r.ok, r.error);

    await asSuper();
    const del = (await q('select event, sent, error from public.webhook_deliveries')).rows;
    check('the webhook attempt was recorded', del.length === 1, 'rows=' + del.length);
    check('it recorded the event name', del[0] && del[0].event === 'issue.created', JSON.stringify(del[0]));
    check('a missing pg_net did not break the write, and was noted',
      del[0] && del[0].sent === false && del[0].error !== '', JSON.stringify(del[0]));

    section('The key table is not readable from outside');
    await asAnon();
    let direct;
    try { await q('select * from public.api_keys'); direct = null; }
    catch (e) { direct = e.message; }
    check('api_keys is closed to anon', direct !== null, 'it was readable!');

  } catch (e) {
    fail++;
    console.log('\n  !! ERROR: ' + e.message);
  } finally {
    await Promise.race([pg.stop().catch(() => {}), new Promise(r => setTimeout(r, 8000))]);
    if (fs.existsSync(DATA)) { try { fs.rmSync(DATA, { recursive: true, force: true }); } catch (e) {} }
  }

  console.log('\n============================================');
  console.log(`  ${pass} passed, ${fail} failed`);
  console.log('============================================');
  process.exit(fail ? 1 : 0);
})();
