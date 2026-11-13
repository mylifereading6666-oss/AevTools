-- PART 3/4: Winner private chat
-- Run after PART 2/4.

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
