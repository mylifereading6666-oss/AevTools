-- AevNetwork community bulletin board with server-mediated authorization.
-- Browser roles cannot access these tables directly; only the Edge Function service role can.
create extension if not exists pgcrypto;

create table if not exists public.aevnetwork_community_posts (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references auth.users(id) on delete restrict,
  title text not null check (char_length(trim(title)) between 1 and 120),
  body text not null check (char_length(trim(body)) between 1 and 5000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  moderated_by uuid references auth.users(id) on delete set null,
  moderation_reason text
);

create table if not exists public.aevnetwork_community_comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.aevnetwork_community_posts(id) on delete cascade,
  author_id uuid not null references auth.users(id) on delete restrict,
  body text not null check (char_length(trim(body)) between 1 and 1500),
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  moderated_by uuid references auth.users(id) on delete set null,
  moderation_reason text
);

create table if not exists public.aevnetwork_community_reports (
  id uuid primary key default gen_random_uuid(),
  target_type text not null check (target_type in ('post','comment')),
  target_id uuid not null,
  reporter_id uuid not null references auth.users(id) on delete cascade,
  reason text not null check (char_length(trim(reason)) between 5 and 500),
  status text not null default 'pending' check (status in ('pending','resolved')),
  created_at timestamptz not null default now(),
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  unique(target_type,target_id,reporter_id)
);

create table if not exists public.aevnetwork_community_moderation_logs (
  id uuid primary key default gen_random_uuid(),
  target_type text not null check (target_type in ('post','comment')),
  target_id uuid not null,
  action text not null check (action in ('remove','dismiss_report')),
  reason text not null,
  admin_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now()
);

create index if not exists aevnetwork_community_posts_created_idx
  on public.aevnetwork_community_posts(created_at desc) where deleted_at is null;
create index if not exists aevnetwork_community_comments_post_idx
  on public.aevnetwork_community_comments(post_id,created_at) where deleted_at is null;
create index if not exists aevnetwork_community_reports_status_idx
  on public.aevnetwork_community_reports(status,created_at desc);

alter table public.aevnetwork_community_posts enable row level security;
alter table public.aevnetwork_community_comments enable row level security;
alter table public.aevnetwork_community_reports enable row level security;
alter table public.aevnetwork_community_moderation_logs enable row level security;

revoke all on public.aevnetwork_community_posts from anon, authenticated;
revoke all on public.aevnetwork_community_comments from anon, authenticated;
revoke all on public.aevnetwork_community_reports from anon, authenticated;
revoke all on public.aevnetwork_community_moderation_logs from anon, authenticated;
grant all on public.aevnetwork_community_posts to service_role;
grant all on public.aevnetwork_community_comments to service_role;
grant all on public.aevnetwork_community_reports to service_role;
grant all on public.aevnetwork_community_moderation_logs to service_role;
