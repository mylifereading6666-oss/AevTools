-- AevTools per-account cloud backup
-- Run once in Supabase SQL Editor before enabling account-scoped storage.

create table if not exists public.aevtools_user_data (
  user_id uuid primary key references auth.users(id) on delete cascade,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  constraint aevtools_user_data_object_check check (jsonb_typeof(data) = 'object')
);

alter table public.aevtools_user_data enable row level security;

drop policy if exists "AevTools users read own data" on public.aevtools_user_data;
create policy "AevTools users read own data"
on public.aevtools_user_data
for select to authenticated
using (user_id = auth.uid());

drop policy if exists "AevTools users insert own data" on public.aevtools_user_data;
create policy "AevTools users insert own data"
on public.aevtools_user_data
for insert to authenticated
with check (user_id = auth.uid());

drop policy if exists "AevTools users update own data" on public.aevtools_user_data;
create policy "AevTools users update own data"
on public.aevtools_user_data
for update to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

revoke all on public.aevtools_user_data from anon;
revoke all on public.aevtools_user_data from authenticated;
grant select, insert, update on public.aevtools_user_data to authenticated;
