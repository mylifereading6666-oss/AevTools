-- AevTools support ticket system
-- Run this script in the same Supabase SQL Editor after permanent-admin.sql.
create table if not exists public.aevtools_support_tickets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  category text not null check (category in ('bug','feature','question','other')),
  subject text not null check (char_length(subject) between 1 and 120),
  message text not null check (char_length(message) between 1 and 4000),
  status text not null default 'open' check (status in ('open','resolved')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists aevtools_support_created_idx
  on public.aevtools_support_tickets(created_at desc);
create index if not exists aevtools_support_user_idx
  on public.aevtools_support_tickets(user_id, created_at desc);

alter table public.aevtools_support_tickets enable row level security;
revoke all on public.aevtools_support_tickets from anon, authenticated;

create or replace function public.aevtools_submit_support_ticket(
  p_category text, p_subject text, p_message text
) returns uuid
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_uid uuid := auth.uid(); v_id uuid;
begin
  if v_uid is null then raise exception 'login_required'; end if;
  if p_category not in ('bug','feature','question','other')
     or char_length(trim(coalesce(p_subject,''))) not between 1 and 120
     or char_length(trim(coalesce(p_message,''))) not between 1 and 4000 then
    raise exception 'invalid_ticket_input';
  end if;
  insert into public.aevtools_support_tickets(user_id,category,subject,message)
  values(v_uid,p_category,trim(p_subject),trim(p_message))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.aevtools_my_support_tickets()
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
declare v_uid uuid := auth.uid(); v_result jsonb;
begin
  if v_uid is null then raise exception 'login_required'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',id,'category',category,'subject',subject,'status',status,'created_at',created_at
  ) order by created_at desc),'[]'::jsonb)
  into v_result
  from public.aevtools_support_tickets where user_id=v_uid;
  return v_result;
end;
$$;

create or replace function public.aevtools_admin_list_support_tickets()
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
declare v_result jsonb;
begin
  if not exists(select 1 from public.aevtools_admin where user_id=auth.uid()) then
    raise exception 'admin_required';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',id,'user_id',user_id,'category',category,'subject',subject,
    'message',message,'status',status,'created_at',created_at
  ) order by created_at desc),'[]'::jsonb)
  into v_result
  from (select * from public.aevtools_support_tickets order by created_at desc limit 100) t;
  return v_result;
end;
$$;

create or replace function public.aevtools_admin_update_support_ticket(
  p_ticket_id uuid, p_status text
) returns boolean
language plpgsql security definer
set search_path = public
as $$
begin
  if not exists(select 1 from public.aevtools_admin where user_id=auth.uid()) then
    raise exception 'admin_required';
  end if;
  if p_status not in ('open','resolved') then raise exception 'invalid_status'; end if;
  update public.aevtools_support_tickets
  set status=p_status, updated_at=now()
  where id=p_ticket_id;
  return found;
end;
$$;

revoke all on function public.aevtools_submit_support_ticket(text,text,text) from public;
grant execute on function public.aevtools_submit_support_ticket(text,text,text) to authenticated;
revoke all on function public.aevtools_my_support_tickets() from public;
grant execute on function public.aevtools_my_support_tickets() to authenticated;
revoke all on function public.aevtools_admin_list_support_tickets() from public;
grant execute on function public.aevtools_admin_list_support_tickets() to authenticated;
revoke all on function public.aevtools_admin_update_support_ticket(uuid,text) from public;
grant execute on function public.aevtools_admin_update_support_ticket(uuid,text) to authenticated;


-- Support conversation/reply system (migration; safe to run again)
create table if not exists public.aevtools_support_replies (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.aevtools_support_tickets(id) on delete cascade,
  sender_user_id uuid not null references auth.users(id) on delete cascade,
  message text not null check (char_length(message) between 1 and 4000),
  created_at timestamptz not null default now()
);
create index if not exists aevtools_support_replies_ticket_idx
  on public.aevtools_support_replies(ticket_id, created_at asc);
