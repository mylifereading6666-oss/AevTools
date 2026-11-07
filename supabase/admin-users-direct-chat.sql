-- AevTools individual chat close/reopen support
-- Run this AFTER the existing admin-users-direct-chat.sql.
alter table public.aevtools_admin_direct_chats
  add column if not exists status text not null default 'open'
    check (status in ('open','closed')),
  add column if not exists closed_at timestamptz,
  add column if not exists closed_by uuid references auth.users(id);

create or replace function public.aevtools_admin_close_direct_chat(p_chat_id uuid)
returns boolean language plpgsql security definer set search_path=public
as $$
begin
 if auth.uid() is null or not exists(select 1 from public.aevtools_admin where user_id=auth.uid()) then
   raise exception 'admin_required';
 end if;
 update public.aevtools_admin_direct_chats
 set status='closed',closed_at=now(),closed_by=auth.uid()
 where id=p_chat_id;
 if not found then raise exception 'chat_not_found'; end if;
 return true;
end; $$;

create or replace function public.aevtools_admin_reopen_direct_chat(p_chat_id uuid)
returns boolean language plpgsql security definer set search_path=public
as $$
begin
 if auth.uid() is null or not exists(select 1 from public.aevtools_admin where user_id=auth.uid()) then
   raise exception 'admin_required';
 end if;
 update public.aevtools_admin_direct_chats
 set status='open',closed_at=null,closed_by=null
 where id=p_chat_id;
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
 insert into public.aevtools_admin_direct_chat_messages(chat_id,sender_user_id,message)
 values(p_chat_id,v_uid,trim(p_message)) returning id into v_id;
 return v_id;
end; $$;

create or replace function public.aevtools_list_direct_chats()
returns jsonb language plpgsql stable security definer set search_path=public,auth
as $$
declare v_uid uuid:=auth.uid(); v_admin boolean; v_result jsonb;
begin
 if v_uid is null then raise exception 'login_required'; end if;
 select exists(select 1 from public.aevtools_admin where user_id=v_uid) into v_admin;
 select coalesce(jsonb_agg(jsonb_build_object(
   'id',c.id,'user_id',c.user_id,'user_email',u.email,'created_at',c.created_at,
   'last_seen_at',p.last_seen_at,
   'is_online',coalesce(p.last_seen_at > now()-interval '2 minutes',false),
   'status',c.status,'closed_at',c.closed_at
 ) order by c.created_at desc),'[]'::jsonb)
 into v_result
 from public.aevtools_admin_direct_chats c
 join auth.users u on u.id=c.user_id
 left join public.aevtools_support_presence p on p.user_id=c.user_id
 where v_admin or c.user_id=v_uid;
 return v_result;
end; $$;

revoke all on function public.aevtools_admin_close_direct_chat(uuid) from public;
grant execute on function public.aevtools_admin_close_direct_chat(uuid) to authenticated;
revoke all on function public.aevtools_admin_reopen_direct_chat(uuid) from public;
grant execute on function public.aevtools_admin_reopen_direct_chat(uuid) to authenticated;
