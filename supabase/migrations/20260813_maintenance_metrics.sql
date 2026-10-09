create table if not exists public.integration_runtime_metrics (
  id boolean primary key default true check(id),
  email_quota_remaining integer,
  sent_today integer not null default 0,
  sent_month integer not null default 0,
  inbox_runs_today integer not null default 0,
  outbox_runs_today integer not null default 0,
  metric_day date not null default current_date,
  metric_month date not null default date_trunc('month',current_date)::date,
  last_inbox_run timestamptz,
  last_outbox_run timestamptz,
  updated_at timestamptz not null default now()
);
alter table public.integration_runtime_metrics enable row level security;
drop policy if exists integration_metrics_read on public.integration_runtime_metrics;
create policy integration_metrics_read on public.integration_runtime_metrics for select to authenticated
using(public.current_role() in ('tecnico','supervisor'));
insert into public.integration_runtime_metrics(id) values(true) on conflict do nothing;

create or replace function public.apps_script_report_metrics(p_secret text,p_kind text,p_sent integer,p_remaining integer)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not public.integration_secret_valid(p_secret) then raise exception 'Credencial inválida'; end if;
  update public.integration_runtime_metrics set
    sent_today=case when metric_day=current_date then sent_today+greatest(p_sent,0) else greatest(p_sent,0) end,
    sent_month=case when metric_month=date_trunc('month',current_date)::date then sent_month+greatest(p_sent,0) else greatest(p_sent,0) end,
    inbox_runs_today=case when metric_day=current_date then inbox_runs_today+(p_kind='inbox')::int else (p_kind='inbox')::int end,
    outbox_runs_today=case when metric_day=current_date then outbox_runs_today+(p_kind='outbox')::int else (p_kind='outbox')::int end,
    metric_day=current_date,metric_month=date_trunc('month',current_date)::date,
    email_quota_remaining=p_remaining,
    last_inbox_run=case when p_kind='inbox' then now() else last_inbox_run end,
    last_outbox_run=case when p_kind='outbox' then now() else last_outbox_run end,updated_at=now()
  where id=true;
end $$;
grant execute on function public.apps_script_report_metrics(text,text,integer,integer) to anon;

create or replace function public.maintenance_metrics() returns jsonb
language plpgsql security definer set search_path=public as $$
declare m public.integration_runtime_metrics;
begin
  if public.current_role() not in ('tecnico','supervisor') then raise exception 'Acesso negado'; end if;
  select * into m from public.integration_runtime_metrics where id=true;
  return jsonb_build_object(
    'database_bytes',pg_database_size(current_database()),
    'attachment_bytes',coalesce((select sum(size_bytes) from public.attachments),0),
    'attachment_count',(select count(*) from public.attachments),
    'ticket_count',(select count(*) from public.tickets),
    'outbox_pending',(select count(*) from public.email_outbox where status in ('pending','processing')),
    'outbox_failed',(select count(*) from public.email_outbox where status='failed'),
    'sent_today',m.sent_today,'sent_month',m.sent_month,'email_quota_remaining',m.email_quota_remaining,
    'inbox_runs_today',m.inbox_runs_today,'outbox_runs_today',m.outbox_runs_today,
    'last_inbox_run',m.last_inbox_run,'last_outbox_run',m.last_outbox_run,'updated_at',m.updated_at
  );
end $$;
grant execute on function public.maintenance_metrics() to authenticated;
