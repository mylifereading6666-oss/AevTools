-- Security hardening for AevTools / AevNetwork shared Supabase project.
-- Removes dangerous client table privileges and closes obsolete maintenance bypasses.

-- RLS does not protect against TRUNCATE. Client roles must never hold these
-- schema-level/table-level administration privileges.
revoke truncate, trigger, references on table
  public.aevtools_announcements,
  public.aevtools_board_posts,
  public.aevtools_board_comments
from public, anon, authenticated;

-- The legacy RPC changes the maintenance flag without creating the current
-- database/global-content snapshots. The Edge Function now uses the
-- service-role-only snapshot-aware RPC instead.
revoke all on function public.aevtools_set_service_maintenance(boolean)
  from public, anon, authenticated, service_role;

-- Store the initial-admin claim verifier outside the function definition.
-- This prevents the verifier hash from being disclosed through function
-- definition inspection. No client role may read or modify this table.
create table if not exists public.aevtools_admin_claim_secret (
  singleton boolean primary key default true check (singleton),
  code_hash text,
  updated_at timestamptz not null default now(),
  constraint aevtools_admin_claim_secret_hash_format
    check (code_hash is null or code_hash ~ '^[0-9a-f]{64}$')
);

alter table public.aevtools_admin_claim_secret enable row level security;
revoke all on table public.aevtools_admin_claim_secret
  from public, anon, authenticated, service_role;

insert into public.aevtools_admin_claim_secret(singleton, code_hash)
values (true, null)
on conflict (singleton) do nothing;

-- The existing administrator remains registered. New claims are disabled
-- until an owner explicitly provisions a fresh secret hash in SQL Editor.
create or replace function public.aevtools_claim_admin(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $function$
declare
  v_uid uuid := auth.uid();
  v_hash text;
  v_expected_hash text;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'reason', 'login_required');
  end if;

  -- Once the singleton administrator exists, no further claim is possible.
  if exists (
    select 1 from public.aevtools_admin
    where singleton = true
  ) then
    return jsonb_build_object('ok', false, 'reason', 'admin_already_exists');
  end if;

  -- Serialize first-admin claims to prevent concurrent claim attempts.
  perform pg_advisory_xact_lock(hashtext('aevtools_first_admin_claim'));

  if exists (
    select 1 from public.aevtools_admin
    where singleton = true
  ) then
    return jsonb_build_object('ok', false, 'reason', 'admin_already_exists');
  end if;

  select code_hash into v_expected_hash
  from public.aevtools_admin_claim_secret
  where singleton = true
  for update;

  if v_expected_hash is null then
    return jsonb_build_object('ok', false, 'reason', 'admin_claim_not_configured');
  end if;

  v_hash := encode(digest(upper(trim(coalesce(p_code, ''))), 'sha256'), 'hex');
  if v_hash <> v_expected_hash then
    return jsonb_build_object('ok', false, 'reason', 'invalid_code');
  end if;

  insert into public.aevtools_admin(singleton, user_id)
  values (true, v_uid)
  on conflict (singleton) do nothing;

  if exists (
    select 1 from public.aevtools_admin
    where singleton = true and user_id = v_uid
  ) then
    return jsonb_build_object('ok', true, 'reason', 'admin');
  end if;

  return jsonb_build_object('ok', false, 'reason', 'admin_already_exists');
end;
$function$;

revoke all on function public.aevtools_claim_admin(text)
  from public, anon;
grant execute on function public.aevtools_claim_admin(text)
  to authenticated;

-- Only the trusted Edge Function's service-role client may invoke this RPC.
-- Validate the JWT role as well as the admin identity supplied by the
-- authenticated Edge Function, preventing direct use with a forged user ID.
create or replace function public.aevtools_set_maintenance_with_snapshot(
  p_enabled boolean,
  p_updated_by uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  snapshot_result jsonb := '{}'::jsonb;
  global_content_result jsonb := '{}'::jsonb;
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'service_role_required';
  end if;

  if p_updated_by is null or not exists (
    select 1
    from public.aevtools_admin
    where user_id = p_updated_by
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
  values
    (true, coalesce(p_enabled, false), now(), p_updated_by)
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
$function$;

revoke all on function public.aevtools_set_maintenance_with_snapshot(boolean, uuid)
  from public, anon, authenticated;
grant execute on function public.aevtools_set_maintenance_with_snapshot(boolean, uuid)
  to service_role;
