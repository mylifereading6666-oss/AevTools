-- AevTools: announcements and community bulletin board
-- Run once in Supabase SQL Editor.

create table if not exists public.aevtools_announcements (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(trim(title)) between 1 and 160),
  body text not null default '' check (char_length(body) <= 6000),
  link_url text,
  video_url text,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.aevtools_board_posts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  author_name text not null default 'ユーザー',
  title text not null check (char_length(trim(title)) between 1 and 160),
  body text not null check (char_length(trim(body)) between 1 and 6000),
  image_url text,
  image_path text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.aevtools_board_posts add column if not exists image_path text;

create table if not exists public.aevtools_board_comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.aevtools_board_posts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  author_name text not null default 'ユーザー',
  body text not null check (char_length(trim(body)) between 1 and 2000),
  created_at timestamptz not null default now()
);

create index if not exists aevtools_announcements_created_idx on public.aevtools_announcements(created_at desc);
create index if not exists aevtools_board_posts_created_idx on public.aevtools_board_posts(created_at desc);
create index if not exists aevtools_board_comments_post_idx on public.aevtools_board_comments(post_id, created_at);

alter table public.aevtools_announcements enable row level security;
alter table public.aevtools_board_posts enable row level security;
alter table public.aevtools_board_comments enable row level security;

drop policy if exists "AevTools announcements public read" on public.aevtools_announcements;
create policy "AevTools announcements public read" on public.aevtools_announcements
for select to anon, authenticated using (true);

drop policy if exists "AevTools announcements admin insert" on public.aevtools_announcements;
create policy "AevTools announcements admin insert" on public.aevtools_announcements
for insert to authenticated with check (
  created_by = auth.uid()
  and exists(select 1 from public.aevtools_admin where user_id=auth.uid())
);

drop policy if exists "AevTools announcements admin update" on public.aevtools_announcements;
create policy "AevTools announcements admin update" on public.aevtools_announcements
for update to authenticated using (
  exists(select 1 from public.aevtools_admin where user_id=auth.uid())
) with check (
  exists(select 1 from public.aevtools_admin where user_id=auth.uid())
);

drop policy if exists "AevTools announcements admin delete" on public.aevtools_announcements;
create policy "AevTools announcements admin delete" on public.aevtools_announcements
for delete to authenticated using (
  exists(select 1 from public.aevtools_admin where user_id=auth.uid())
);

drop policy if exists "AevTools board posts public read" on public.aevtools_board_posts;
create policy "AevTools board posts public read" on public.aevtools_board_posts
for select to anon, authenticated using (true);

drop policy if exists "AevTools board posts authenticated insert" on public.aevtools_board_posts;
create policy "AevTools board posts authenticated insert" on public.aevtools_board_posts
for insert to authenticated with check (user_id=auth.uid());

drop policy if exists "AevTools board posts owner or admin update" on public.aevtools_board_posts;
create policy "AevTools board posts owner or admin update" on public.aevtools_board_posts
for update to authenticated using (
  user_id=auth.uid() or exists(select 1 from public.aevtools_admin where user_id=auth.uid())
) with check (
  user_id=auth.uid() or exists(select 1 from public.aevtools_admin where user_id=auth.uid())
);

drop policy if exists "AevTools board posts owner or admin delete" on public.aevtools_board_posts;
create policy "AevTools board posts owner or admin delete" on public.aevtools_board_posts
for delete to authenticated using (
  user_id=auth.uid() or exists(select 1 from public.aevtools_admin where user_id=auth.uid())
);

drop policy if exists "AevTools board comments public read" on public.aevtools_board_comments;
create policy "AevTools board comments public read" on public.aevtools_board_comments
for select to anon, authenticated using (true);

drop policy if exists "AevTools board comments authenticated insert" on public.aevtools_board_comments;
create policy "AevTools board comments authenticated insert" on public.aevtools_board_comments
for insert to authenticated with check (user_id=auth.uid());

drop policy if exists "AevTools board comments owner or admin delete" on public.aevtools_board_comments;
create policy "AevTools board comments owner or admin delete" on public.aevtools_board_comments
for delete to authenticated using (
  user_id=auth.uid() or exists(select 1 from public.aevtools_admin where user_id=auth.uid())
);

-- The author label is assigned by the database, not trusted from the browser.
create or replace function public.aevtools_board_set_author()
returns trigger language plpgsql security definer set search_path=public
as $$
begin
  new.author_name := coalesce(public.aevtools_profile_json(new.user_id)->>'nickname','ユーザー');
  return new;
end;
$$;

drop trigger if exists aevtools_board_posts_author on public.aevtools_board_posts;
create trigger aevtools_board_posts_author before insert on public.aevtools_board_posts
for each row execute function public.aevtools_board_set_author();

drop trigger if exists aevtools_board_comments_author on public.aevtools_board_comments;
create trigger aevtools_board_comments_author before insert on public.aevtools_board_comments
for each row execute function public.aevtools_board_set_author();

-- Public image bucket; authenticated users may upload only into their own UUID folder.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('aev-board-images','aev-board-images',true,5242880,array['image/jpeg','image/png','image/webp','image/gif'])
on conflict(id) do update set public=true,file_size_limit=5242880,allowed_mime_types=array['image/jpeg','image/png','image/webp','image/gif'];

drop policy if exists "AevTools board images public read" on storage.objects;
create policy "AevTools board images public read" on storage.objects
for select to anon, authenticated using (bucket_id='aev-board-images');

drop policy if exists "AevTools board images owner upload" on storage.objects;
create policy "AevTools board images owner upload" on storage.objects
for insert to authenticated with check (
  bucket_id='aev-board-images' and (storage.foldername(name))[1]=auth.uid()::text
);

drop policy if exists "AevTools board images owner delete" on storage.objects;
create policy "AevTools board images owner delete" on storage.objects
for delete to authenticated using (
  bucket_id='aev-board-images' and (
    (storage.foldername(name))[1]=auth.uid()::text
    or exists(select 1 from public.aevtools_admin where user_id=auth.uid())
  )
);

grant select, insert, update, delete on public.aevtools_announcements to authenticated;
grant select on public.aevtools_announcements to anon;
grant select, insert, update, delete on public.aevtools_board_posts to authenticated;
grant select on public.aevtools_board_posts to anon;
grant select, insert, delete on public.aevtools_board_comments to authenticated;
grant select on public.aevtools_board_comments to anon;
