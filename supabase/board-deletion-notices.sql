-- AevTools bulletin board moderation and deletion notices
-- Run once in Supabase SQL Editor after announcements-community-board.sql.

create table if not exists public.aevtools_board_deletion_notices (
  id uuid primary key default gen_random_uuid(),
  recipient_user_id uuid not null references auth.users(id) on delete cascade,
  item_type text not null check (item_type in ('post','reply')),
  item_title text not null default '',
  item_content text not null,
  reason text not null check (char_length(trim(reason)) between 1 and 1000),
  deleted_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  read_at timestamptz
);

create index if not exists aevtools_board_deletion_notices_user_idx
  on public.aevtools_board_deletion_notices(recipient_user_id, created_at desc);

alter table public.aevtools_board_deletion_notices enable row level security;
revoke all on public.aevtools_board_deletion_notices from anon, authenticated;

drop policy if exists "AevTools board posts owner or admin delete" on public.aevtools_board_posts;
create policy "AevTools board posts owner delete" on public.aevtools_board_posts
for delete to authenticated using (user_id = auth.uid());

drop policy if exists "AevTools board comments owner or admin delete" on public.aevtools_board_comments;
create policy "AevTools board comments owner delete" on public.aevtools_board_comments
for delete to authenticated using (user_id = auth.uid());

create or replace function public.aevtools_admin_delete_board_post(p_post_id uuid, p_reason text)
returns boolean
language plpgsql security definer
set search_path = public
as $$
declare v_post public.aevtools_board_posts%rowtype;
begin
  if auth.uid() is null or not public.aevtools_is_admin() then
    raise exception 'admin_required';
  end if;
  if char_length(trim(coalesce(p_reason,''))) not between 1 and 1000 then
    raise exception 'deletion_reason_required';
  end if;
  select * into v_post from public.aevtools_board_posts where id=p_post_id for update;
  if not found then raise exception 'post_not_found'; end if;

  insert into public.aevtools_board_deletion_notices
    (recipient_user_id,item_type,item_title,item_content,reason,deleted_by)
  values
    (v_post.user_id,'post',v_post.title,v_post.body,trim(p_reason),auth.uid());

  -- Replies are cascade-deleted. Only the original post author is notified.
  delete from public.aevtools_board_posts where id=p_post_id;
  return true;
end;
$$;

create or replace function public.aevtools_admin_delete_board_reply(p_reply_id uuid, p_reason text)
returns boolean
language plpgsql security definer
set search_path = public
as $$
declare v_reply public.aevtools_board_comments%rowtype;
begin
  if auth.uid() is null or not public.aevtools_is_admin() then
    raise exception 'admin_required';
  end if;
  if char_length(trim(coalesce(p_reason,''))) not between 1 and 1000 then
    raise exception 'deletion_reason_required';
  end if;
  select * into v_reply from public.aevtools_board_comments where id=p_reply_id for update;
  if not found then raise exception 'reply_not_found'; end if;

  insert into public.aevtools_board_deletion_notices
    (recipient_user_id,item_type,item_title,item_content,reason,deleted_by)
  values
    (v_reply.user_id,'reply','',v_reply.body,trim(p_reason),auth.uid());

  delete from public.aevtools_board_comments where id=p_reply_id;
  return true;
end;
$$;

create or replace function public.aevtools_my_board_deletion_notices()
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
declare v_uid uuid := auth.uid(); v_result jsonb;
begin
  if v_uid is null then raise exception 'login_required'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',id,'item_type',item_type,'item_title',item_title,
    'item_content',item_content,'reason',reason,'created_at',created_at,
    'read_at',read_at
  ) order by created_at desc),'[]'::jsonb)
  into v_result
  from public.aevtools_board_deletion_notices
  where recipient_user_id=v_uid;
  return v_result;
end;
$$;

create or replace function public.aevtools_read_board_deletion_notice(p_notice_id uuid)
returns boolean
language plpgsql security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'login_required'; end if;
  update public.aevtools_board_deletion_notices
  set read_at=coalesce(read_at,now())
  where id=p_notice_id and recipient_user_id=auth.uid();
  return found;
end;
$$;

revoke all on function public.aevtools_admin_delete_board_post(uuid,text) from public;
grant execute on function public.aevtools_admin_delete_board_post(uuid,text) to authenticated;
revoke all on function public.aevtools_admin_delete_board_reply(uuid,text) from public;
grant execute on function public.aevtools_admin_delete_board_reply(uuid,text) to authenticated;
revoke all on function public.aevtools_my_board_deletion_notices() from public;
grant execute on function public.aevtools_my_board_deletion_notices() to authenticated;
revoke all on function public.aevtools_read_board_deletion_notice(uuid) from public;
grant execute on function public.aevtools_read_board_deletion_notice(uuid) to authenticated;
