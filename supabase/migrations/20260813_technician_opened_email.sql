-- Diferencia o e-mail de chamado aberto pelo servidor daquele criado pela equipe técnica.
alter table public.email_outbox drop constraint if exists email_outbox_event_type_check;
alter table public.email_outbox add constraint email_outbox_event_type_check
  check (event_type in ('recebido','aberto_pelo_tecnico','em_atendimento','atualizacao','concluido'));

create or replace function public.queue_ticket_email() returns trigger
language plpgsql security definer set search_path=public as $$
declare v_email text; v_event text;
begin
  v_email:=public.ticket_email(new);
  if v_email is null then return new; end if;
  if tg_op='INSERT' then
    v_event:=case when new.source='Tecnico' then 'aberto_pelo_tecnico' else 'recebido' end;
  elsif new.status is distinct from old.status and new.status='Em atendimento' then v_event:='em_atendimento';
  elsif new.status is distinct from old.status and new.status='Concluído' then v_event:='concluido';
  else return new;
  end if;
  insert into public.email_outbox(ticket_id,recipient,event_type,payload)
  values(new.id,v_email,v_event,public.ticket_email_payload(new));
  return new;
end $$;
