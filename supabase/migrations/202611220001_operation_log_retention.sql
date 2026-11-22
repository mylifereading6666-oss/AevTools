-- AevTools / AevNetwork operation log retention.
-- Run once in the shared Supabase SQL Editor.
-- Only sanitized API action names are stored. No email, credentials, tokens,
-- user IDs, request bodies, chat content, or IP addresses are logged.

create extension if not exists pg_cron with schema pg_catalog;

create table if not exists public.aevtools_operation_logs (
  id bigint generated always as identity primary key,
  app_key text not null check (app_key in ('aevtools', 'aevnetwork', 'unknown')),
  event_type text not null check (event_type in ('api_request', 'api_exception')),
  action text not null default 'unknown',
  created_at timestamptz not null default now()
);

create index if not exists aevtools_operation_logs_created_at_idx
  on public.aevtools_operation_logs (created_at);

alter table public.aevtools_operation_logs enable row level security;
revoke all on table public.aevtools_operation_logs from public, anon, authenticated;
grant insert on table public.aevtools_operation_logs to service_role;
grant usage, select on sequence public.aevtools_operation_logs_id_seq to service_role;

create or replace function public.aevtools_cleanup_operation_logs()
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  deleted_count bigint;
begin
  delete from public.aevtools_operation_logs
  where created_at < now() - interval '90 days';
  get diagnostics deleted_count = row_count;
  return deleted_count;
end;
$$;

revoke all on function public.aevtools_cleanup_operation_logs() from public, anon, authenticated;
grant execute on function public.aevtools_cleanup_operation_logs() to service_role;

do $$
declare
  existing_job_id bigint;
begin
  select jobid into existing_job_id
  from cron.job
  where jobname = 'aevtools-operation-log-retention'
  limit 1;

  if existing_job_id is not null then
    perform cron.unschedule(existing_job_id);
  end if;

  perform cron.schedule(
    'aevtools-operation-log-retention',
    '17 3 * * *',
    'select public.aevtools_cleanup_operation_logs();'
  );
end;
$$;
