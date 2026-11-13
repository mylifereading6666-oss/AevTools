-- AevTools profiles, grouped navigation support, realtime roulette and winner chat
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

-- Roulette round and participant records. Exactly one active round at a time.
create table if not exists public.aevtools_roulette_rounds (
 id uuid primary key default gen_random_uuid(),
 status text not null default 'open' check(status in ('open','spinning','finished','cancelled')),
 spin_duration_seconds integer not null default 10 check(spin_duration_seconds between 3 and 120),
 winner_user_id uuid references auth.users(id) on delete set null,
 created_by uuid not null references auth.users(id) on delete restrict,
 created_at timestamptz not null default now(),
 started_at timestamptz,
 finished_at timestamptz
);
create unique index if not exists aevtools_roulette_one_active_round
 on public.aevtools_roulette_rounds ((true)) where status in ('open','spinning');
create table if not exists public.aevtools_roulette_participants (
 id uuid primary key default gen_random_uuid(),
 round_id uuid not null references public.aevtools_roulette_rounds(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 nickname text not null,
 weight integer not null default 1 check(weight between 1 and 1000),
 joined_at timestamptz not null default now(),
 unique(round_id,user_id)
);
create index if not exists aevtools_roulette_participants_round_idx
 on public.aevtools_roulette_participants(round_id,joined_at);
alter table public.aevtools_roulette_rounds enable row level security;
alter table public.aevtools_roulette_participants enable row level security;
revoke all on public.aevtools_roulette_rounds from anon,authenticated;
revoke all on public.aevtools_roulette_participants from anon,authenticated;

create or replace function public.aevtools_roulette_notify()
returns void language plpgsql security definer set search_path=public
as $$
begin
 perform realtime.send(jsonb_build_object('changed',true),'roulette_changed','aev-roulette',true);
end;
$$;

create or replace function public.aevtools_roulette_get_state()
returns jsonb language plpgsql stable security definer set search_path=public
as $$
declare v_uid uuid:=auth.uid(); v_admin boolean; v_round public.aevtools_roulette_rounds%rowtype; v_parts jsonb;
begin
 if v_uid is null then raise exception 'login_required'; end if;
 select exists(select 1 from public.aevtools_admin where user_id=v_uid) into v_admin;
 select * into v_round from public.aevtools_roulette_rounds
 where status in ('open','spinning')
 order by created_at desc limit 1;
 if not found then
   select * into v_round from public.aevtools_roulette_rounds
   order by created_at desc limit 1;
 end if;
 if v_round.id is null then
   return jsonb_build_object('round',null,'participants','[]'::jsonb,'is_admin',v_admin);
 end if;
 select coalesce(jsonb_agg(jsonb_build_object(
   'user_id',p.user_id,'nickname',p.nickname,'joined_at',p.joined_at,
   'weight',case when v_admin then p.weight else null end,
   'probability',case when v_admin then round(100.0*p.weight/nullif(t.total_weight,0),2) else null end
 ) order by p.joined_at,p.id),'[]'::jsonb)
 into v_parts
 from public.aevtools_roulette_participants p
 cross join (select coalesce(sum(weight),0) total_weight from public.aevtools_roulette_participants where round_id=v_round.id) t
 where p.round_id=v_round.id;
 return jsonb_build_object(
   'round',jsonb_build_object(
     'id',v_round.id,'status',v_round.status,
     'spin_duration_seconds',v_round.spin_duration_seconds,
     'created_at',v_round.created_at,'started_at',v_round.started_at,
     'finished_at',v_round.finished_at,
     'winner_user_id',case when v_round.status='finished' then v_round.winner_user_id else null end,
     'winner_nickname',case when v_round.status='finished' then
       (select nickname from public.aevtools_roulette_participants where round_id=v_round.id and user_id=v_round.winner_user_id)
       else null end
   ),
   'participants',v_parts,'is_admin',v_admin,
   'my_joined',exists(select 1 from public.aevtools_roulette_participants where round_id=v_round.id and user_id=v_uid)
 );
end;
$$;

create or replace function public.aevtools_roulette_create_round(p_spin_duration_seconds integer default 10)
returns uuid language plpgsql security definer set search_path=public
as $$
declare v_uid uuid:=auth.uid(); v_id uuid;
begin
 if v_uid is null or not exists(select 1 from public.aevtools_admin where user_id=v_uid) then raise exception 'admin_required'; end if;
 if p_spin_duration_seconds not between 3 and 120 then raise exception 'invalid_duration'; end if;
 insert into public.aevtools_roulette_rounds(created_by,spin_duration_seconds)
 values(v_uid,p_spin_duration_seconds) returning id into v_id;
 perform public.aevtools_roulette_notify();
 return v_id;
exception when unique_violation then raise exception 'active_round_exists';
end;
$$;

create or replace function public.aevtools_roulette_join()
returns boolean language plpgsql security definer set search_path=public
as $$
declare v_uid uuid:=auth.uid(); v_round_id uuid; v_name text;
begin
 if v_uid is null then raise exception 'login_required'; end if;
 select id into v_round_id from public.aevtools_roulette_rounds where status='open' order by created_at desc limit 1 for update;
 if v_round_id is null then raise exception 'registration_closed'; end if;
 select nickname into v_name from public.aevtools_profiles where user_id=v_uid;
 if v_name is null then
   v_name:=case when exists(select 1 from public.aevtools_admin where user_id=v_uid) then 'Aev0rnJP'
                else 'ユーザー'||upper(substr(replace(v_uid::text,'-',''),1,6)) end;
 end if;
 insert into public.aevtools_roulette_participants(round_id,user_id,nickname)
 values(v_round_id,v_uid,v_name);
 perform public.aevtools_roulette_notify();
 return true;
exception when unique_violation then raise exception 'already_joined';
end;
$$;

create or replace function public.aevtools_roulette_set_duration(p_round_id uuid,p_seconds integer)
returns boolean language plpgsql security definer set search_path=public
as $$
begin
 if auth.uid() is null or not exists(select 1 from public.aevtools_admin where user_id=auth.uid()) then raise exception 'admin_required'; end if;
 if p_seconds not between 3 and 120 then raise exception 'invalid_duration'; end if;
 update public.aevtools_roulette_rounds set spin_duration_seconds=p_seconds where id=p_round_id and status='open';
 if not found then raise exception 'round_not_open'; end if;
 perform public.aevtools_roulette_notify();
 return true;
end;
$$;

create or replace function public.aevtools_roulette_set_weight(p_round_id uuid,p_user_id uuid,p_weight integer)
returns boolean language plpgsql security definer set search_path=public
as $$
begin
 if auth.uid() is null or not exists(select 1 from public.aevtools_admin where user_id=auth.uid()) then raise exception 'admin_required'; end if;
 if p_weight not between 1 and 1000 then raise exception 'invalid_weight'; end if;
 update public.aevtools_roulette_participants set weight=p_weight
 where round_id=p_round_id and user_id=p_user_id
 and exists(select 1 from public.aevtools_roulette_rounds where id=p_round_id and status='open');
 if not found then raise exception 'participant_or_round_not_found'; end if;
 perform public.aevtools_roulette_notify();
 return true;
end;
$$;

create or replace function public.aevtools_roulette_start_spin(p_round_id uuid)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare v_uid uuid:=auth.uid(); v_total bigint; v_roll numeric; v_winner uuid; v_started timestamptz:=now(); v_duration integer;
begin
 if v_uid is null or not exists(select 1 from public.aevtools_admin where user_id=v_uid) then raise exception 'admin_required'; end if;
 select spin_duration_seconds into v_duration from public.aevtools_roulette_rounds where id=p_round_id and status='open' for update;
 if not found then raise exception 'round_not_open'; end if;
 select coalesce(sum(weight),0) into v_total from public.aevtools_roulette_participants where round_id=p_round_id;
 if v_total<=0 then raise exception 'no_participants'; end if;
 v_roll:=random()*v_total;
 select user_id into v_winner from (
   select user_id,sum(weight) over(order by joined_at,id) cumulative
   from public.aevtools_roulette_participants where round_id=p_round_id
 ) q where cumulative>=v_roll order by cumulative limit 1;
 update public.aevtools_roulette_rounds
 set status='spinning',winner_user_id=v_winner,started_at=v_started,finished_at=null
 where id=p_round_id;
 perform public.aevtools_roulette_notify();
 return jsonb_build_object('started_at',v_started,'duration_seconds',v_duration);
end;
$$;

create or replace function public.aevtools_roulette_finish_spin(p_round_id uuid)
returns boolean language plpgsql security definer set search_path=public
as $$
begin
 if auth.uid() is null then raise exception 'login_required'; end if;
 update public.aevtools_roulette_rounds
 set status='finished',finished_at=now()
 where id=p_round_id and status='spinning'
 and started_at+make_interval(secs=>spin_duration_seconds)<=now();
 if found then perform public.aevtools_roulette_notify(); return true; end if;
 return false;
end;
$$;

-- Winner-only private chat. Deleting the chat cascades and permanently deletes all messages.
create table if not exists public.aevtools_roulette_winner_chats (
 id uuid primary key default gen_random_uuid(),
 round_id uuid not null unique references public.aevtools_roulette_rounds(id) on delete cascade,
 winner_user_id uuid not null references auth.users(id) on delete cascade,
 created_by uuid not null references auth.users(id) on delete restrict,
 created_at timestamptz not null default now()
);
create table if not exists public.aevtools_roulette_winner_chat_messages (
 id uuid primary key default gen_random_uuid(),
 chat_id uuid not null references public.aevtools_roulette_winner_chats(id) on delete cascade,
 sender_user_id uuid not null references auth.users(id) on delete cascade,
 message text not null check(char_length(message) between 1 and 4000),
 created_at timestamptz not null default now()
);
alter table public.aevtools_roulette_winner_chats enable row level security;
alter table public.aevtools_roulette_winner_chat_messages enable row level security;
revoke all on public.aevtools_roulette_winner_chats from anon,authenticated;
revoke all on public.aevtools_roulette_winner_chat_messages from anon,authenticated;

create or replace function public.aevtools_roulette_create_winner_chat(p_round_id uuid)
returns uuid language plpgsql security definer set search_path=public
as $$
declare v_uid uuid:=auth.uid(); v_winner uuid; v_id uuid;
begin
 if v_uid is null or not exists(select 1 from public.aevtools_admin where user_id=v_uid) then raise exception 'admin_required'; end if;
 select winner_user_id into v_winner from public.aevtools_roulette_rounds where id=p_round_id and status='finished';
 if v_winner is null then raise exception 'round_not_finished'; end if;
 insert into public.aevtools_roulette_winner_chats(round_id,winner_user_id,created_by)
 values(p_round_id,v_winner,v_uid)
 on conflict(round_id) do nothing;
 select id into v_id from public.aevtools_roulette_winner_chats where round_id=p_round_id;
 perform public.aevtools_roulette_notify();
 return v_id;
end;
$$;

create or replace function public.aevtools_roulette_list_winner_chats()
returns jsonb language plpgsql stable security definer set search_path=public
as $$
declare v_uid uuid:=auth.uid(); v_result jsonb;
begin
 if v_uid is null then raise exception 'login_required'; end if;
 select coalesce(jsonb_agg(jsonb_build_object(
   'id',c.id,'round_id',c.round_id,'winner_user_id',c.winner_user_id,
   'winner_nickname',p.nickname,'created_at',c.created_at
 ) order by c.created_at desc),'[]'::jsonb)
 into v_result
 from public.aevtools_roulette_winner_chats c
 left join public.aevtools_profiles p on p.user_id=c.winner_user_id
 where c.winner_user_id=v_uid or exists(select 1 from public.aevtools_admin a where a.user_id=v_uid);
 return v_result;
end;
$$;

create or replace function public.aevtools_roulette_get_winner_chat_messages(p_chat_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public
as $$
declare v_uid uuid:=auth.uid(); v_result jsonb;
begin
 if v_uid is null then raise exception 'login_required'; end if;
 if not exists(select 1 from public.aevtools_roulette_winner_chats c where c.id=p_chat_id
   and (c.winner_user_id=v_uid or exists(select 1 from public.aevtools_admin a where a.user_id=v_uid))) then
   raise exception 'not_allowed';
 end if;
 select coalesce(jsonb_agg(jsonb_build_object(
   'id',m.id,'sender_user_id',m.sender_user_id,
   'sender_nickname',public.aevtools_profile_json(m.sender_user_id)->>'nickname',
   'role_label',public.aevtools_profile_json(m.sender_user_id)->>'role_label',
   'message',m.message,'created_at',m.created_at
 ) order by m.created_at asc),'[]'::jsonb)
 into v_result from public.aevtools_roulette_winner_chat_messages m where m.chat_id=p_chat_id;
 return v_result;
end;
$$;

create or replace function public.aevtools_roulette_send_winner_chat_message(p_chat_id uuid,p_message text)
returns uuid language plpgsql security definer set search_path=public
as $$
declare v_uid uuid:=auth.uid(); v_id uuid;
begin
 if v_uid is null then raise exception 'login_required'; end if;
 if char_length(trim(coalesce(p_message,''))) not between 1 and 4000 then raise exception 'invalid_message'; end if;
 if not exists(select 1 from public.aevtools_roulette_winner_chats c where c.id=p_chat_id
   and (c.winner_user_id=v_uid or exists(select 1 from public.aevtools_admin a where a.user_id=v_uid))) then
   raise exception 'not_allowed';
 end if;
 insert into public.aevtools_roulette_winner_chat_messages(chat_id,sender_user_id,message)
 values(p_chat_id,v_uid,trim(p_message)) returning id into v_id;
 perform public.aevtools_roulette_notify();
 return v_id;
end;
$$;

create or replace function public.aevtools_roulette_delete_winner_chat(p_chat_id uuid)
returns boolean language plpgsql security definer set search_path=public
as $$
begin
 if auth.uid() is null or not exists(select 1 from public.aevtools_admin where user_id=auth.uid()) then raise exception 'admin_required'; end if;
 delete from public.aevtools_roulette_winner_chats where id=p_chat_id;
 if not found then raise exception 'chat_not_found'; end if;
 perform public.aevtools_roulette_notify();
 return true;
end;
$$;

-- Allow authenticated clients to subscribe to the public roulette state and only their own winner chat.
do $$
begin
 if not exists(select 1 from pg_policies where schemaname='realtime' and tablename='messages' and policyname='AevTools roulette realtime read') then
  create policy "AevTools roulette realtime read" on realtime.messages
  for select to authenticated using (
   realtime.topic()='aev-roulette'
   or (realtime.topic() like 'aev-roulette-chat:%' and exists(
    select 1 from public.aevtools_roulette_winner_chats c
    where c.id::text=split_part(realtime.topic(),':',2)
    and (c.winner_user_id=auth.uid() or exists(select 1 from public.aevtools_admin a where a.user_id=auth.uid()))
   ))
  );
 end if;
 if not exists(select 1 from pg_policies where schemaname='realtime' and tablename='messages' and policyname='AevTools roulette realtime write') then
  create policy "AevTools roulette realtime write" on realtime.messages
  for insert to authenticated with check (
   realtime.topic()='aev-roulette'
   or (realtime.topic() like 'aev-roulette-chat:%' and exists(
    select 1 from public.aevtools_roulette_winner_chats c
    where c.id::text=split_part(realtime.topic(),':',2)
    and (c.winner_user_id=auth.uid() or exists(select 1 from public.aevtools_admin a where a.user_id=auth.uid()))
   ))
  );
 end if;
end $$;

revoke all on function public.aevtools_profile_json(uuid) from public;
grant execute on function public.aevtools_profile_json(uuid) to authenticated;
revoke all on function public.aevtools_get_my_profile() from public;
grant execute on function public.aevtools_get_my_profile() to authenticated;
revoke all on function public.aevtools_update_my_nickname(text) from public;
grant execute on function public.aevtools_update_my_nickname(text) to authenticated;
revoke all on function public.aevtools_roulette_get_state() from public;
grant execute on function public.aevtools_roulette_get_state() to authenticated;
revoke all on function public.aevtools_roulette_create_round(integer) from public;
grant execute on function public.aevtools_roulette_create_round(integer) to authenticated;
revoke all on function public.aevtools_roulette_join() from public;
grant execute on function public.aevtools_roulette_join() to authenticated;
revoke all on function public.aevtools_roulette_set_duration(uuid,integer) from public;
grant execute on function public.aevtools_roulette_set_duration(uuid,integer) to authenticated;
revoke all on function public.aevtools_roulette_set_weight(uuid,uuid,integer) from public;
grant execute on function public.aevtools_roulette_set_weight(uuid,uuid,integer) to authenticated;
revoke all on function public.aevtools_roulette_start_spin(uuid) from public;
grant execute on function public.aevtools_roulette_start_spin(uuid) to authenticated;
revoke all on function public.aevtools_roulette_finish_spin(uuid) from public;
grant execute on function public.aevtools_roulette_finish_spin(uuid) to authenticated;
revoke all on function public.aevtools_roulette_create_winner_chat(uuid) from public;
grant execute on function public.aevtools_roulette_create_winner_chat(uuid) to authenticated;
revoke all on function public.aevtools_roulette_list_winner_chats() from public;
grant execute on function public.aevtools_roulette_list_winner_chats() to authenticated;
revoke all on function public.aevtools_roulette_get_winner_chat_messages(uuid) from public;
grant execute on function public.aevtools_roulette_get_winner_chat_messages(uuid) to authenticated;
revoke all on function public.aevtools_roulette_send_winner_chat_message(uuid,text) from public;
grant execute on function public.aevtools_roulette_send_winner_chat_message(uuid,text) to authenticated;
revoke all on function public.aevtools_roulette_delete_winner_chat(uuid) from public;
grant execute on function public.aevtools_roulette_delete_winner_chat(uuid) to authenticated;


-- Include public nicknames in admin support lists and direct-chat directory.
create or replace function public.aevtools_admin_list_support_tickets()
returns jsonb language plpgsql stable security definer
set search_path=public
as $$
declare v_result jsonb;
begin
 if not exists(select 1 from public.aevtools_admin where user_id=auth.uid()) then raise exception 'admin_required'; end if;
 select coalesce(jsonb_agg(jsonb_build_object(
   'id',t.id,'user_id',t.user_id,'user_nickname',coalesce(pr.nickname,'ユーザー'),
   'category',t.category,'subject',t.subject,'message',t.message,'status',t.status,
   'created_at',t.created_at,'cancellation_reason',t.cancellation_reason,
   'blacklisted',exists(select 1 from public.aevtools_support_blacklist b where b.user_id=t.user_id)
 ) order by t.created_at desc),'[]'::jsonb)
 into v_result
 from (select * from public.aevtools_support_tickets where status<>'cancelled' order by created_at desc limit 100) t
 left join public.aevtools_profiles pr on pr.user_id=t.user_id;
 return v_result;
end;
$$;

create or replace function public.aevtools_list_direct_chats()
returns jsonb language plpgsql stable security definer
set search_path=public,auth
as $$
declare v_uid uuid:=auth.uid(); v_admin boolean; v_result jsonb;
begin
 if v_uid is null then raise exception 'login_required'; end if;
 select exists(select 1 from public.aevtools_admin where user_id=v_uid) into v_admin;
 select coalesce(jsonb_agg(jsonb_build_object(
   'id',c.id,'user_id',c.user_id,'user_email',u.email,
   'user_nickname',coalesce(pr.nickname,'ユーザー'),
   'admin_nickname',(select ap.nickname from public.aevtools_admin aa left join public.aevtools_profiles ap on ap.user_id=aa.user_id limit 1),
   'created_at',c.created_at,'last_seen_at',p.last_seen_at,
   'is_online',coalesce(p.last_seen_at>now()-interval '2 minutes',false),
   'status',c.status,'closed_at',c.closed_at
 ) order by c.created_at desc),'[]'::jsonb)
 into v_result
 from public.aevtools_admin_direct_chats c
 join auth.users u on u.id=c.user_id
 left join public.aevtools_profiles pr on pr.user_id=c.user_id
 left join public.aevtools_support_presence p on p.user_id=c.user_id
 where v_admin or c.user_id=v_uid;
 return v_result;
end;
$$;

create or replace function public.aevtools_roulette_cancel_round(p_round_id uuid)
returns boolean language plpgsql security definer set search_path=public
as $$
begin
 if auth.uid() is null or not exists(select 1 from public.aevtools_admin where user_id=auth.uid()) then raise exception 'admin_required'; end if;
 update public.aevtools_roulette_rounds set status='cancelled'
 where id=p_round_id and status in ('open','spinning');
 if not found then raise exception 'round_not_active'; end if;
 perform public.aevtools_roulette_notify();
 return true;
end;
$$;
revoke all on function public.aevtools_roulette_cancel_round(uuid) from public;
grant execute on function public.aevtools_roulette_cancel_round(uuid) to authenticated;


create or replace function public.aevtools_admin_list_cancelled_support_tickets()
returns jsonb language plpgsql stable security definer
set search_path=public
as $$
declare v_result jsonb;
begin
 if not exists(select 1 from public.aevtools_admin where user_id=auth.uid()) then raise exception 'admin_required'; end if;
 select coalesce(jsonb_agg(jsonb_build_object(
   'id',t.id,'user_id',t.user_id,'user_nickname',coalesce(pr.nickname,'ユーザー'),
   'category',t.category,'subject',t.subject,'message',t.message,'status',t.status,
   'created_at',t.created_at,'cancellation_reason',t.cancellation_reason
 ) order by t.updated_at desc),'[]'::jsonb)
 into v_result
 from (select * from public.aevtools_support_tickets where status='cancelled' order by updated_at desc limit 200) t
 left join public.aevtools_profiles pr on pr.user_id=t.user_id;
 return v_result;
end;
$$;


create or replace function public.aevtools_admin_list_support_blacklist_users()
returns jsonb language plpgsql stable security definer
set search_path=public,auth
as $$
declare v_result jsonb;
begin
 if auth.uid() is null or not exists(select 1 from public.aevtools_admin where user_id=auth.uid()) then
   raise exception 'admin_required';
 end if;
 select coalesce(jsonb_agg(jsonb_build_object(
   'user_id',b.user_id,'email',u.email,
   'nickname',coalesce(pr.nickname,'ユーザー'),
   'account_created_at',u.created_at,'last_sign_in_at',u.last_sign_in_at,
   'blacklisted_at',b.created_at,'blacklist_reason',b.reason,
   'admin_user_id',b.admin_user_id,'admin_email',admin_user.email,
   'tickets',coalesce((
     select jsonb_agg(jsonb_build_object(
       'id',t.id,'category',t.category,'subject',t.subject,'message',t.message,
       'status',t.status,'created_at',t.created_at,'updated_at',t.updated_at,
       'cancellation_reason',t.cancellation_reason,
       'replies',coalesce((
         select jsonb_agg(jsonb_build_object(
           'sender_user_id',r.sender_user_id,'sender_email',sender.email,
           'sender_nickname',coalesce(sender_profile.nickname,'ユーザー'),
           'message',r.message,'created_at',r.created_at
         ) order by r.created_at asc)
         from public.aevtools_support_replies r
         left join auth.users sender on sender.id=r.sender_user_id
         left join public.aevtools_profiles sender_profile on sender_profile.user_id=r.sender_user_id
         where r.ticket_id=t.id
       ),'[]'::jsonb)
     ) order by t.created_at desc)
     from public.aevtools_support_tickets t where t.user_id=b.user_id
   ),'[]'::jsonb)
 ) order by b.created_at desc),'[]'::jsonb)
 into v_result
 from public.aevtools_support_blacklist b
 left join auth.users u on u.id=b.user_id
 left join public.aevtools_profiles pr on pr.user_id=b.user_id
 left join auth.users admin_user on admin_user.id=b.admin_user_id;
 return v_result;
end;
$$;
