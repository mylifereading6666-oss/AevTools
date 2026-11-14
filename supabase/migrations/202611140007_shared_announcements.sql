-- Shared AevTools / AevNetwork announcements.
-- The AevTools announcements table is the single source of truth.
-- Existing AevNetwork announcements are copied once; original rows remain untouched.

insert into public.aevtools_announcements
  (id, title, body, link_url, video_url, created_by, created_at, updated_at)
select
  id, title, body, link_url, null, created_by, created_at, updated_at
from public.aevnetwork_announcements
on conflict (id) do nothing;

-- Announcements are public-readable. Writes remain controlled by the existing
-- AevTools policies and the authenticated AevNetwork Edge Function.
grant select on public.aevtools_announcements to anon, authenticated;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname='public'
      and tablename='aevtools_announcements'
      and policyname='Shared announcements are publicly readable'
  ) then
    create policy "Shared announcements are publicly readable"
      on public.aevtools_announcements
      for select to anon, authenticated
      using (true);
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname='supabase_realtime'
      and schemaname='public'
      and tablename='aevtools_announcements'
  ) then
    alter publication supabase_realtime add table public.aevtools_announcements;
  end if;
end $$;