alter table public.aevtools_support_replies enable row level security;
revoke all on public.aevtools_support_replies from anon, authenticated;

create or replace function public.aevtools_support_ticket_messages(p_ticket_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
declare v_uid uuid := auth.uid(); v_admin boolean; v_owner uuid; v_result jsonb;
begin
  if v_uid is null then raise exception 'login_required'; end if;
  select user_id into v_owner from public.aevtools_support_tickets where id=p_ticket_id;
  if v_owner is null then raise exception 'ticket_not_found'; end if;
  select exists(select 1 from public.aevtools_admin where user_id=v_uid) into v_admin;
  if v_uid<>v_owner and not v_admin then raise exception 'not_allowed'; end if;

  select coalesce(jsonb_agg(item order by created_at asc, sort_order asc),'[]'::jsonb)
  into v_result
  from (
    select jsonb_build_object(
      'id', 'initial-'||t.id::text,
      'sender', 'user',
      'label', case when v_admin then 'ユーザー' else 'あなた' end,
      'message', t.message,
      'created_at', t.created_at
    ) as item, t.created_at, 0 as sort_order
    from public.aevtools_support_tickets t where t.id=p_ticket_id
    union all
    select jsonb_build_object(
      'id', r.id,
      'sender', case when exists(select 1 from public.aevtools_admin a where a.user_id=r.sender_user_id) then 'admin' else 'user' end,
      'label', case
        when exists(select 1 from public.aevtools_admin a where a.user_id=r.sender_user_id) then 'Aev0rnJP'
        when v_admin then 'ユーザー'
        else 'あなた'
      end,
      'message', r.message,
      'created_at', r.created_at
    ) as item, r.created_at, 1 as sort_order
    from public.aevtools_support_replies r where r.ticket_id=p_ticket_id
  ) q;
  return v_result;
end;
$$;

create or replace function public.aevtools_support_reply(p_ticket_id uuid,p_message text)
returns uuid
language plpgsql security definer
set search_path = public
as $$
declare v_uid uuid := auth.uid(); v_owner uuid; v_reply_id uuid;
begin
  if v_uid is null then raise exception 'login_required'; end if;
  if char_length(trim(coalesce(p_message,''))) not between 1 and 4000 then
    raise exception 'invalid_reply';
  end if;
  select user_id into v_owner from public.aevtools_support_tickets where id=p_ticket_id;
  if v_owner is null then raise exception 'ticket_not_found'; end if;
  if v_uid<>v_owner and not exists(select 1 from public.aevtools_admin where user_id=v_uid) then
    raise exception 'not_allowed';
  end if;
  insert into public.aevtools_support_replies(ticket_id,sender_user_id,message)
  values(p_ticket_id,v_uid,trim(p_message)) returning id into v_reply_id;
  update public.aevtools_support_tickets
  set status='open',updated_at=now()
  where id=p_ticket_id;
  return v_reply_id;
end;
$$;

revoke all on function public.aevtools_support_ticket_messages(uuid) from public;
grant execute on function public.aevtools_support_ticket_messages(uuid) to authenticated;
revoke all on function public.aevtools_support_reply(uuid,text) from public;
grant execute on function public.aevtools_support_reply(uuid,text) to authenticated;


-- Support ticket cancellation and user support blacklist (migration)
alter table public.aevtools_support_tickets
  drop constraint if exists aevtools_support_tickets_status_check;
alter table public.aevtools_support_tickets
  add constraint aevtools_support_tickets_status_check
  check (status in ('open','resolved','cancelled'));
alter table public.aevtools_support_tickets
  add column if not exists cancellation_reason text;

create table if not exists public.aevtools_support_blacklist (
  user_id uuid primary key references auth.users(id) on delete cascade,
  admin_user_id uuid not null references auth.users(id) on delete restrict,
  reason text,
  created_at timestamptz not null default now()
);
alter table public.aevtools_support_blacklist enable row level security;
revoke all on public.aevtools_support_blacklist from anon, authenticated;

create or replace function public.aevtools_submit_support_ticket(
  p_category text, p_subject text, p_message text
) returns uuid
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_uid uuid := auth.uid(); v_id uuid;
begin
  if v_uid is null then raise exception 'login_required'; end if;
  if exists(select 1 from public.aevtools_support_blacklist b where b.user_id=v_uid) then
    raise exception 'support_blacklisted';
  end if;
  if p_category not in ('bug','feature','question','other')
     or char_length(trim(coalesce(p_subject,''))) not between 1 and 120
     or char_length(trim(coalesce(p_message,''))) not between 1 and 4000 then
    raise exception 'invalid_ticket_input';
  end if;
  insert into public.aevtools_support_tickets(user_id,category,subject,message)
  values(v_uid,p_category,trim(p_subject),trim(p_message))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.aevtools_my_support_tickets()
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
declare v_uid uuid := auth.uid(); v_result jsonb;
begin
  if v_uid is null then raise exception 'login_required'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',id,'category',category,'subject',subject,'status',status,
    'created_at',created_at,'cancellation_reason',cancellation_reason
  ) order by created_at desc),'[]'::jsonb)
  into v_result
  from public.aevtools_support_tickets where user_id=v_uid;
  return v_result;
