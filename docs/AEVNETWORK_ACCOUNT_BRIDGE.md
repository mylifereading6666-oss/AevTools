# AevNetwork shared account and storage bridge

AevNetwork uses the existing AevTools Supabase Auth project for identity. The
AevNetwork browser calls the AevTools-owned Edge Function endpoint; it does
not query Supabase tables directly.

## Data isolation

- Existing AevTools table `aevtools_user_data` is not modified.
- AevNetwork has a separate `aevnetwork_user_data` row per Auth user.
- The Edge Function validates every bearer token with Supabase Auth before
  reading or writing that user's row.
- The service-role key exists only in Supabase Edge Function secrets.
- Browser access to the new table is denied by RLS and SQL grants.

## Deployment checklist

1. In the existing Supabase project, open SQL Editor and run
   `supabase/migrations/202611140001_aevnetwork_user_data.sql`.
2. Deploy `supabase/functions/aevnetwork-api/index.ts` as the function
   `aevnetwork-api` using the Supabase CLI or Dashboard.
3. Confirm the function environment contains the platform-provided
   `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY`.
4. Do not paste the service-role key into GitHub, HTML, or browser storage.

## API contract

POST JSON to `https://vuqbbwdojwmtehgsyfaq.supabase.co/functions/v1/aevnetwork-api`.

- `{ "action": "login", "email": "...", "password": "..." }` returns a
  Supabase Auth session for an existing AevTools account.
- `{ "action": "refresh", "refresh_token": "..." }` renews an expired session.
- `{ "action": "get_data" }` with `Authorization: Bearer <access_token>`
  returns only the signed-in user's AevNetwork data.
- `{ "action": "save_data", "data": { ... } }` with the same bearer token
  saves only that user's AevNetwork data.

The login endpoint currently supports existing-account sign-in only.
Registration, password recovery, token refresh, logout UI, profile fields,
and username cooldown enforcement are later integration tasks. Do not claim
those features are active until implemented and tested.

## Important

GitHub Pages serves static files only. Committing this source does not deploy
the Edge Function or execute the SQL migration. Both deployment steps above
must be completed in Supabase before the API can work.
