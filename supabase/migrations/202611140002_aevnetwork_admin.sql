-- AevNetwork administrator features (additive migration)
-- Run in the SAME Supabase project used by AevTools.
-- Does not modify AevTools tables or the single-admin registry.

create extension if not exists pgcrypto;

create table if not exists public.aevnetwork_announcements (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(trim(title)) between 1 and 160),
  body text not null default '' check (char_length(body) <= 6000),
  link_url text,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.aevnetwork_news (
  id uuid primary key default gen_random_uuid(),
  category text not null default 'GAMING' check (char_length(category) between 1 and 40),
  title text not null check (char_length(trim(title)) between 1 and 160),
  body text not null default '' check (char_length(body) <= 10000),
  link_url text,
  published boolean not null default true,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.aevnetwork_updates (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(trim(title)) between 1 and 160),
  body text not null default '' check (char_length(body) <= 10000),
  published boolean not null default true,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.aevnetwork_blacklist (
  user_id uuid primary key references auth.users(id) on delete cascade,
  reason text not null check (char_length(trim(reason)) between 1 and 1000),
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now()
);

create index if not exists aevnetwork_announcements_created_idx on public.aevnetwork_announcements(created_at desc);
create index if not exists aevnetwork_news_created_idx on public.aevnetwork_news(created_at desc);
create index if not exists aevnetwork_updates_created_idx on public.aevnetwork_updates(created_at desc);

alter table public.aevnetwork_announcements enable row level security;
alter table public.aevnetwork_news enable row level security;
alter table public.aevnetwork_updates enable row level security;
alter table public.aevnetwork_blacklist enable row level security;

-- Browser clients cannot directly read or change these tables.
-- The Edge Function uses service-role access only after validating the caller
-- and checking public.aevtools_is_admin() for every administrator action.
revoke all on public.aevnetwork_announcements from anon, authenticated;
revoke all on public.aevnetwork_news from anon, authenticated;
revoke all on public.aevnetwork_updates from anon, authenticated;
revoke all on public.aevnetwork_blacklist from anon, authenticated;
grant all on public.aevnetwork_announcements to service_role;
grant all on public.aevnetwork_news to service_role;
grant all on public.aevnetwork_updates to service_role;
grant all on public.aevnetwork_blacklist to service_role;

-- Server-side admin check for the API. The permanent AevTools admin remains
-- the sole authority; no AevNetwork-specific admin account is created.
create or replace function public.aevnetwork_is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.aevtools_is_admin();
$$;

revoke all on function public.aevnetwork_is_admin() from public;
grant execute on function public.aevnetwork_is_admin() to authenticated;
