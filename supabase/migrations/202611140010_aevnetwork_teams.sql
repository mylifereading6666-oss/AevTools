-- AevNetwork teams, applications and private team chat.
create extension if not exists pgcrypto;
create table if not exists public.aevnetwork_teams (
 id uuid primary key default gen_random_uuid(),
 name text not null check (char_length(trim(name)) between 2 and 32),
 description text not null default '' check (char_length(description) <= 1000),
 game text not null default '' check (char_length(game) <= 60),
 owner_id uuid not null references auth.users(id) on delete restrict,
 created_at timestamptz not null default now()
);
create table if not exists public.aevnetwork_team_members (
 id uuid primary key default gen_random_uuid(),
 team_id uuid not null references public.aevnetwork_teams(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 role text not null default 'member' check (role in ('leader','member')),
 status text not null default 'pending' check (status in ('pending','approved','rejected')),
 created_at timestamptz not null default now(),
 reviewed_at timestamptz,
 unique(team_id,user_id)
);
create table if not exists public.aevnetwork_team_messages (
 id uuid primary key default gen_random_uuid(),
 team_id uuid not null references public.aevnetwork_teams(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete restrict,
 body text not null check (char_length(trim(body)) between 1 and 2000),
 created_at timestamptz not null default now()
);
create index if not exists aevnetwork_teams_created_idx on public.aevnetwork_teams(created_at desc);
create index if not exists aevnetwork_team_members_user_idx on public.aevnetwork_team_members(user_id,status);
create index if not exists aevnetwork_team_members_team_idx on public.aevnetwork_team_members(team_id,status);
create index if not exists aevnetwork_team_messages_team_idx on public.aevnetwork_team_messages(team_id,created_at desc);
alter table public.aevnetwork_teams enable row level security;
alter table public.aevnetwork_team_members enable row level security;
alter table public.aevnetwork_team_messages enable row level security;
revoke all on public.aevnetwork_teams from anon, authenticated;
revoke all on public.aevnetwork_team_members from anon, authenticated;
revoke all on public.aevnetwork_team_messages from anon, authenticated;
grant all on public.aevnetwork_teams to service_role;
grant all on public.aevnetwork_team_members to service_role;
grant all on public.aevnetwork_team_messages to service_role;