end;
$$;

create or replace function public.aevtools_admin_list_support_tickets()
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
declare v_result jsonb;
begin
  if not exists(select 1 from public.aevtools_admin where user_id=auth.uid()) then
    raise exception 'admin_required';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',id,'user_id',user_id,'category',category,'subject',subject,
    'message',message,'status',status,'created_at',created_at,
    'cancellation_reason',cancellation_reason,
    'blacklisted',exists(select 1 from public.aevtools_support_blacklist b where b.user_id=t.user_id)
  ) order by created_at desc),'[]'::jsonb)
  into v_result
  from (select * from public.aevtools_support_tickets where status <> 'cancelled' order by created_at desc limit 100) t;
  return v_result;
end;
$$;

create or replace function public.aevtools_cancel_support_ticket(
  p_ticket_id uuid, p_reason text
) returns boolean
language plpgsql security definer
set search_path = public
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'login_required'; end if;
  if char_length(trim(coalesce(p_reason,''))) not between 10 and 1000 then
    raise exception 'cancellation_reason_required';
  end if;
  update public.aevtools_support_tickets
  set status='cancelled', cancellation_reason=trim(p_reason), updated_at=now()
  where id=p_ticket_id and user_id=v_uid and status in ('open','resolved');
  if not found then raise exception 'ticket_not_cancellable'; end if;
  return true;
end;
$$;

create or replace function public.aevtools_admin_list_cancelled_support_tickets()
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
declare v_result jsonb;
begin
  if not exists(select 1 from public.aevtools_admin where user_id=auth.uid()) then
    raise exception 'admin_required';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',id,'user_id',user_id,'category',category,'subject',subject,
    'message',message,'status',status,'created_at',created_at,
    'cancellation_reason',cancellation_reason
  ) order by updated_at desc),'[]'::jsonb)
  into v_result
  from (select * from public.aevtools_support_tickets where status='cancelled' order by updated_at desc limit 200) t;
  return v_result;
end;
$$;

create or replace function public.aevtools_admin_set_support_blacklist(
  p_user_id uuid, p_blocked boolean, p_reason text default null
) returns boolean
language plpgsql security definer
set search_path = public
as $$
begin
  if not exists(select 1 from public.aevtools_admin where user_id=auth.uid()) then
    raise exception 'admin_required';
  end if;
  if p_user_id is null or exists(select 1 from public.aevtools_admin where user_id=p_user_id) then
    raise exception 'invalid_target_user';
  end if;
  if p_blocked then
    insert into public.aevtools_support_blacklist(user_id,admin_user_id,reason)
    values(p_user_id,auth.uid(),nullif(trim(coalesce(p_reason,'')),''))
    on conflict(user_id) do update
      set admin_user_id=excluded.admin_user_id,reason=excluded.reason,created_at=now();
  else
    delete from public.aevtools_support_blacklist where user_id=p_user_id;
  end if;
  return true;
