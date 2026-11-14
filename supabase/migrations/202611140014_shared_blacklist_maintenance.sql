-- Shared AevTools / AevNetwork blacklist and maintenance controls.
-- Run once in the Supabase SQL Editor for project vuqbbwdojwmtehgsyfaq.

-- Keep both existing blacklist screens, but synchronize them bidirectionally.
-- AevTools support blacklist and AevNetwork blacklist become one logical list.
insert into public.aevnetwork_blacklist(user_id, reason, created_by, created_at)
select user_id, coalesce(nullif(trim(reason),''),'AevTools support restriction'), admin_user_id, created_at
from public.aevtools_support_blacklist
on conflict (user_id) do nothing;

insert into public.aevtools_support_blacklist(user_id, admin_user_id, reason, created_at)
select user_id, created_by, reason, created_at
from public.aevnetwork_blacklist
on conflict (user_id) do nothing;

create or replace function public.sync_aevtools_blacklist_to_network()
returns trigger language plpgsql security definer set search_path=public
as $$
begin
  if pg_trigger_depth() > 1 then
    if TG_OP='DELETE' then return OLD; else return NEW; end if;
  end if;
  if TG_OP='DELETE' then
    delete from public.aevnetwork_blacklist where user_id=OLD.user_id;
    return OLD;
  end if;
  insert into public.aevnetwork_blacklist(user_id,reason,created_by,created_at)
  values(NEW.user_id,coalesce(nullif(trim(NEW.reason),''),'AevTools support restriction'),NEW.admin_user_id,NEW.created_at)
  on conflict(user_id) do update set reason=excluded.reason,created_by=excluded.created_by,created_at=excluded.created_at;
  return NEW;
end $$;

create or replace function public.sync_aevnetwork_blacklist_to_tools()
returns trigger language plpgsql security definer set search_path=public
as $$
begin
  if pg_trigger_depth() > 1 then
    if TG_OP='DELETE' then return OLD; else return NEW; end if;
  end if;
  if TG_OP='DELETE' then
    delete from public.aevtools_support_blacklist where user_id=OLD.user_id;
    return OLD;
  end if;
  insert into public.aevtools_support_blacklist(user_id,admin_user_id,reason,created_at)
  values(NEW.user_id,NEW.created_by,NEW.reason,NEW.created_at)
  on conflict(user_id) do update set admin_user_id=excluded.admin_user_id,reason=excluded.reason,created_at=excluded.created_at;
  return NEW;
end $$;

drop trigger if exists aevtools_blacklist_sync_to_network on public.aevtools_support_blacklist;
create trigger aevtools_blacklist_sync_to_network
after insert or update or delete on public.aevtools_support_blacklist
for each row execute function public.sync_aevtools_blacklist_to_network();

drop trigger if exists aevnetwork_blacklist_sync_to_tools on public.aevnetwork_blacklist;
create trigger aevnetwork_blacklist_sync_to_tools
after insert or update or delete on public.aevnetwork_blacklist
for each row execute function public.sync_aevnetwork_blacklist_to_tools();

-- Shared maintenance switch. The permanent AevTools administrator alone can change it.
create table if not exists public.aevtools_service_control (
  singleton boolean primary key default true check (singleton),
  maintenance_enabled boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);
insert into public.aevtools_service_control(singleton,maintenance_enabled)
values(true,false) on conflict(singleton) do nothing;
alter table public.aevtools_service_control enable row level security;
revoke all on public.aevtools_service_control from anon, authenticated, public;

create or replace function public.aevtools_get_service_maintenance()
returns boolean language sql stable security definer set search_path=public
as $$
  select coalesce((select maintenance_enabled from public.aevtools_service_control where singleton=true),false);
$$;

create or replace function public.aevtools_set_service_maintenance(p_enabled boolean)
returns boolean language plpgsql security definer set search_path=public
as $$
begin
  if auth.uid() is null or not exists(select 1 from public.aevtools_admin where user_id=auth.uid()) then
    raise exception 'admin_required';
  end if;
  insert into public.aevtools_service_control(singleton,maintenance_enabled,updated_at,updated_by)
  values(true,coalesce(p_enabled,false),now(),auth.uid())
  on conflict(singleton) do update
    set maintenance_enabled=excluded.maintenance_enabled,updated_at=excluded.updated_at,updated_by=excluded.updated_by;
  return true;
end $$;

revoke all on function public.aevtools_get_service_maintenance() from public;
grant execute on function public.aevtools_get_service_maintenance() to anon, authenticated;
revoke all on function public.aevtools_set_service_maintenance(boolean) from public;
grant execute on function public.aevtools_set_service_maintenance(boolean) to authenticated;
