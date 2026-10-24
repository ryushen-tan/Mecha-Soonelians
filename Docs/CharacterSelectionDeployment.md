# Deploy the character-selection fix

This update lets the lobby API acknowledge `hasCharacter` and clear Ready for the
host as well as guests. Supabase persists character availability and the room's
character requirement between API requests and deployments. Existing rooms keep
their legacy rules; create a new room after deploying.

## 1. Apply the database migration first

In the existing Supabase project's SQL Editor, run the complete contents of:

[`supabase/migrations/20261024180000_rally_character_selection.sql`](../supabase/migrations/20261024180000_rally_character_selection.sql)

The earlier migrations must already be installed (see [Supabase setup](Supabase.md)).
This migration adds two boolean columns and replaces the room load/save functions
in one transaction. It preserves existing rows and function permissions and is
compatible with the older API while the new deployment rolls out. Do not run
`supabase db push` against the shared Rugia project.

## 2. Deploy this Git revision to Vercel

- Repository: `ryushen-tan/Mecha-Soonelians`.
- Fix branch: `codex/character-selection-deploy` (or merge it into `main` after step 1).
- Root Directory: `server`.
- Framework: Next.js.
- Install command: `npm ci`.
- Build command: `npm run build`.
- Output directory: leave at the Next.js default.

Keep the existing Production variables `RALLY_DATABASE_URL`, `SUPABASE_URL`, and
`SUPABASE_SECRET_KEY` (plus `RALLY_DATABASE_CA_CERT` if already configured). Keep
the existing 3D service variables too. No new environment variable is needed.
Do not set `RALLY_STORE=memory` or use the Mac's local database connection string.

Choose a deployment built from the fix commit, and deploy/promote it to Production.
Redeploying an older commit does not include this fix. If Git deployment is enabled,
merging this branch into the configured production branch starts the deployment.

## 3. Verify on both phones

Use `https://mecha-soonelians.vercel.app` as the lobby server on both phones. Leave
the old room and create a fresh room. Select a saved character on each phone:
the chooser should close, and each player should stay unready until tapping Ready.
Once both players are ready, the host can start the round.

The updated iPhone app must be installed separately; Vercel only deploys the server.
Vercel's existing function body-size limit still applies to character model uploads;
this fix changes selection and room state, not the model upload transport.

## Validation

From `server/`: `npm ci`, `npm test`, `npm run build`, `npm run test:integration`,
and `npm run test:supabase` (PostgreSQL tools must be on `PATH`). The Supabase suite
uses a disposable local cluster and separate API processes. It checks character
selection, readiness, starting a round, restart persistence, and old API saves
that omit the new fields. It does not alter the hosted database.
