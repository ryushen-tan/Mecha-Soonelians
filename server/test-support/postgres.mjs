import { execFile, spawnSync } from 'node:child_process';
import { mkdtemp, readdir, readFile, rm } from 'node:fs/promises';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import postgres from 'postgres';

const run = promisify(execFile);
const migrations = new URL('../../supabase/migrations/', import.meta.url);

export const hasPostgres = spawnSync('initdb', ['--version']).status === 0;

// What hosted Supabase provides before our migrations run. The default privileges are deliberately
// broader than Supabase's, so the tests prove the migrations revoke client access themselves.
const SUPABASE_SHIM = `
  create role anon nologin;
  create role authenticated nologin;
  create role service_role nologin bypassrls;
  alter default privileges for role postgres grant all on tables to anon, authenticated, service_role;
  alter default privileges for role postgres grant all on sequences to anon, authenticated, service_role;
  alter default privileges for role postgres grant all on functions to anon, authenticated, service_role;
  alter default privileges for role postgres grant usage on schemas to anon, authenticated, service_role;
  create schema storage;
  create table storage.buckets (id text primary key, name text not null unique, public boolean default false,
    file_size_limit bigint, allowed_mime_types text[], created_at timestamptz default now(), updated_at timestamptz default now());
`;

export async function freePort() {
  const server = createServer().listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  const { port } = server.address();
  await new Promise(resolve => server.close(resolve));
  return port;
}

// A throwaway PostgreSQL cluster with the Supabase migrations applied.
export async function startPostgres() {
  const dir = await mkdtemp(join(tmpdir(), 'rally-pg-'));
  const data = join(dir, 'data');
  const port = await freePort();
  await run('initdb', ['-D', data, '-U', 'postgres', '--auth=trust', '-E', 'UTF8', '--no-sync']);
  const start = () => run('pg_ctl', ['-D', data, '-l', join(dir, 'log'), '-w', 'start',
    '-o', `-p ${port} -k ${dir} -c listen_addresses=127.0.0.1 -c fsync=off`]);
  const stop = () => run('pg_ctl', ['-D', data, '-m', 'fast', '-w', 'stop']);
  await start();
  const admin = postgres(`postgres://postgres@127.0.0.1:${port}/postgres`, { onnotice: () => {}, max: 2 });
  await admin.unsafe(SUPABASE_SHIM);
  for (const file of (await readdir(migrations)).filter(name => name.endsWith('.sql')).sort()) {
    await admin.unsafe(await readFile(new URL(file, migrations), 'utf8'));
  }
  await admin`alter role rally_api with login password 'rally-test'`;
  return {
    admin,
    apiURL: `postgres://rally_api:rally-test@127.0.0.1:${port}/postgres`,
    pause: stop,
    resume: start,
    async close() {
      await admin.end({ timeout: 1 });
      await stop().catch(() => {});
      await rm(dir, { recursive: true, force: true });
    }
  };
}
