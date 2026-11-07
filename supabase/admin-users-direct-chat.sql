-- AevTools admin user directory and admin-created private chats
-- Run in Supabase SQL Editor AFTER support-tickets.sql and support-realtime.sql.

create table if not exists public.aevtools_admin_direct_chats (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now()
);
create table if not exists public.aevtools_admin_direct_chat_messages (
  id uuid primary key default gen_random_uuid(),
  chat_id uuid not null references public.aevtools_admin_direct_chats(id) on delete cascade,
  sender_user_id uuid not null references auth.users(id) on delete cascade,
  message text not null check (char_length(message) between 1 and 4000),
  created_at timestamptz not null default now()
);
create index if not exists aevtools_admin_direct_chat_messages_idx
  on public.aevtools_admin_direct_chat_messages(chat_id, created_at);

alter table public.aevtools_admin_direct_chats enable row level security;
alter table public.aevtools_admin_direct_chat_messages enable row level security;
revoke all on public.aevtools_admin_direct_chats from anon, authenticated;
revoke all on public.aevtools_admin_direct_chat_messages from anon, authenticated;

-- Admin-only directory of registered accounts. Passwords/tokens are never returned.
create or replace function public.aevtools_admin_list_users()
returns jsonb language plpgsql stable security definer
set search_path = public, auth
as $$
declare v_result jsonb;
begin
  if auth.uid() is null or not exists(select 1 from public.aevtools_admin where user_id=auth.uid()) then
    raise exception 'admin_required';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id',u.id,
    'email',u.email,
    'created_at',u.created_at,
    'last_sign_in_at',u.last_sign_in_at,
    'last_seen_at',p.last_seen_at,
    'is_online',coalesce(p.last_seen_at > now()-interval '2 minutes',false)
  ) order by u.created_at desc),'[]'::jsonb)
  into v_result
  from auth.users u
  left join public.aevtools_support_presence p on p.user_id=u.id
  where not exists(select 1 from public.aevtools_admin a where a.user_id=u.id);
  return v_result;
end;
$$;

-- Only the permanent admin can create a private chat. One chat per user.
create or replace function public.aevtools_admin_create_direct_chat(p_user_id uuid)
returns uuid language plpgsql security definer
set search_path = public
as $$
declare v_chat_id uuid;
begin
  if auth.uid() is null or not exists(select 1 from public.aevtools_admin where user_id=auth.uid()) then
    raise exception 'admin_required';
  end if;
  if p_user_id is null or p_user_id=auth.uid()
     or exists(select 1 from public.aevtools_admin where user_id=p_user_id)
     or not exists(select 1 from auth.users where id=p_user_id) then
    raise exception 'invalid_target_user';
  end if;
  insert into public.aevtools_admin_direct_chats(user_id,created_by)
  values(p_user_id,auth.uid())
  on conflict(user_id) do nothing;
  select id into v_chat_id from public.aevtools_admin_direct_chats where user_id=p_user_id;
  return v_chat_id;
end;
$$;

-- Admin sees all their created chats; a user sees only their own admin-created chat.
create or replace function public.aevtools_list_direct_chats()
returns jsonb language plpgsql stable security definer
set search_path = public, auth
as $$
declare v_uid uuid:=auth.uid(); v_admin boolean; v_result jsonb;
begin
  if v_uid is null then raise exception 'login_required'; end if;
  select exists(select 1 from public.aevtools_admin where user_id=v_uid) into v_admin;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',c.id,'user_id',c.user_id,'user_email',u.email,'created_at',c.created_at,
    'last_seen_at',p.last_seen_at,
    'is_online',coalesce(p.last_seen_at > now()-interval '2 minutes',false)
  ) order by c.created_at desc),'[]'::jsonb)
  into v_result
  from public.aevtools_admin_direct_chats c
  join auth.users u on u.id=c.user_id
  left join public.aevtools_support_presence p on p.user_id=c.user_id
  where v_admin or c.user_id=v_uid;
  return v_result;
end;
$$;

create or replace function public.aevtools_get_direct_chat_messages(p_chat_id uuid)
returns jsonb language plpgsql stable security definer
set search_path = public, auth
as $$
declare v_uid uuid:=auth.uid(); v_result jsonb;
begin
  if v_uid is null then raise exception 'login_required'; end if;
  if not exists(
    select 1 from public.aevtools_admin_direct_chats c
    where c.id=p_chat_id and (c.user_id=v_uid or exists(select 1 from public.aevtools_admin a where a.user_id=v_uid))
  ) then raise exception 'not_allowed'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',m.id,'sender_user_id',m.sender_user_id,
    'sender_is_admin',exists(select 1 from public.aevtools_admin a where a.user_id=m.sender_user_id),
    'message',m.message,'created_at',m.created_at
  ) order by m.created_at asc),'[]'::jsonb)
  into v_result from public.aevtools_admin_direct_chat_messages m where m.chat_id=p_chat_id;
  return v_result;
end;
$$;

create or replace function public.aevtools_send_direct_chat_message(p_chat_id uuid,p_message text)
returns uuid language plpgsql security definer
set search_path = public
as $$
declare v_uid uuid:=auth.uid(); v_user uuid; v_id uuid;
begin
  if v_uid is null then raise exception 'login_required'; end if;
  if char_length(trim(coalesce(p_message,''))) not between 1 and 4000 then raise exception 'invalid_message'; end if;
  select user_id into v_user from public.aevtools_admin_direct_chats where id=p_chat_id;
  if v_user is null then raise exception 'chat_not_found'; end if;
  if v_uid<>v_user and not exists(select 1 from public.aevtools_admin where user_id=v_uid) then
    raise exception 'not_allowed';
  end if;
  insert into public.aevtools_admin_direct_chat_messages(chat_id,sender_user_id,message)
  values(p_chat_id,v_uid,trim(p_message)) returning id into v_id;
  return v_id;
