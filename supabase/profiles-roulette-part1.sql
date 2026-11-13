-- PART 1/4: Profiles, nicknames, support labels, direct-chat labels
-- Run this first in Supabase SQL Editor.

-- Run once in Supabase SQL Editor AFTER the existing AevTools SQL migrations.
-- Safe to re-run: uses IF NOT EXISTS / CREATE OR REPLACE.

create table if not exists public.aevtools_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  nickname text not null check (char_length(nickname) between 1 and 20),
  updated_at timestamptz not null default now()
);
alter table public.aevtools_profiles enable row level security;
revoke all on public.aevtools_profiles from anon, authenticated;
create unique index if not exists aevtools_profiles_nickname_unique
  on public.aevtools_profiles (lower(nickname));

insert into public.aevtools_profiles(user_id,nickname)
select u.id,
       case when a.user_id is not null then 'Aev0rnJP'
            else 'ユーザー' || upper(substr(replace(u.id::text,'-',''),1,6)) end
from auth.users u
left join public.aevtools_admin a on a.user_id=u.id
on conflict(user_id) do nothing;

create or replace function public.aevtools_profile_json(p_user_id uuid)
returns jsonb language plpgsql stable security definer
set search_path=public,auth
as $$
declare v_nickname text; v_admin boolean;
begin
 if p_user_id is null then return null; end if;
 select nickname into v_nickname from public.aevtools_profiles where user_id=p_user_id;
 select exists(select 1 from public.aevtools_admin where user_id=p_user_id) into v_admin;
 if v_nickname is null then
   select case when v_admin then 'Aev0rnJP' else 'ユーザー' || upper(substr(replace(p_user_id::text,'-',''),1,6)) end
   into v_nickname;
 end if;
 return jsonb_build_object(
   'user_id',p_user_id,
   'nickname',v_nickname,
   'is_admin',v_admin,
   'role_label',case when v_admin then '👑 管理者 / 🛠 開発者' else null end
 );
end;
$$;

create or replace function public.aevtools_get_my_profile()
returns jsonb language plpgsql stable security definer
set search_path=public
as $$
declare v_uid uuid:=auth.uid();
begin
 if v_uid is null then raise exception 'login_required'; end if;
 insert into public.aevtools_profiles(user_id,nickname)
 values(v_uid,case when exists(select 1 from public.aevtools_admin where user_id=v_uid) then 'Aev0rnJP'
                   else 'ユーザー' || upper(substr(replace(v_uid::text,'-',''),1,6)) end)
 on conflict(user_id) do nothing;
 return public.aevtools_profile_json(v_uid);
end;
$$;

create or replace function public.aevtools_update_my_nickname(p_nickname text)
returns jsonb language plpgsql security definer
set search_path=public
as $$
declare v_uid uuid:=auth.uid(); v_name text:=trim(coalesce(p_nickname,''));
begin
 if v_uid is null then raise exception 'login_required'; end if;
 if char_length(v_name) not between 1 and 20 then raise exception 'nickname_length_invalid'; end if;
 if v_name ~ '[[:cntrl:]]' then raise exception 'nickname_invalid'; end if;
 if lower(v_name)='aev0rnjp' and not exists(select 1 from public.aevtools_admin where user_id=v_uid) then
   raise exception 'nickname_reserved';
 end if;
 insert into public.aevtools_profiles(user_id,nickname)
 values(v_uid,v_name)
 on conflict(user_id) do update set nickname=excluded.nickname,updated_at=now();
 update public.aevtools_roulette_participants p
 set nickname=v_name
 from public.aevtools_roulette_rounds r
 where p.round_id=r.id and p.user_id=v_uid and r.status='open';
 perform public.aevtools_roulette_notify();
 return public.aevtools_profile_json(v_uid);
exception when unique_violation then
 raise exception 'nickname_taken';
end;
$$;

