-- PART 2/4: Roulette rounds, participants, realtime notifications and spin functions
-- Run after PART 1/4.

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
revoke all on function public.aevtools_roulette_notify() from public,anon,authenticated;

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
