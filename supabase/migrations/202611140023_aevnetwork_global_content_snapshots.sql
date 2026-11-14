-- Global AevNetwork news and update-content maintenance snapshots.
-- These tables contain shared content, not per-user records.

create table if not exists public.aevnetwork_global_content_snapshots (
  singleton boolean primary key default true check (singleton),
  news_data jsonb not null default '[]'::jsonb,
  updates_data jsonb not null default '[]'::jsonb,
  captured_at timestamptz not null default now()
);

alter table public.aevnetwork_global_content_snapshots enable row level security;
revoke all on public.aevnetwork_global_content_snapshots from anon, authenticated;
grant all on public.aevnetwork_global_content_snapshots to service_role;

create or replace function public.aevnetwork_capture_global_content_snapshot()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_news jsonb;
  v_updates jsonb;
begin
  select coalesce(jsonb_agg(to_jsonb(n)), '[]'::jsonb)
    into v_news from public.aevnetwork_news n;
  select coalesce(jsonb_agg(to_jsonb(u)), '[]'::jsonb)
    into v_updates from public.aevnetwork_updates u;

  insert into public.aevnetwork_global_content_snapshots
    (singleton, news_data, updates_data, captured_at)
  values (true, v_news, v_updates, now())
  on conflict (singleton) do update
    set news_data = excluded.news_data,
        updates_data = excluded.updates_data,
        captured_at = excluded.captured_at;

  return jsonb_build_object(
    'news_count', jsonb_array_length(v_news),
    'updates_count', jsonb_array_length(v_updates)
  );
end;
$$;

create or replace function public.aevnetwork_restore_global_content_snapshot()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_snapshot public.aevnetwork_global_content_snapshots%rowtype;
  v_news_count integer := 0;
  v_updates_count integer := 0;
begin
  select * into v_snapshot
    from public.aevnetwork_global_content_snapshots
    where singleton = true
    for update;

  if not found then
    return jsonb_build_object('restored', false, 'reason', 'snapshot_not_found');
  end if;

  -- Restore missing rows only. Existing current rows win, preventing rollback
  -- over newer content that may already exist in the live tables.
  insert into public.aevnetwork_news
  select (jsonb_populate_record(null::public.aevnetwork_news, item)).*
  from jsonb_array_elements(v_snapshot.news_data) as item
  on conflict do nothing;
  get diagnostics v_news_count = row_count;

  insert into public.aevnetwork_updates
  select (jsonb_populate_record(null::public.aevnetwork_updates, item)).*
  from jsonb_array_elements(v_snapshot.updates_data) as item
  on conflict do nothing;
  get diagnostics v_updates_count = row_count;

  delete from public.aevnetwork_global_content_snapshots where singleton = true;

  return jsonb_build_object(
    'restored', true,
    'news_rows_inserted', v_news_count,
    'update_rows_inserted', v_updates_count
  );
end;
$$;

-- Extend the existing atomic maintenance transition:
-- ON captures shared news/updates; OFF restores missing shared rows before access resumes.
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
  global_content_result jsonb := '{}'::jsonb;
begin
  if p_updated_by is null or not exists (
    select 1 from public.aevtools_admin where user_id = p_updated_by
  ) then
    raise exception 'admin_required';
  end if;

  if coalesce(p_enabled, false) then
    snapshot_result := public.aevtools_capture_maintenance_snapshots();
    global_content_result := public.aevnetwork_capture_global_content_snapshot();
  else
    global_content_result := public.aevnetwork_restore_global_content_snapshot();
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
    'snapshot', snapshot_result,
    'global_content', global_content_result
  );
end;
$$;

revoke all on function public.aevnetwork_capture_global_content_snapshot() from public, anon, authenticated;
grant execute on function public.aevnetwork_capture_global_content_snapshot() to service_role;
revoke all on function public.aevnetwork_restore_global_content_snapshot() from public, anon, authenticated;
grant execute on function public.aevnetwork_restore_global_content_snapshot() to service_role;
revoke all on function public.aevtools_set_maintenance_with_snapshot(boolean, uuid) from public, anon, authenticated;
grant execute on function public.aevtools_set_maintenance_with_snapshot(boolean, uuid) to service_role;
