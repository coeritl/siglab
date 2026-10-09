-- Observabilidade e reprocessamento seguro da fila de notificações.
alter table public.email_outbox
  add column if not exists manual_retry_at timestamptz,
  add column if not exists manual_retry_by uuid references public.profiles(id) on delete set null;

create or replace function public.apps_script_finish_outbox(
  p_secret text,p_id bigint,p_success boolean,p_error text default null
) returns void language plpgsql security definer set search_path=public as $$
begin
  if not public.integration_secret_valid(p_secret) then raise exception 'Credencial inválida'; end if;
  if p_success then
    update public.email_outbox set status='sent',sent_at=coalesce(sent_at,now()),last_error=null
    where id=p_id and status<>'sent';
  else
    update public.email_outbox set
      status=case when attempts>=5 then 'failed' else 'pending' end,
      available_at=now()+interval '30 minutes',
      last_error=left(coalesce(p_error,'Erro desconhecido'),1000)
    where id=p_id and status='processing';
  end if;
end $$;

create or replace function public.retry_email_outbox(p_id bigint) returns void
language plpgsql security definer set search_path=public as $$
begin
  if public.current_role()<>'tecnico' then raise exception 'Apenas técnicos podem reenviar notificações'; end if;
  update public.email_outbox set status='pending',available_at=now(),claimed_at=null,
    attempts=0,last_error=null,manual_retry_at=now(),manual_retry_by=auth.uid()
  where id=p_id and (
    status='failed' or
    (status='pending' and available_at<now()-interval '5 minutes') or
    (status='processing' and claimed_at<now()-interval '10 minutes')
  );
  if not found then raise exception 'A notificação não está disponível para reenvio'; end if;
end $$;
grant execute on function public.retry_email_outbox(bigint) to authenticated;

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
    'outbox_pending',(select count(*) from public.email_outbox where status='pending'),
    'outbox_processing',(select count(*) from public.email_outbox where status='processing'),
    'outbox_failed',(select count(*) from public.email_outbox where status='failed'),
    'outbox_overdue',(select count(*) from public.email_outbox where (status='pending' and available_at<now()-interval '5 minutes') or (status='processing' and claimed_at<now()-interval '10 minutes')),
    'outbox_sent_today',(select count(*) from public.email_outbox where status='sent' and sent_at>=current_date),
    'outbox_last_error',(select last_error from public.email_outbox where last_error is not null order by id desc limit 1),
    'outbox_problems',coalesce((select jsonb_agg(to_jsonb(q)) from (
      select o.id,o.recipient,o.event_type,o.status,o.attempts,o.available_at,o.last_error,
             coalesce(t.protocol,r.protocol) protocol
      from public.email_outbox o
      left join public.tickets t on t.id=o.ticket_id
      left join public.reservations r on r.id=o.reservation_id
      where o.status='failed'
         or (o.status='pending' and o.available_at<now()-interval '5 minutes')
         or (o.status='processing' and o.claimed_at<now()-interval '10 minutes')
      order by o.id desc limit 25
    ) q),'[]'::jsonb),
    'sent_today',m.sent_today,'sent_month',m.sent_month,'email_quota_remaining',m.email_quota_remaining,
    'inbox_runs_today',m.inbox_runs_today,'outbox_runs_today',m.outbox_runs_today,
    'last_inbox_run',m.last_inbox_run,'last_outbox_run',m.last_outbox_run,'updated_at',m.updated_at
  );
end $$;
grant execute on function public.maintenance_metrics() to authenticated;

-- Chamados originados no chat já nascem no estado final escolhido pelo técnico.
-- Por isso devem gerar um único evento: conclusão ou permanência em atendimento.
create or replace function public.queue_ticket_email() returns trigger
language plpgsql security definer set search_path=public as $$
declare v_email text; v_event text;
begin
  v_email:=public.ticket_email(new);
  if v_email is null then return new; end if;
  if tg_op='INSERT' then
    if new.source='Chat' then
      v_event:=case when new.status='Concluído' then 'concluido' else 'em_atendimento' end;
    else
      v_event:=case when new.source='Tecnico' then 'aberto_pelo_tecnico' else 'recebido' end;
    end if;
  elsif new.status is distinct from old.status and new.status='Em atendimento' then v_event:='em_atendimento';
  elsif new.status is distinct from old.status and new.status='Concluído' then v_event:='concluido';
  else return new;
  end if;
  insert into public.email_outbox(ticket_id,recipient,event_type,payload)
  values(new.id,v_email,v_event,public.ticket_email_payload(new));
  return new;
end $$;
