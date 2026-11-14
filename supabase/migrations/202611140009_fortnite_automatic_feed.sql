-- Fortnite official feed metadata and deduplication for AevNetwork.
-- Existing hand-written news and updates remain unchanged.
alter table public.aevnetwork_news
  add column if not exists source_name text,
  add column if not exists source_url text,
  add column if not exists source_id text,
  add column if not exists image_url text,
  add column if not exists video_url text,
  add column if not exists video_embed_url text,
  add column if not exists content_type text not null default 'article';
alter table public.aevnetwork_updates
  add column if not exists link_url text,
  add column if not exists source_name text,
  add column if not exists source_url text,
  add column if not exists source_id text,
  add column if not exists image_url text,
  add column if not exists video_url text,
  add column if not exists video_embed_url text,
  add column if not exists content_type text not null default 'status';

-- Automated posts have no human author; keep admin-created records unchanged.
alter table public.aevnetwork_news alter column created_by drop not null;
alter table public.aevnetwork_updates alter column created_by drop not null;

create unique index if not exists aevnetwork_news_source_url_uidx
  on public.aevnetwork_news(source_url);
create unique index if not exists aevnetwork_updates_source_url_uidx
  on public.aevnetwork_updates(source_url);
create index if not exists aevnetwork_news_source_id_idx
  on public.aevnetwork_news(source_id) where source_id is not null;
create index if not exists aevnetwork_updates_source_id_idx
  on public.aevnetwork_updates(source_id) where source_id is not null;

grant all on public.aevnetwork_news to service_role;
grant all on public.aevnetwork_updates to service_role;
