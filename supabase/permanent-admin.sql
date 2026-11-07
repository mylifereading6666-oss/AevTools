-- AevTools permanent single-admin setup
-- Run this entire script in Supabase SQL Editor for project vuqbbwdojwmtehgsyfaq.
-- Admin is bound to auth.uid(); logout does not delete this row.
create extension if not exists pgcrypto;

create table if not exists public.aevtools_admin (
  singleton boolean primary key default true check (singleton = true),
  user_id uuid not null unique references auth.users(id) on delete restrict,
  created_at timestamptz not null default now()
);

alter table public.aevtools_admin enable row level security;
revoke all on public.aevtools_admin from anon, authenticated;

create or replace function public.aevtools_claim_admin(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
  v_hash text;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'reason', 'login_required');
  end if;

  -- SHA-256 hash of the one-time 8-character admin claim code.
  v_hash := encode(digest(upper(trim(coalesce(p_code,''))), 'sha256'), 'hex');
  if v_hash <> '6561b6e1ecb6584ea11b70da2639f3cf5fb9daa936b360f9003d572fda95ac64' then
    return jsonb_build_object('ok', false, 'reason', 'invalid_code');
  end if;

  -- The singleton primary key makes concurrent second claims fail atomically.
  insert into public.aevtools_admin(singleton, user_id)
  values (true, v_uid)
  on conflict (singleton) do nothing;

  if exists (select 1 from public.aevtools_admin where singleton=true and user_id=v_uid) then
    return jsonb_build_object('ok', true, 'reason', 'admin');
  end if;

  return jsonb_build_object('ok', false, 'reason', 'admin_already_exists');
end;
$$;

create or replace function public.aevtools_is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.aevtools_admin
    where singleton=true and user_id=auth.uid()
  );
$$;

revoke all on function public.aevtools_claim_admin(text) from public;
grant execute on function public.aevtools_claim_admin(text) to authenticated;
revoke all on function public.aevtools_is_admin() from public;
grant execute on function public.aevtools_is_admin() to authenticated;
