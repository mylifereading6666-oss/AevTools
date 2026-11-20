-- AevTools support ticket lifecycle and admin-started realtime chat
-- Run once in Supabase SQL Editor after support-tickets.sql and support-realtime.sql.

alter table public.aevtools_support_tickets
  add column if not exists chat_started_at timestamptz;

-- The user can only open a resolved ticket again through this explicit action.
create or replace function public.aevtools_user_re_request_support_ticket(
  p_ticket_id uuid
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'login_required'; end if;

  update public.aevtools_support_tickets
  set status = 'open',
      chat_started_at = null,
      cancellation_reason = null,
      updated_at = now()
  where id = p_ticket_id
    and user_id = v_uid
    and status = 'resolved';

  if not found then raise exception 'ticket_not_rerequestable'; end if;
  return true;
end;
$$;

revoke all on function public.aevtools_user_re_request_support_ticket(uuid) from public;
grant execute on function public.aevtools_user_re_request_support_ticket(uuid) to authenticated;

-- Only an administrator can start a ticket's realtime chat.
create or replace function public.aevtools_admin_start_support_chat(
  p_ticket_id uuid
) returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare
  v_started_at timestamptz;
begin
  if auth.uid() is null or not exists (
    select 1 from public.aevtools_admin where user_id = auth.uid()
  ) then
    raise exception 'admin_required';
  end if;

  update public.aevtools_support_tickets
  set chat_started_at = coalesce(chat_started_at, now()),
      updated_at = now()
  where id = p_ticket_id
    and status = 'open'
  returning chat_started_at into v_started_at;

  if v_started_at is null then raise exception 'ticket_not_open'; end if;
  return v_started_at;
end;
$$;

revoke all on function public.aevtools_admin_start_support_chat(uuid) from public;
grant execute on function public.aevtools_admin_start_support_chat(uuid) to authenticated;

-- Include chat availability in the user's own ticket list.
create or replace function public.aevtools_my_support_tickets()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_result jsonb;
begin
  if v_uid is null then raise exception 'login_required'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', id,
    'category', category,
    'subject', subject,
    'status', status,
    'created_at', created_at,
    'cancellation_reason', cancellation_reason,
    'chat_started_at', chat_started_at
  ) order by created_at desc), '[]'::jsonb)
  into v_result
  from public.aevtools_support_tickets
  where user_id = v_uid;

  return v_result;
end;
$$;

revoke all on function public.aevtools_my_support_tickets() from public;
grant execute on function public.aevtools_my_support_tickets() to authenticated;

-- Expose the administrator-started flag to the admin console.
create or replace function public.aevtools_admin_list_support_tickets()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_result jsonb;
begin
  if auth.uid() is null or not exists (
    select 1 from public.aevtools_admin where user_id = auth.uid()
  ) then
    raise exception 'admin_required';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', t.id,
    'user_id', t.user_id,
    'category', t.category,
    'subject', t.subject,
    'message', t.message,
    'status', t.status,
    'created_at', t.created_at,
    'cancellation_reason', t.cancellation_reason,
    'chat_started_at', t.chat_started_at,
    'blacklisted', exists(
      select 1 from public.aevtools_support_blacklist b where b.user_id = t.user_id
    )
  ) order by t.created_at desc), '[]'::jsonb)
  into v_result
  from (
    select *
    from public.aevtools_support_tickets
    where status <> 'cancelled'
    order by created_at desc
    limit 100
  ) t;

  return v_result;
end;
$$;

revoke all on function public.aevtools_admin_list_support_tickets() from public;
grant execute on function public.aevtools_admin_list_support_tickets() to authenticated;

