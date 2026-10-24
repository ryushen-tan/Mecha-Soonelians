# Supabase room storage

Rooms, members, game state and disguise metadata are stored in Supabase Postgres (schema `rally`), and disguise GLBs go in the private Storage bucket `rally-disguises`. Every Vercel instance reads and writes the same rows, so no single instance owns a room. Each request locks its room row for the length of one transaction. That makes joins, leaves, kicks, starts, game actions and heartbeats apply one at a time per room, across all instances.

| Piece | Where |
| --- | --- |
| Migrations | `supabase/migrations/` (apply in filename order) |
| Store | `server/lib/supabase-store.mjs` (single-process memory store: `server/lib/room-store.mjs`) |
| Environment | `server/.env.example` |
| Tests | `cd server && npm run test:supabase` (needs PostgreSQL 15+ `initdb`/`pg_ctl` on `PATH`) |

**Production** uses the existing Supabase project **Rugia** (ref `saeypsjtyeahpqkmjkwo`, `ca-central-1`; the free plan allowed no new project). Rally lives entirely in its own `rally` schema, `rally_api` role, `rally-disguises` bucket, `rally-cleanup-expired` cron job and `mecha_soonelians` secret key, and the API role cannot read Rugia's data. Rugia's migration history belongs to Rugia's repository, so **do not run `supabase db push` against it**; apply new files in `supabase/migrations/` with:

```sh
npx supabase@latest db query --linked --project-ref saeypsjtyeahpqkmjkwo --file supabase/migrations/<file>.sql
```

## Behaviour

- **Round trips.** Through Supavisor's transaction pooler (prepared statements off), every parameterized query costs an extra round trip. So a request is four simple-protocol statements: `begin`, `rally.room_load(code)` (locks and reads), `rally.room_save(id, changes)`, and `commit`. The room stays locked for about two round trips. Run the functions in the same region as the database, or as close to it as Vercel allows.
- **Codes and names.** Room codes are six digits and unique (`rooms_code_key`). Names are unique per room, case-insensitively (`members_room_name_key` on `name.toLocaleLowerCase('en-US')`). Each room has one host (`members_one_host`).
- **Tokens.** Membership tokens are returned to their owner once. Only their SHA-256 (`members.token_hash`) is stored.
- **Expiry.**
  - A guest who makes no request for 90 seconds is removed.
  - If the host makes no request for 90 seconds, or the room is idle for two hours, the room closes.
  - A host leaving also closes the room.
  - Every request applies these rules to the room it locks. `rally.cleanup_expired()` applies the same rules every minute through pg_cron, and skips rooms that a request holds at that moment.
- **Outages.** Database, pooler, and Storage failures return `503` with `Retry-After: 2`, never `404` or `401`. The app treats a 503 as "reconnecting" and keeps its membership. If the three variables are missing, the API refuses with `503`; it does not fall back to per-instance memory.
- **Disguises.** A disguise goes through these steps:
  1. The GLB is validated.
  2. It is stored under a unique path `<room id>/<member id>/<uuid>.glb`.
  3. It is published under the room lock, where the phase rules are checked again.

  Replaced, rejected, and deleted files are queued in `rally.storage_trash` by a trigger. The API deletes them through the Storage API, after the request that removed them and whenever a room is created. Downloads stream through the API after the same visibility check as before.
- **Access.**
  - Client keys (anon/publishable and signed-in users) and `service_role` have no privileges on the `rally` schema, its tables, or its functions. RLS is enabled on every table, with policies only for `rally_api`.
  - The bucket is private and has no `storage.objects` policies.
  - The API uses two credentials: a least-privilege Postgres role, and the secret key for Storage only. Both are server-side.

## Online AR round

Pressing **Start game** in the lobby runs the AR hide-and-seek round through this same backend (`server/lib/ar.mjs`, table `rally.ar_games`, private bucket `rally-ar`).

- **Flow.** The host's phone uploads its scanned house (`structure.json` and `worldmap.arexperience`) straight to Storage on signed upload links, then the server picks **one random seeker**. Phases: *finding the house* (every phone relocalizes) → *hiding* (hiders place a ghost; the seeker is told to wait) → *seeking* → *results*. Hiding starts by itself when every player has found the house, or when the host taps **Start hiding now**. All timers run on the server clock.
- **Who sees what** is decided server-side: a hider sees their own ghost; the seeker sees everyone's only while seeking; everyone sees all at the end. Signed download links are only issued for ghosts the caller may see.
- **Big files** never pass through Vercel (its 4.5 MB body limit): the phones upload and download on short-lived signed links. Files live under `<room id>/` and are deleted when the room closes or the next round clears the ghosts.
- **Needs `SUPABASE_SERVICE_ROLE_KEY`.** Storage only creates signed links and existence checks for a JWT caller, not for an `sb_secret_` key (verified against the real service). Set the legacy `service_role` JWT as `SUPABASE_SERVICE_ROLE_KEY` on Vercel. Only the AR bucket uses it; everything else keeps using `SUPABASE_SECRET_KEY`.
- **API** (all under `/rooms/:code/ar`, membership token required): `GET` the round; `POST` with `action` = `start` (host), `begin` (host), `skip` (host), `ready`, `place`, `tag`; `POST|GET /house`; `POST /ghosts` and `GET /ghosts/:id` for upload/download links.

