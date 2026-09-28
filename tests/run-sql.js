/* ============================================================================
 *  run-sql.js — applies supabase-schema.sql to a database you name.
 *
 *  Use it when the Supabase CLI is not logged in and you have no access token:
 *  all this needs is the database connection string, which is on the Supabase
 *  dashboard under  Project settings > Database > Connection string > URI.
 *
 *  Run it:
 *      node run-sql.js "postgresql://postgres:PASSWORD@db.<ref>.supabase.co:5432/postgres"
 *
 *  It prints what it finds before and after, so you can see it worked.
 * ========================================================================= */

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { Client } = require('pg');

const SCHEMA = path.resolve(__dirname, '..', 'supabase-schema.sql');
const args = process.argv.slice(2);
const WANT_KEYS = args.includes('--create-keys');
const url = args.find(a => !a.startsWith('--')) || process.env.DATABASE_URL;

function say(msg) { console.log(msg); }
function ok(msg) { console.log('  PASS  ' + msg); }
function bad(msg) { console.log('  FAIL  ' + msg); }

(async () => {
  if (!url) {
    say('');
    say('Give me a connection string:');
    say('');
    say('    node run-sql.js "postgresql://postgres:PASSWORD@db.<ref>.supabase.co:5432/postgres"');
    say('');
    say('You will find it in Supabase under');
    say('    Project settings > Database > Connection string > URI');
    say('');
    say('Use the "Session pooler" one if the direct connection is not reachable');
    say('from here; both work.');
    say('');
    process.exit(2);
  }

  if (!fs.existsSync(SCHEMA)) {
    bad('Could not find supabase-schema.sql next to this folder.');
    process.exit(2);
  }
  const sql = fs.readFileSync(SCHEMA, 'utf8');

  // Never print the password back out.
  const safe = url.replace(/:\/\/([^:]+):[^@]+@/, '://$1:****@');
  say('');
  say('==============================================');
  say('  Applying the schema');
  say('==============================================');
  say('  database : ' + safe);
  say('  schema   : ' + (sql.length / 1024).toFixed(1) + ' KB');
  say('');

  const client = new Client({
    connectionString: url,
    ssl: /supabase|amazonaws|neon|render/i.test(url) ? { rejectUnauthorized: false } : undefined,
    connectionTimeoutMillis: 20000
  });

  let before = null;

  try {
    say('Connecting...');
    await client.connect();
    ok('connected');
  } catch (e) {
    bad('could not connect: ' + e.message);
    say('');
    say('  Things worth checking:');
    say('    * the password is the DATABASE password, not your account password');
    say('    * if it says "tenant or user not found", try the Session pooler string');
    say('    * your network may block port 5432; the pooler uses 6543');
    say('');
    process.exit(1);
  }

  try {
    // what is there now
    const q = async (text) => (await client.query(text)).rows;
    const one = async (text) => (await q(text))[0].v;

    before = {
      issues: await one("select count(*)::int v from information_schema.tables where table_schema='public' and table_name='issues'"),
      apiKeys: await one("select count(*)::int v from information_schema.tables where table_schema='public' and table_name='api_keys'"),
      apiDocs: await one("select count(*)::int v from pg_proc where proname='api_docs'")
    };
    say('');
    say('Before:');
    say('  issues table    : ' + (before.issues ? 'yes' : 'no'));
    say('  api_keys table  : ' + (before.apiKeys ? 'yes' : 'no'));
    say('  api_docs()      : ' + (before.apiDocs ? 'yes' : 'no'));

    say('');
    say('Running the schema (safe to repeat - it updates in place)...');
    await client.query(sql);
    ok('the schema applied without error');

    const after = {
      apiKeys: await one("select count(*)::int v from information_schema.tables where table_schema='public' and table_name='api_keys'"),
      webhooks: await one("select count(*)::int v from information_schema.tables where table_schema='public' and table_name='webhooks'"),
      deliveries: await one("select count(*)::int v from information_schema.tables where table_schema='public' and table_name='webhook_deliveries'"),
      apiDocs: await one("select count(*)::int v from pg_proc where proname='api_docs'"),
      endpoints: await one("select count(*)::int v from pg_proc where proname like 'api\\_%'"),
      issuesKept: await one("select count(*)::int v from public.issues")
    };

    say('');
    say('After:');
    ok('api_keys table');
    ok('webhooks table');
    ok('webhook_deliveries table');
    ok('api_docs()');
    ok(after.endpoints + ' API functions');
    say('');
    say('  issues still on the board : ' + after.issuesKept);
    if (before.issues) {
      say('  (the existing board was not touched)');
    }

    // ---- optionally hand out keys, so nothing has to be clicked ------------
    if (WANT_KEYS) {
      say('');
      say('Creating keys...');

      const live = await one("select count(*)::int v from public.api_keys where revoked_at is null");
      if (live > 0) {
        say('  ' + live + ' key(s) already exist - not making more.');
        say('  (revoke the old ones in the app if you want fresh ones.)');
      } else {
        const make = async (name, role) => {
          const key = 'itk_' + crypto.randomBytes(24).toString('hex');
          await client.query(
            `insert into public.api_keys (name, prefix, key_hash, role)
             values ($1, $2, encode(digest($3, 'sha256'), 'hex'), $4)`,
            [name, key.slice(0, 12), key, role]
          );
          return key;
        };

        const adminKey = await make('admin - full control', 'admin');
        const userKey  = await make('shared with a friend', 'user');

        say('');
        say('==============================================');
        say('  YOUR KEYS - copy them now');
        say('==============================================');
        say('');
        say('  ADMIN (can change, delete, list accounts)');
        say('    ' + adminKey);
        say('');
        say('  USER  (can read, search and report)');
        say('    ' + userKey);
        say('');
        say('  Only the hash is stored. They are not shown again.');
        say('');
        say('  Browser console, straight in:');
        say('    https://issue-trackers-bay.vercel.app/api.html?key=' + userKey);
        say('');
        say('  Or test them:');
        say('    cd tests');
        say('    .\\api-smoke.ps1 -Key ' + userKey);
        say('    .\\api-smoke.ps1 -Key ' + adminKey + ' -Write');
        say('');
      }
    }

    say('');
    say('==============================================');
    say('  Done. The API is in the database.');
    say('==============================================');
    if (!WANT_KEYS) {
      say('');
      say('Next:');
      say('  1. Open the app, Settings > API keys, create one and copy it');
      say('  2. Test it:  cd tests && .\\api-smoke.ps1 -Key itk_your_key');
    }
    say('');
  } catch (e) {
    bad('the database rejected it: ' + e.message);
    if (e.position) say('  at character ' + e.position + ' of the schema');
    if (e.hint) say('  hint: ' + e.hint);
    say('');
  } finally {
    await client.end().catch(() => {});
  }
})();
