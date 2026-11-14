-- Shared bulletin-board deletion notices, matching AevTools behavior.
create table if not exists public.aevnetwork_community_deletion_notices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  item_type text not null check (item_type in ('post','comment')),
  item_title text,
  item_content text not null,
  reason text not null,
  created_at timestamptz not null default now(),
  read_at timestamptz
);

create index if not exists aevnetwork_community_deletion_notices_user_created_idx
  on public.aevnetwork_community_deletion_notices(user_id, created_at desc);

alter table public.aevnetwork_community_deletion_notices enable row level security;
revoke all on public.aevnetwork_community_deletion_notices from anon, authenticated;
grant all on public.aevnetwork_community_deletion_notices to service_role;

drop function if exists public.aevtools_my_board_deletion_notices();
create function public.aevtools_my_board_deletion_notices()
returns table (
  id uuid,
  item_type text,
  item_title text,
  item_content text,
  reason text,
  created_at timestamptz,
  read_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select n.id, n.item_type, n.item_title, n.item_content, n.reason, n.created_at, n.read_at
  from public.aevnetwork_community_deletion_notices n
  where n.user_id = auth.uid()
  order by n.created_at desc;
$$;

drop function if exists public.aevtools_read_board_deletion_notice(uuid);
create function public.aevtools_read_board_deletion_notice(p_notice_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.aevnetwork_community_deletion_notices
  set read_at = coalesce(read_at, now())
  where id = p_notice_id and user_id = auth.uid();
  return found;
end;
$$;

grant execute on function public.aevtools_my_board_deletion_notices() to authenticated;
grant execute on function public.aevtools_read_board_deletion_notice(uuid) to authenticated;