-- Reset the chat-start flag whenever an administrator reopens a resolved ticket.
create or replace function public.aevtools_admin_update_support_ticket(
  p_ticket_id uuid,
  p_status text
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not exists (
    select 1 from public.aevtools_admin where user_id = auth.uid()
  ) then
    raise exception 'admin_required';
  end if;
  if p_status not in ('open', 'resolved') then
    raise exception 'invalid_status';
  end if;

  update public.aevtools_support_tickets
  set status = p_status,
      chat_started_at = case when p_status = 'open' then null else chat_started_at end,
      updated_at = now()
  where id = p_ticket_id;

  return found;
end;
$$;

revoke all on function public.aevtools_admin_update_support_ticket(uuid, text) from public;
grant execute on function public.aevtools_admin_update_support_ticket(uuid, text) to authenticated;

-- A user cannot cancel a resolved ticket. They must use the re-request action.
create or replace function public.aevtools_cancel_support_ticket(
  p_ticket_id uuid,
  p_reason text
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'login_required'; end if;
  if char_length(trim(coalesce(p_reason, ''))) not between 10 and 1000 then
    raise exception 'cancellation_reason_required';
  end if;

  update public.aevtools_support_tickets
  set status = 'cancelled',
      cancellation_reason = trim(p_reason),
      updated_at = now()
  where id = p_ticket_id
    and user_id = v_uid
    and status = 'open';

  if not found then raise exception 'ticket_not_cancellable'; end if;
  return true;
end;
$$;

revoke all on function public.aevtools_cancel_support_ticket(uuid, text) from public;
grant execute on function public.aevtools_cancel_support_ticket(uuid, text) to authenticated;

-- A non-admin can read a support conversation only after an admin starts it
-- and only while the ticket is open. Admins retain access to historical messages.
create or replace function public.aevtools_support_ticket_messages(
  p_ticket_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_admin boolean;
  v_owner uuid;
  v_status text;
  v_chat_started_at timestamptz;
  v_result jsonb;
begin
  if v_uid is null then raise exception 'login_required'; end if;

  select user_id, status, chat_started_at
  into v_owner, v_status, v_chat_started_at
  from public.aevtools_support_tickets
  where id = p_ticket_id;

  if v_owner is null then raise exception 'ticket_not_found'; end if;

  select exists(
    select 1 from public.aevtools_admin where user_id = v_uid
  ) into v_admin;

  if not v_admin and (
    v_uid <> v_owner or v_status <> 'open' or v_chat_started_at is null
  ) then
    raise exception 'support_chat_not_started';
  end if;

  select coalesce(jsonb_agg(item order by created_at asc, sort_order asc), '[]'::jsonb)
  into v_result
  from (
    select jsonb_build_object(
      'id', 'initial-' || t.id::text,
      'sender', 'user',
      'label', case when v_admin then 'ユーザー' else 'あなた' end,
      'message', t.message,
      'created_at', t.created_at
    ) as item, t.created_at, 0 as sort_order
    from public.aevtools_support_tickets t
    where t.id = p_ticket_id

    union all

    select jsonb_build_object(
      'id', r.id,
      'sender', case
        when exists(select 1 from public.aevtools_admin a where a.user_id = r.sender_user_id)
        then 'admin' else 'user' end,
      'label', case
        when exists(select 1 from public.aevtools_admin a where a.user_id = r.sender_user_id)
        then 'Aev0rnJP'
        when v_admin then 'ユーザー'
        else 'あなた' end,
      'message', r.message,
      'created_at', r.created_at
    ) as item, r.created_at, 1 as sort_order
    from public.aevtools_support_replies r
    where r.ticket_id = p_ticket_id
  ) q;

  return v_result;
end;
$$;

revoke all on function public.aevtools_support_ticket_messages(uuid) from public;
grant execute on function public.aevtools_support_ticket_messages(uuid) to authenticated;

-- Both sides may reply only after the administrator starts the chat.
-- Replies no longer silently reopen resolved tickets.
create or replace function public.aevtools_support_reply(
  p_ticket_id uuid,
  p_message text
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_owner uuid;
  v_status text;
  v_chat_started_at timestamptz;
  v_is_admin boolean;
  v_reply_id uuid;
begin
  if v_uid is null then raise exception 'login_required'; end if;
  if char_length(trim(coalesce(p_message, ''))) not between 1 and 4000 then
    raise exception 'invalid_reply';
  end if;

  select user_id, status, chat_started_at
  into v_owner, v_status, v_chat_started_at
  from public.aevtools_support_tickets
  where id = p_ticket_id;

  if v_owner is null then raise exception 'ticket_not_found'; end if;

  select exists(
    select 1 from public.aevtools_admin where user_id = v_uid
  ) into v_is_admin;

  if (not v_is_admin and v_uid <> v_owner) then
    raise exception 'not_allowed';
  end if;

  if v_status <> 'open' or v_chat_started_at is null then
    raise exception 'support_chat_not_started';
  end if;

  if not v_is_admin and exists(
    select 1 from public.aevtools_support_blacklist where user_id = v_uid
  ) then
    raise exception 'support_blacklisted';
  end if;

  insert into public.aevtools_support_replies(ticket_id, sender_user_id, message)
  values(p_ticket_id, v_uid, trim(p_message))
  returning id into v_reply_id;

  update public.aevtools_support_tickets
  set updated_at = now()
  where id = p_ticket_id;

  return v_reply_id;
end;
$$;

revoke all on function public.aevtools_support_reply(uuid, text) from public;
grant execute on function public.aevtools_support_reply(uuid, text) to authenticated;

-- Restrict private Realtime channel access as well as the UI.
drop policy if exists "AevTools support participants can read realtime messages" on realtime.messages;
drop policy if exists "AevTools support participants can send realtime messages" on realtime.messages;

create policy "AevTools support participants can read realtime messages"
on realtime.messages for select to authenticated
using (
  realtime.topic() like 'aev-support:%'
  and exists (
    select 1
    from public.aevtools_support_tickets t
    where t.id::text = split_part(realtime.topic(), ':', 2)
      and (
        exists(select 1 from public.aevtools_admin a where a.user_id = auth.uid())
        or (
          t.user_id = auth.uid()
          and t.status = 'open'
          and t.chat_started_at is not null
        )
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
        exists(select 1 from public.aevtools_admin a where a.user_id = auth.uid())
        or (
          t.user_id = auth.uid()
          and t.status = 'open'
          and t.chat_started_at is not null
        )
      )
  )
);
