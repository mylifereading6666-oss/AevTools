-- Shared AevTools / AevNetwork announcements.
-- The AevTools announcements table is the single source of truth.
-- Existing AevNetwork announcements are copied once; original rows remain untouched.

insert into public.aevtools_announcements
  (id, title, body, link_url, video_url, created_by, created_at, updated_at)
select
  id, title, body, link_url, null, created_by, created_at, updated_at
from public.aevnetwork_announcements
on conflict (id) do nothing;

-- Announcements are public-readable. Writes remain controlled by the existing
-- AevTools policies and the authenticated AevNetwork Edge Function.
grant select on public.aevtools_announcements to anon, authenticated;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname='public'
      and tablename='aevtools_announcements'
      and policyname='Shared announcements are publicly readable'
  ) then
    create policy "Shared announcements are publicly readable"
      on public.aevtools_announcements
      for select to anon, authenticated
      using (true);
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname='supabase_realtime'
      and schemaname='public'
      and tablename='aevtools_announcements'
  ) then
    alter publication supabase_realtime add table public.aevtools_announcements;
  end if;
end $$;

-- Unify the bulletin board on the AevNetwork community tables.
-- Keep legacy AevTools posts and replies by copying them before switching clients.
alter table public.aevnetwork_community_posts
  add column if not exists author_name text,
  add column if not exists image_url text,
  add column if not exists image_path text;
alter table public.aevnetwork_community_comments
  add column if not exists author_name text;

alter table public.aevnetwork_community_posts
  drop constraint if exists aevnetwork_community_posts_title_check;
alter table public.aevnetwork_community_posts
  drop constraint if exists aevnetwork_community_posts_body_check;
alter table public.aevnetwork_community_posts
  add constraint aevnetwork_community_posts_title_check
    check (char_length(trim(title)) between 1 and 160),
  add constraint aevnetwork_community_posts_body_check
    check (char_length(trim(body)) between 1 and 6000);
alter table public.aevnetwork_community_comments
  drop constraint if exists aevnetwork_community_comments_body_check;
alter table public.aevnetwork_community_comments
  add constraint aevnetwork_community_comments_body_check
    check (char_length(trim(body)) between 1 and 2000);

-- Migrate existing AevTools board posts and replies. Existing source rows are
-- intentionally retained as a backup; duplicate IDs are skipped.
insert into public.aevnetwork_community_posts
  (id, author_id, author_name, title, body, image_url, image_path, created_at, updated_at)
select
  id, user_id, author_name, title, body, image_url, image_path, created_at, created_at
from public.aevtools_board_posts
where user_id is not null
on conflict (id) do nothing;

insert into public.aevnetwork_community_comments
  (id, post_id, author_id, author_name, body, created_at)
select
  c.id, c.post_id, c.user_id, c.author_name, c.body, c.created_at
from public.aevtools_board_comments c
join public.aevnetwork_community_posts p on p.id=c.post_id
where c.user_id is not null
on conflict (id) do nothing;

-- Public read only is required for anonymous viewing and Realtime delivery.
-- All writes continue to go through the authenticated Edge Function.
grant select on public.aevnetwork_community_posts to anon, authenticated;
grant select on public.aevnetwork_community_comments to anon, authenticated;
do $$
begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='aevnetwork_community_posts' and policyname='Public can read active shared board posts') then
    create policy "Public can read active shared board posts"
      on public.aevnetwork_community_posts for select to anon, authenticated
      using (deleted_at is null);
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='aevnetwork_community_comments' and policyname='Public can read active shared board comments') then
    create policy "Public can read active shared board comments"
      on public.aevnetwork_community_comments for select to anon, authenticated
      using (deleted_at is null);
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='aevnetwork_community_posts') then
    alter publication supabase_realtime add table public.aevnetwork_community_posts;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='aevnetwork_community_comments') then
    alter publication supabase_realtime add table public.aevnetwork_community_comments;
  end if;
end $$;


-- Shared bulletin-board deletion notices, matching AevTools behavior.
create table if not exists public.aevnetwork_community_deletion_notices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  item_type text not null check (item_type in ('post','comment')),
  item_title text,
  item_content text not null,
  reason text not null,
  created_at timestamptz not null default now(),
  read_at timestamptz
);

create index if not exists aevnetwork_community_deletion_notices_user_created_idx
  on public.aevnetwork_community_deletion_notices(user_id, created_at desc);

alter table public.aevnetwork_community_deletion_notices enable row level security;
revoke all on public.aevnetwork_community_deletion_notices from anon, authenticated;
grant all on public.aevnetwork_community_deletion_notices to service_role;

drop function if exists public.aevtools_my_board_deletion_notices();
create function public.aevtools_my_board_deletion_notices()
returns table (
  id uuid,
  item_type text,
  item_title text,
  item_content text,
  reason text,
  created_at timestamptz,
  read_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select n.id, n.item_type, n.item_title, n.item_content, n.reason, n.created_at, n.read_at
  from public.aevnetwork_community_deletion_notices n
  where n.user_id = auth.uid()
  order by n.created_at desc;
$$;

drop function if exists public.aevtools_read_board_deletion_notice(uuid);
create function public.aevtools_read_board_deletion_notice(p_notice_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.aevnetwork_community_deletion_notices
  set read_at = coalesce(read_at, now())
  where id = p_notice_id and user_id = auth.uid();
  return found;
end;
$$;

grant execute on function public.aevtools_my_board_deletion_notices() to authenticated;
grant execute on function public.aevtools_read_board_deletion_notice(uuid) to authenticated;