## Supabase setup

1. **Create the project.** Create a project at <https://supabase.com/dashboard>. Choose the region closest to your players. Every request makes several round trips to the database, so the Vercel functions must run in the matching region (step 4 of Vercel setup). For example, East US (North Virginia) pairs with Vercel `iad1`. Save the database password.

2. **Apply the migrations.** For a dedicated project, from the repository root (for a project shared with another app, use `supabase db query … --file` per file, as above):

   ```sh
   npx supabase@latest login
   npx supabase@latest init            # only if supabase/config.toml does not exist yet
   npx supabase@latest link --project-ref <project-ref>
   npx supabase@latest db push         # applies the files in supabase/migrations
   ```

   Without the CLI, open **SQL Editor** and run each file in `supabase/migrations/` in filename order.

3. **Enable the API role.** Generate a password: `openssl rand -hex 32` gives a password that needs no URL encoding. Then run in **SQL Editor**:

   ```sql
   alter role rally_api with login password '<generated password>';
   ```

4. **Check the result** in **SQL Editor**:

   ```sql
   select jobname, schedule, active from cron.job where jobname = 'rally-cleanup-expired';  -- one active row, '* * * * *'
   select id, public, file_size_limit from storage.buckets where id = 'rally-disguises';     -- public = false
   select relname, relrowsecurity from pg_class where relnamespace = 'rally'::regnamespace and relkind = 'r';  -- all true
   ```

   Under **Project Settings → Data API**, leave `rally` out of the exposed schemas.

5. **Collect the values.**
   - `RALLY_DATABASE_URL`: Click **Connect**, then **Transaction pooler** (port 6543). Copy the URI and change the user from `postgres.<project-ref>` to `rally_api.<project-ref>`. Use the password from step 3.
   - `SUPABASE_URL`: `https://<project-ref>.supabase.co`, from **Project Settings → Data API**.
   - `SUPABASE_SECRET_KEY`: From **Project Settings → API Keys**, create or copy a secret key (`sb_secret_…`). The legacy `service_role` key also works.
   - Optional, `RALLY_DATABASE_CA_CERT`: From **Database → Settings → SSL Configuration**, download the certificate and use its PEM text. With it, the server certificate is verified. Without it, the connection is encrypted but the certificate is not verified.

6. **Try it locally before Vercel.** Copy `server/.env.example` to `server/.env.local` and fill it in. Then:

   ```sh
   cd server
   npm run dev
   curl -s -X POST localhost:3000/rooms -H 'Content-Type: application/json' -d '{"name":"Setup","avatar":0}'
   ```

   The room should appear in **Table Editor → rally → rooms**. If you change the Data API settings, the Table Editor may only show the schema to the dashboard; that's expected.

## Vercel setup

1. In **Project Settings → Build and Deployment**, the Root Directory is `server`.
2. In **Project Settings → Environment Variables**, add `RALLY_DATABASE_URL`, `SUPABASE_URL`, `SUPABASE_SECRET_KEY`, and optionally `RALLY_DATABASE_CA_CERT`.
   - Set them for Production, and for Preview if previews should share rooms.
   - Mark them Sensitive.
   - Do not prefix them with `NEXT_PUBLIC_`, and do not set `RALLY_STORE`.
3. Set the variables before the deployment that ships this code. A deployment only reads variables that existed when it was built and started; without them, every room request returns `503`.
4. In **Project Settings → Functions → Function Region**, choose the region that matches Supabase.
5. Deploy.

## After deploying: verify across instances

Run these against the deployment. Every check must pass before you call the live issue fixed.

```sh
cd server
RALLY_TEST_URL=https://mecha-soonelians.vercel.app node --test server.test.mjs           # 4 pass; 64 simultaneous joins
RALLY_TEST_URL=https://mecha-soonelians.vercel.app node --test --test-name-pattern='HTTP game' game.test.mjs
```

Then:

- **Membership survives new instances.** Create a room in the app, join from a second phone, and leave both in the lobby. Redeploy (`vercel redeploy <deployment-url> --prod`, or use **Redeploy** in the dashboard). Both phones must stay in the room.
- **The database is the source of truth.** While both phones are in a room, run `select r.code, m.name, m.seen_at from rally.members m join rally.rooms r on r.id = m.room_id order by r.code, m.seq;`. Both players should appear and `seen_at` should advance every second or so.
- **Expiry.** Background the host app for more than 90 seconds. The room's row should disappear and the guest should see "Room not found".

## Limits

- Vercel caps request and response bodies at 4.5 MB. This applies to disguise uploads and downloads, which already ran through the function before this change, so GLBs above 4.5 MB fail with `413` on Vercel even though the API accepts 20 MB.
- Rate limits (180 mutations per minute per address, with per-player budgets for game actions) and the in-flight upload budget are counted per instance. They are abuse guards, not room state.
- Storage files of rooms that pg_cron closes are deleted the next time any instance creates a room, or another room closes.
