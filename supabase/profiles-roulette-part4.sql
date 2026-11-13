-- PART 4/4: Realtime policies, permissions, admin support and directory functions
-- Run after PART 3/4.

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
