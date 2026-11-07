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
