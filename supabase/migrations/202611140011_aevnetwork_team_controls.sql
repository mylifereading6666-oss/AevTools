-- AevNetwork team lifecycle, capacity, chat visibility and mediation.
create table if not exists public.aevnetwork_team_chat_preferences (
  team_id uuid not null references public.aevnetwork_teams(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  hidden_before timestamptz,
  hidden_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key(team_id,user_id)
);
create table if not exists public.aevnetwork_team_mediation_requests (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.aevnetwork_teams(id) on delete cascade,
  requester_id uuid not null references auth.users(id) on delete cascade,
  message text not null default '' check (char_length(message) <= 1000),
  status text not null default 'pending' check (status in ('pending','approved','closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(team_id,requester_id,status)
);
create index if not exists aevnetwork_team_mediation_status_idx
  on public.aevnetwork_team_mediation_requests(status,created_at desc);
alter table public.aevnetwork_team_chat_preferences enable row level security;
alter table public.aevnetwork_team_mediation_requests enable row level security;
revoke all on public.aevnetwork_team_chat_preferences from anon, authenticated;
revoke all on public.aevnetwork_team_mediation_requests from anon, authenticated;
grant all on public.aevnetwork_team_chat_preferences to service_role;
grant all on public.aevnetwork_team_mediation_requests to service_role;

create or replace function public.aevnetwork_enforce_team_capacity()
returns trigger language plpgsql security definer set search_path=public as $$
declare approved_count integer;
begin
  if new.status='approved' then
    perform 1 from public.aevnetwork_teams where id=new.team_id for update;
    select count(*) into approved_count
      from public.aevnetwork_team_members m
      where m.team_id=new.team_id and m.status='approved'
        and (tg_op='INSERT' or m.id<>new.id);
    if approved_count >= 4 then raise exception 'team_full'; end if;
  end if;
  return new;
end;
$$;
drop trigger if exists aevnetwork_team_capacity_guard on public.aevnetwork_team_members;
create trigger aevnetwork_team_capacity_guard
before insert or update of status on public.aevnetwork_team_members
for each row execute function public.aevnetwork_enforce_team_capacity();
