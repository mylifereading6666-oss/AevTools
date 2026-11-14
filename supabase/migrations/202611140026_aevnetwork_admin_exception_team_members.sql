-- Admin-only exceptional team additions. Normal teams remain capped at four.
create table if not exists public.aevnetwork_team_admin_add_audit (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.aevnetwork_teams(id) on delete cascade,
  target_user_id uuid not null references auth.users(id) on delete restrict,
  admin_user_id uuid not null references auth.users(id) on delete restrict,
  context text not null check (context in ('audit','mediation')),
  reason text not null check (char_length(reason) between 5 and 1000),
  mediation_request_id uuid references public.aevnetwork_team_mediation_requests(id) on delete set null,
  created_at timestamptz not null default now()
);

alter table public.aevnetwork_team_admin_add_audit enable row level security;
revoke all on public.aevnetwork_team_admin_add_audit from public, anon, authenticated, service_role;

create or replace function public.aevnetwork_enforce_team_capacity()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $function$
declare
  approved_count integer;
  override_audit_id uuid;
begin
  if new.status <> 'approved' then
    return new;
  end if;

  perform 1 from public.aevnetwork_teams where id = new.team_id for update;
  if not found then
    raise exception 'team_not_found';
  end if;

  select count(*) into approved_count
  from public.aevnetwork_team_members
  where team_id = new.team_id
    and status = 'approved'
    and (tg_op <> 'UPDATE' or id <> new.id);

  if approved_count >= 4 then
    begin
      override_audit_id := nullif(current_setting('aevnetwork.admin_add_audit_id', true), '')::uuid;
    exception when others then
      override_audit_id := null;
    end;

    if override_audit_id is null or not exists (
      select 1
      from public.aevnetwork_team_admin_add_audit a
      join public.aevtools_admin admin on admin.user_id = a.admin_user_id
      where a.id = override_audit_id
        and a.team_id = new.team_id
        and a.target_user_id = new.user_id
    ) then
      raise exception 'team_full';
    end if;
  end if;

  return new;
end;
$function$;

create or replace function public.aevnetwork_admin_add_team_member(
  p_admin_user_id uuid,
  p_team_id uuid,
  p_target_user_id uuid,
  p_context text,
  p_reason text,
  p_mediation_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $function$
declare
  v_audit_id uuid;
  v_existing public.aevnetwork_team_members%rowtype;
  v_team public.aevnetwork_teams%rowtype;
  v_has_existing boolean := false;
begin
  if p_admin_user_id is null or not exists (
    select 1 from public.aevtools_admin where user_id = p_admin_user_id
  ) then
    raise exception 'admin_required';
  end if;

  if p_context not in ('audit','mediation') then
    raise exception 'invalid_admin_add_context';
  end if;
  if p_reason is null or char_length(trim(p_reason)) < 5 or char_length(p_reason) > 1000 then
    raise exception 'admin_add_reason_required';
  end if;

  select * into v_team
  from public.aevnetwork_teams
  where id = p_team_id
  for update;
  if not found then raise exception 'team_not_found'; end if;

  if not exists (select 1 from auth.users where id = p_target_user_id) then
    raise exception 'target_user_not_found';
  end if;

  if p_context = 'mediation' then
    if p_mediation_request_id is null or not exists (
      select 1 from public.aevnetwork_team_mediation_requests
      where id = p_mediation_request_id
        and team_id = p_team_id
        and status = 'approved'
    ) then
      raise exception 'approved_mediation_required';
    end if;
  elsif p_mediation_request_id is not null then
    raise exception 'invalid_mediation_request';
  end if;

  select * into v_existing
  from public.aevnetwork_team_members
  where team_id = p_team_id and user_id = p_target_user_id
  for update;

  v_has_existing := found;
  if v_has_existing and v_existing.status = 'approved' then
    raise exception 'already_team_member';
  end if;

  insert into public.aevnetwork_team_admin_add_audit
    (team_id,target_user_id,admin_user_id,context,reason,mediation_request_id)
  values
    (p_team_id,p_target_user_id,p_admin_user_id,p_context,trim(p_reason),p_mediation_request_id)
  returning id into v_audit_id;

  perform set_config('aevnetwork.admin_add_audit_id', v_audit_id::text, true);

  if v_has_existing then
    update public.aevnetwork_team_members
      set role = 'member', status = 'approved', reviewed_at = now()
      where id = v_existing.id;
  else
    insert into public.aevnetwork_team_members
      (team_id,user_id,role,status,reviewed_at)
    values
      (p_team_id,p_target_user_id,'member','approved',now());
  end if;

  return jsonb_build_object('added',true,'audit_id',v_audit_id);
end;
$function$;

revoke all on function public.aevnetwork_admin_add_team_member(uuid,uuid,uuid,text,text,uuid) from public, anon, authenticated;
grant execute on function public.aevnetwork_admin_add_team_member(uuid,uuid,uuid,text,text,uuid) to service_role;
