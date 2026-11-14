-- AevTools / AevNetwork: permanent single test-helper assignment
-- Run once in the shared Supabase SQL Editor.

create table if not exists public.aevtools_test_helper_assignment (
  singleton boolean primary key default true check (singleton),
  user_id uuid not null unique references auth.users(id) on delete restrict,
  assigned_by uuid not null references auth.users(id) on delete restrict,
  assigned_at timestamptz not null default now()
);

alter table public.aevtools_test_helper_assignment enable row level security;
revoke all on public.aevtools_test_helper_assignment from anon, authenticated, public;

create or replace function public.aevtools_prevent_test_helper_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  raise exception 'test_helper_assignment_is_permanent';
end;
$$;

drop trigger if exists aevtools_test_helper_immutable on public.aevtools_test_helper_assignment;
create trigger aevtools_test_helper_immutable
before update or delete on public.aevtools_test_helper_assignment
for each row execute function public.aevtools_prevent_test_helper_change();

-- The API uses the service-role key after verifying the permanent admin account.
-- No client-side direct table access is granted.
