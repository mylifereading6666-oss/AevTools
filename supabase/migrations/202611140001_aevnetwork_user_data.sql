-- AevNetwork account-scoped cloud storage.
-- Safe isolation: this is a NEW table and does not alter AevTools data.
create table if not exists public.aevnetwork_user_data (
  user_id uuid primary key references auth.users(id) on delete cascade,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.aevnetwork_user_data enable row level security;

-- No browser policies are intentionally created.
-- Only the AevNetwork Edge Function uses the server-side service-role key
-- after validating the caller's Supabase Auth access token.
revoke all on table public.aevnetwork_user_data from anon, authenticated;
grant all on table public.aevnetwork_user_data to service_role;
