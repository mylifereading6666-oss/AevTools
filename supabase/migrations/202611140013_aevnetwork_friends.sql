-- AevNetwork friend graph and friend requests.
-- Public profile fields remain in the shared AevTools profile table.
create table if not exists public.aevnetwork_friend_requests (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references auth.users(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted','rejected','cancelled')),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  constraint aevnetwork_friend_requests_not_self check (sender_id <> recipient_id)
);

create unique index if not exists aevnetwork_friend_requests_pending_pair
  on public.aevnetwork_friend_requests(sender_id,recipient_id)
  where status='pending';

create index if not exists aevnetwork_friend_requests_recipient_pending
  on public.aevnetwork_friend_requests(recipient_id,created_at desc)
  where status='pending';

create table if not exists public.aevnetwork_friendships (
  id uuid primary key default gen_random_uuid(),
  user_low uuid not null references auth.users(id) on delete cascade,
  user_high uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint aevnetwork_friendships_ordered check (user_low < user_high),
  constraint aevnetwork_friendships_unique_pair unique(user_low,user_high)
);

create index if not exists aevnetwork_friendships_user_low on public.aevnetwork_friendships(user_low);
create index if not exists aevnetwork_friendships_user_high on public.aevnetwork_friendships(user_high);

alter table public.aevnetwork_friend_requests enable row level security;
alter table public.aevnetwork_friendships enable row level security;

revoke all on public.aevnetwork_friend_requests, public.aevnetwork_friendships from anon, authenticated;
grant all on public.aevnetwork_friend_requests, public.aevnetwork_friendships to service_role;
