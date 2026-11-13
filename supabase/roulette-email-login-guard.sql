-- AevTools: メールアドレスでログインしたユーザーだけがルーレットに参加できるようにする
create or replace function public.aevtools_roulette_join()
returns boolean language plpgsql security definer set search_path=public
as $$
declare
 v_uid uuid:=auth.uid();
 v_round_id uuid;
 v_name text;
begin
 if v_uid is null then
   raise exception 'login_required';
 end if;

 if coalesce(auth.jwt()->'app_metadata'->>'provider','') <> 'email'
    and not coalesce((auth.jwt()->'app_metadata'->'providers') ? 'email',false) then
   raise exception 'email_login_required';
 end if;

 select id into v_round_id
 from public.aevtools_roulette_rounds
 where status='open'
 order by created_at desc
 limit 1
 for update;

 if v_round_id is null then
   raise exception 'registration_closed';
 end if;

 select nickname into v_name
 from public.aevtools_profiles
 where user_id=v_uid;

 if v_name is null then
   v_name:=case
     when exists(select 1 from public.aevtools_admin where user_id=v_uid) then 'Aev0rnJP'
     else 'ユーザー'||upper(substr(replace(v_uid::text,'-',''),1,6))
   end;
 end if;

 insert into public.aevtools_roulette_participants(round_id,user_id,nickname)
 values(v_round_id,v_uid,v_name);

 perform public.aevtools_roulette_notify();
 return true;
exception
 when unique_violation then raise exception 'already_joined';
end;
$$;

revoke all on function public.aevtools_roulette_join() from public;
grant execute on function public.aevtools_roulette_join() to authenticated;
