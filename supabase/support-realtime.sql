-- AevTools support chat realtime migration
-- Run in Supabase SQL Editor AFTER support-tickets.sql.
-- Enables private Realtime channels for participants of a support ticket.

create table if not exists public.aevtools_support_presence (
  user_id uuid primary key references auth.users(id) on delete cascade,
  last_seen_at timestamptz not null default now()
);

alter table public.aevtools_support_presence enable row level security;
revoke all on public.aevtools_support_presence from anon, authenticated;

-- User can update only their own last-seen timestamp through this RPC.
create or replace function public.aevtools_support_touch_presence()
returns timestamptz
language plpgsql security definer
set search_path = public
as $$
declare v_uid uuid := auth.uid(); v_time timestamptz := now();
begin
  if v_uid is null then raise exception 'login_required'; end if;
  insert into public.aevtools_support_presence(user_id,last_seen_at)
  values(v_uid,v_time)
  on conflict(user_id) do update set last_seen_at=excluded.last_seen_at;
  return v_time;
end;
$$;

-- Return last-seen time only if caller is the ticket owner or admin.
create or replace function public.aevtools_support_get_presence(p_ticket_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
declare v_uid uuid := auth.uid(); v_owner uuid; v_result jsonb;
begin
  if v_uid is null then raise exception 'login_required'; end if;
  select user_id into v_owner from public.aevtools_support_tickets where id=p_ticket_id;
  if v_owner is null then raise exception 'ticket_not_found'; end if;
  if v_uid<>v_owner and not exists(select 1 from public.aevtools_admin where user_id=v_uid) then
    raise exception 'not_allowed';
  end if;
  select jsonb_build_object(
    'user_id',v_owner,
    'last_seen_at',p.last_seen_at
  ) into v_result
  from public.aevtools_support_presence p where p.user_id=v_owner;
  return coalesce(v_result,jsonb_build_object('user_id',v_owner,'last_seen_at',null));
end;
$$;

revoke all on function public.aevtools_support_touch_presence() from public;
grant execute on function public.aevtools_support_touch_presence() to authenticated;
revoke all on function public.aevtools_support_get_presence(uuid) from public;
grant execute on function public.aevtools_support_get_presence(uuid) to authenticated;

-- Private Realtime channel access: only ticket owner and admin can join.
create policy "AevTools support participants can read realtime messages"
on realtime.messages for select to authenticated
using (
  realtime.topic() like 'aev-support:%'
  and exists (
    select 1
    from public.aevtools_support_tickets t
    where t.id::text = split_part(realtime.topic(), ':', 2)
      and (
        t.user_id = auth.uid()
        or exists(select 1 from public.aevtools_admin a where a.user_id=auth.uid())
      )
  )
);

create policy "AevTools support participants can send realtime messages"
on realtime.messages for insert to authenticated
with check (
  realtime.topic() like 'aev-support:%'
  and exists (
    select 1
    from public.aevtools_support_tickets t
    where t.id::text = split_part(realtime.topic(), ':', 2)
      and (
        t.user_id = auth.uid()
        or exists(select 1 from public.aevtools_admin a where a.user_id=auth.uid())
      )
  )
);

-- Realtime is used for presence and broadcast; database messages are not replicated.