end;
$$;

revoke all on function public.aevtools_cancel_support_ticket(uuid,text) from public;
grant execute on function public.aevtools_cancel_support_ticket(uuid,text) to authenticated;
revoke all on function public.aevtools_admin_list_cancelled_support_tickets() from public;
grant execute on function public.aevtools_admin_list_cancelled_support_tickets() to authenticated;
revoke all on function public.aevtools_admin_set_support_blacklist(uuid,boolean,text) from public;
grant execute on function public.aevtools_admin_set_support_blacklist(uuid,boolean,text) to authenticated;


-- Also prevent blacklisted users from replying to support threads.
create or replace function public.aevtools_support_reply(p_ticket_id uuid,p_message text)
returns uuid
language plpgsql security definer
set search_path = public
as $$
declare v_uid uuid := auth.uid(); v_owner uuid; v_reply_id uuid;
begin
  if v_uid is null then raise exception 'login_required'; end if;
  if char_length(trim(coalesce(p_message,''))) not between 1 and 4000 then
    raise exception 'invalid_reply';
  end if;
  select user_id into v_owner from public.aevtools_support_tickets where id=p_ticket_id;
  if v_owner is null then raise exception 'ticket_not_found'; end if;
  if v_uid<>v_owner and not exists(select 1 from public.aevtools_admin where user_id=v_uid) then
    raise exception 'not_allowed';
  end if;
  if v_uid=v_owner and exists(select 1 from public.aevtools_support_blacklist where user_id=v_uid) then
    raise exception 'support_blacklisted';
  end if;
  insert into public.aevtools_support_replies(ticket_id,sender_user_id,message)
  values(p_ticket_id,v_uid,trim(p_message)) returning id into v_reply_id;
  update public.aevtools_support_tickets
  set status='open',updated_at=now()
  where id=p_ticket_id;
  return v_reply_id;
end;
$$;


-- Admin-only detailed blacklist user directory.
-- Shows account email/timestamps and all support ticket/reply history.
-- Never exposes passwords, auth tokens, or recovery secrets.
create or replace function public.aevtools_admin_list_support_blacklist_users()
returns jsonb
language plpgsql stable security definer
set search_path = public, auth
as $$
declare v_result jsonb;
begin
  if auth.uid() is null or not exists(
    select 1 from public.aevtools_admin where user_id=auth.uid()
  ) then
    raise exception 'admin_required';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id', b.user_id,
    'email', u.email,
    'account_created_at', u.created_at,
    'last_sign_in_at', u.last_sign_in_at,
    'blacklisted_at', b.created_at,
    'blacklist_reason', b.reason,
    'admin_user_id', b.admin_user_id,
    'admin_email', admin_user.email,
    'tickets', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', t.id,
        'category', t.category,
        'subject', t.subject,
        'message', t.message,
        'status', t.status,
        'created_at', t.created_at,
        'updated_at', t.updated_at,
        'cancellation_reason', t.cancellation_reason,
        'replies', coalesce((
          select jsonb_agg(jsonb_build_object(
            'sender_user_id', r.sender_user_id,
            'sender_email', sender.email,
            'message', r.message,
            'created_at', r.created_at
          ) order by r.created_at asc)
          from public.aevtools_support_replies r
          left join auth.users sender on sender.id=r.sender_user_id
          where r.ticket_id=t.id
        ), '[]'::jsonb)
      ) order by t.created_at desc)
      from public.aevtools_support_tickets t
      where t.user_id=b.user_id
    ), '[]'::jsonb)
  ) order by b.created_at desc), '[]'::jsonb)
  into v_result
  from public.aevtools_support_blacklist b
  left join auth.users u on u.id=b.user_id
  left join auth.users admin_user on admin_user.id=b.admin_user_id;

  return v_result;
end;
$$;

revoke all on function public.aevtools_admin_list_support_blacklist_users() from public;
grant execute on function public.aevtools_admin_list_support_blacklist_users() to authenticated;