end;
$$;

revoke all on function public.aevtools_admin_list_users() from public;
grant execute on function public.aevtools_admin_list_users() to authenticated;
revoke all on function public.aevtools_admin_create_direct_chat(uuid) from public;
grant execute on function public.aevtools_admin_create_direct_chat(uuid) to authenticated;
revoke all on function public.aevtools_list_direct_chats() from public;
grant execute on function public.aevtools_list_direct_chats() to authenticated;
revoke all on function public.aevtools_get_direct_chat_messages(uuid) from public;
grant execute on function public.aevtools_get_direct_chat_messages(uuid) to authenticated;
revoke all on function public.aevtools_send_direct_chat_message(uuid,text) from public;
grant execute on function public.aevtools_send_direct_chat_message(uuid,text) to authenticated;

-- User presence heartbeat: call this after login and periodically while the page is open.

-- Private Realtime channel authorization for each direct chat.
drop policy if exists "AevTools direct chat participants can read realtime messages" on realtime.messages;
create policy "AevTools direct chat participants can read realtime messages"
on realtime.messages for select to authenticated
using (
  realtime.topic() like 'aev-direct:%'
  and exists (
    select 1 from public.aevtools_admin_direct_chats c
    where c.id::text = split_part(realtime.topic(), ':', 2)
      and (c.user_id=auth.uid() or exists(select 1 from public.aevtools_admin a where a.user_id=auth.uid()))
  )
);

drop policy if exists "AevTools direct chat participants can send realtime messages" on realtime.messages;
create policy "AevTools direct chat participants can send realtime messages"
on realtime.messages for insert to authenticated
with check (
  realtime.topic() like 'aev-direct:%'
  and exists (
    select 1 from public.aevtools_admin_direct_chats c
    where c.id::text = split_part(realtime.topic(), ':', 2)
      and (c.user_id=auth.uid() or exists(select 1 from public.aevtools_admin a where a.user_id=auth.uid()))
  )
);


-- AevTools individual chat close/reopen support
alter table public.aevtools_admin_direct_chats
  add column if not exists status text not null default 'open' check (status in ('open','closed')),
  add column if not exists closed_at timestamptz,
  add column if not exists closed_by uuid references auth.users(id);

create or replace function public.aevtools_admin_close_direct_chat(p_chat_id uuid)
returns boolean language plpgsql security definer set search_path=public
as $$
begin
 if auth.uid() is null or not exists(select 1 from public.aevtools_admin where user_id=auth.uid()) then raise exception 'admin_required'; end if;
 update public.aevtools_admin_direct_chats set status='closed',closed_at=now(),closed_by=auth.uid() where id=p_chat_id;
 if not found then raise exception 'chat_not_found'; end if;
 return true;
end; $$;

create or replace function public.aevtools_admin_reopen_direct_chat(p_chat_id uuid)
returns boolean language plpgsql security definer set search_path=public
as $$
begin
 if auth.uid() is null or not exists(select 1 from public.aevtools_admin where user_id=auth.uid()) then raise exception 'admin_required'; end if;
 update public.aevtools_admin_direct_chats set status='open',closed_at=null,closed_by=null where id=p_chat_id;
 if not found then raise exception 'chat_not_found'; end if;
 return true;
end; $$;

create or replace function public.aevtools_send_direct_chat_message(p_chat_id uuid,p_message text)
returns uuid language plpgsql security definer set search_path=public
as $$
declare v_uid uuid:=auth.uid(); v_user uuid; v_status text; v_id uuid;
begin
 if v_uid is null then raise exception 'login_required'; end if;
 if char_length(trim(coalesce(p_message,''))) not between 1 and 4000 then raise exception 'invalid_message'; end if;
 select user_id,status into v_user,v_status from public.aevtools_admin_direct_chats where id=p_chat_id;
 if v_user is null then raise exception 'chat_not_found'; end if;
 if v_uid<>v_user and not exists(select 1 from public.aevtools_admin where user_id=v_uid) then raise exception 'not_allowed'; end if;
 if v_status='closed' then raise exception 'chat_closed'; end if;
 insert into public.aevtools_admin_direct_chat_messages(chat_id,sender_user_id,message) values(p_chat_id,v_uid,trim(p_message)) returning id into v_id;
 return v_id;
end; $$;

create or replace function public.aevtools_list_direct_chats()
returns jsonb language plpgsql stable security definer set search_path=public,auth
as $$
declare v_uid uuid:=auth.uid(); v_admin boolean; v_result jsonb;
begin
 if v_uid is null then raise exception 'login_required'; end if;
 select exists(select 1 from public.aevtools_admin where user_id=v_uid) into v_admin;
 select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'user_id',c.user_id,'user_email',u.email,'created_at',c.created_at,'last_seen_at',p.last_seen_at,'is_online',coalesce(p.last_seen_at > now()-interval '2 minutes',false),'status',c.status,'closed_at',c.closed_at) order by c.created_at desc),'[]'::jsonb)
 into v_result from public.aevtools_admin_direct_chats c join auth.users u on u.id=c.user_id left join public.aevtools_support_presence p on p.user_id=c.user_id where v_admin or c.user_id=v_uid;
 return v_result;
end; $$;

revoke all on function public.aevtools_admin_close_direct_chat(uuid) from public;
grant execute on function public.aevtools_admin_close_direct_chat(uuid) to authenticated;
revoke all on function public.aevtools_admin_reopen_direct_chat(uuid) from public;
grant execute on function public.aevtools_admin_reopen_direct_chat(uuid) to authenticated;
