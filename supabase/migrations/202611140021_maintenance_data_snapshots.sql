-- AevTools / AevNetwork maintenance-time user data snapshots.
-- Run once in the Supabase SQL Editor.
-- Snapshot rows are private: only the Edge Function service_role can read/write them.

create table if not exists public.aev_user_data_snapshots (
  user_id uuid not null references auth.users(id) on delete cascade,
  app_key text not null check (app_key in ('aevtools', 'aevnetwork')),
  data jsonb not null default '{}'::jsonb,
  source_updated_at timestamptz,
  captured_at timestamptz not null default now(),
  primary key (user_id, app_key),
  constraint aev_user_data_snapshots_object_check check (jsonb_typeof(data) = 'object')
);

alter table public.aev_user_data_snapshots enable row level security;
revoke all on public.aev_user_data_snapshots from public, anon, authenticated;
grant all on public.aev_user_data_snapshots to service_role;

-- Capture every account's current cloud data at the exact maintenance transition.
create or replace function public.aevtools_capture_maintenance_snapshots()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  tools_count integer := 0;
  network_count integer := 0;
begin
  insert into public.aev_user_data_snapshots
    (user_id, app_key, data, source_updated_at, captured_at)
  select user_id, 'aevtools', data, updated_at, now()
  from public.aevtools_user_data
  on conflict (user_id, app_key) do update
    set data = excluded.data,
        source_updated_at = excluded.source_updated_at,
        captured_at = excluded.captured_at;
  get diagnostics tools_count = row_count;

  insert into public.aev_user_data_snapshots
    (user_id, app_key, data, source_updated_at, captured_at)
  select user_id, 'aevnetwork', data, updated_at, now()
  from public.aevnetwork_user_data
  on conflict (user_id, app_key) do update
    set data = excluded.data,
        source_updated_at = excluded.source_updated_at,
        captured_at = excluded.captured_at;
  get diagnostics network_count = row_count;

  return jsonb_build_object('aevtools_users', tools_count, 'aevnetwork_users', network_count);
end;
$$;

-- While maintenance is ON, every subsequent cloud-data write refreshes that
-- user's own snapshot. This includes administrator/test-helper changes.
create or replace function public.aevtools_refresh_user_data_snapshot()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce((
    select maintenance_enabled
    from public.aevtools_service_control
    where singleton = true
  ), false) then
    insert into public.aev_user_data_snapshots
      (user_id, app_key, data, source_updated_at, captured_at)
    values (
      new.user_id,
      case when tg_table_name = 'aevtools_user_data' then 'aevtools' else 'aevnetwork' end,
      new.data,
      new.updated_at,
      now()
    )
    on conflict (user_id, app_key) do update
      set data = excluded.data,
          source_updated_at = excluded.source_updated_at,
          captured_at = excluded.captured_at;
  end if;
  return new;
end;
$$;

drop trigger if exists aevtools_snapshot_user_data on public.aevtools_user_data;
create trigger aevtools_snapshot_user_data
after insert or update on public.aevtools_user_data
for each row execute function public.aevtools_refresh_user_data_snapshot();

drop trigger if exists aevnetwork_snapshot_user_data on public.aevnetwork_user_data;
create trigger aevnetwork_snapshot_user_data
after insert or update on public.aevnetwork_user_data
for each row execute function public.aevtools_refresh_user_data_snapshot();

-- The Edge Function verifies the caller's admin identity first, then invokes
-- this service-role-only RPC. Snapshot + maintenance switch update are atomic.
create or replace function public.aevtools_set_maintenance_with_snapshot(
  p_enabled boolean,
  p_updated_by uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  snapshot_result jsonb := '{}'::jsonb;
begin
  if p_updated_by is null or not exists (
    select 1 from public.aevtools_admin where user_id = p_updated_by
  ) then
    raise exception 'admin_required';
  end if;

  if coalesce(p_enabled, false) then
    snapshot_result := public.aevtools_capture_maintenance_snapshots();
  end if;

  insert into public.aevtools_service_control
    (singleton, maintenance_enabled, updated_at, updated_by)
  values (true, coalesce(p_enabled, false), now(), p_updated_by)
  on conflict (singleton) do update
    set maintenance_enabled = excluded.maintenance_enabled,
        updated_at = excluded.updated_at,
        updated_by = excluded.updated_by;

  return jsonb_build_object(
    'maintenance_enabled', coalesce(p_enabled, false),
    'snapshot', snapshot_result
  );
end;
$$;

revoke all on function public.aevtools_capture_maintenance_snapshots() from public, anon, authenticated;
grant execute on function public.aevtools_capture_maintenance_snapshots() to service_role;
revoke all on function public.aevtools_set_maintenance_with_snapshot(boolean, uuid) from public, anon, authenticated;
grant execute on function public.aevtools_set_maintenance_with_snapshot(boolean, uuid) to service_role;
revoke all on function public.aevtools_refresh_user_data_snapshot() from public, anon, authenticated;
