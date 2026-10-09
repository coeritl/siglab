-- Lembretes de disponibilidade e alerta por e-mail para chats aguardando.
-- Cada sessão pode gerar no máximo um alerta para os técnicos que estavam
-- efetivamente online no momento em que o servidor entrou na fila.

alter table public.chat_sessions
  add column if not exists waiting_notification_sent_at timestamptz;

alter table public.email_outbox drop constraint if exists email_outbox_event_type_check;
alter table public.email_outbox add constraint email_outbox_event_type_check check(event_type in (
  'recebido','aberto_pelo_tecnico','em_atendimento','atualizacao','concluido',
  'novo_chamado_tecnico','resposta_servidor_tecnico','chat_aguardando_tecnico',
  'reserva_confirmar','reserva_confirmada','reserva_autorizada','reserva_cancelada','reserva_alterada',
  'reserva_acesso','reserva_cancelamento_confirmar',
  'reserva_cancelamento_aprovado','reserva_cancelamento_rejeitado'
));

create or replace function public.queue_waiting_chat_staff_email()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_server public.servers;
begin
  -- Só há alerta quando a sessão nasce aguardando atendimento. A marca na
  -- própria sessão torna a operação idempotente mesmo em caso de retry.
  if new.status <> 'waiting' or new.waiting_notification_sent_at is not null then
    return new;
  end if;

  update public.chat_sessions
  set waiting_notification_sent_at = now()
  where id = new.id
    and waiting_notification_sent_at is null;

  if not found then return new; end if;

  select * into v_server from public.servers where id = new.server_id;
  if v_server.id is null then return new; end if;

  insert into public.email_outbox(recipient, event_type, payload)
  select lower(p.email),
         'chat_aguardando_tecnico',
         jsonb_build_object(
           'protocol', 'CHAT-' || upper(left(replace(new.id::text, '-', ''), 8)),
           'title', coalesce(nullif(new.subject, ''), 'Atendimento via chat'),
           'lab', 'Chat ao vivo',
           'category', 'Atendimento imediato',
           'server_name', v_server.full_name,
           'server_email', v_server.email
         )
  from public.staff_chat_status scs
  join public.profiles p on p.id = scs.profile_id
  where scs.is_online = true
    and scs.last_heartbeat >= now() - interval '3 minutes'
    and p.active = true
    and p.role in ('tecnico', 'supervisor')
    and nullif(trim(p.email), '') is not null;

  return new;
end;
$$;

drop trigger if exists queue_waiting_chat_staff_email on public.chat_sessions;
create trigger queue_waiting_chat_staff_email
after insert on public.chat_sessions
for each row execute function public.queue_waiting_chat_staff_email();