-- Keep the existing admin directory but add public nickname and role badge data.
create or replace function public.aevtools_admin_list_users()
returns jsonb language plpgsql stable security definer
set search_path=public,auth
as $$
declare v_result jsonb;
begin
 if auth.uid() is null or not exists(select 1 from public.aevtools_admin where user_id=auth.uid()) then
   raise exception 'admin_required';
 end if;
 select coalesce(jsonb_agg(jsonb_build_object(
   'user_id',u.id,'email',u.email,'created_at',u.created_at,
   'last_sign_in_at',u.last_sign_in_at,'last_seen_at',p.last_seen_at,
   'is_online',coalesce(p.last_seen_at>now()-interval '2 minutes',false),
   'nickname',coalesce(pr.nickname,'ユーザー'||upper(substr(replace(u.id::text,'-',''),1,6))),
   'is_admin',false,'role_label',null
 ) order by u.created_at desc),'[]'::jsonb)
 into v_result
 from auth.users u
 left join public.aevtools_support_presence p on p.user_id=u.id
 left join public.aevtools_profiles pr on pr.user_id=u.id
 where not exists(select 1 from public.aevtools_admin a where a.user_id=u.id);
 return v_result;
end;
$$;

-- Profile-aware support conversation labels.
create or replace function public.aevtools_support_ticket_messages(p_ticket_id uuid)
returns jsonb language plpgsql stable security definer
set search_path=public
as $$
declare v_uid uuid:=auth.uid(); v_admin boolean; v_owner uuid; v_result jsonb;
begin
 if v_uid is null then raise exception 'login_required'; end if;
 select user_id into v_owner from public.aevtools_support_tickets where id=p_ticket_id;
 if v_owner is null then raise exception 'ticket_not_found'; end if;
 select exists(select 1 from public.aevtools_admin where user_id=v_uid) into v_admin;
 if v_uid<>v_owner and not v_admin then raise exception 'not_allowed'; end if;
 select coalesce(jsonb_agg(item order by created_at asc,sort_order asc),'[]'::jsonb)
 into v_result
 from (
   select jsonb_build_object(
     'id','initial-'||t.id::text,'sender','user',
     'label',coalesce((public.aevtools_profile_json(t.user_id)->>'nickname'),'ユーザー'),
     'role_label',null,'message',t.message,'created_at',t.created_at
   ) item,t.created_at,0 sort_order
   from public.aevtools_support_tickets t where t.id=p_ticket_id
   union all
   select jsonb_build_object(
     'id',r.id,'sender',case when exists(select 1 from public.aevtools_admin a where a.user_id=r.sender_user_id) then 'admin' else 'user' end,
     'label',public.aevtools_profile_json(r.sender_user_id)->>'nickname',
     'role_label',public.aevtools_profile_json(r.sender_user_id)->>'role_label',
     'message',r.message,'created_at',r.created_at
   ) item,r.created_at,1 sort_order
   from public.aevtools_support_replies r where r.ticket_id=p_ticket_id
 ) q;
 return v_result;
end;
$$;

-- Profile-aware direct-chat messages.
create or replace function public.aevtools_get_direct_chat_messages(p_chat_id uuid)
returns jsonb language plpgsql stable security definer
set search_path=public,auth
as $$
declare v_uid uuid:=auth.uid(); v_result jsonb;
begin
 if v_uid is null then raise exception 'login_required'; end if;
 if not exists(select 1 from public.aevtools_admin_direct_chats c
   where c.id=p_chat_id and (c.user_id=v_uid or exists(select 1 from public.aevtools_admin a where a.user_id=v_uid))) then
   raise exception 'not_allowed';
 end if;
 select coalesce(jsonb_agg(jsonb_build_object(
   'id',m.id,'sender_user_id',m.sender_user_id,
   'sender_is_admin',exists(select 1 from public.aevtools_admin a where a.user_id=m.sender_user_id),
   'sender_nickname',public.aevtools_profile_json(m.sender_user_id)->>'nickname',
   'role_label',public.aevtools_profile_json(m.sender_user_id)->>'role_label',
   'message',m.message,'created_at',m.created_at
 ) order by m.created_at asc),'[]'::jsonb)
 into v_result from public.aevtools_admin_direct_chat_messages m where m.chat_id=p_chat_id;
 return v_result;
end;
$$;
