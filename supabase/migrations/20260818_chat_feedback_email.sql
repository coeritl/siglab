-- Migration: Envio automático de e-mail de feedback e chamado ao finalizar chat ao vivo
-- Garante que todo atendimento de chat finalizado gere o chamado com histórico e link de feedback no e-mail do servidor

create or replace function public.create_ticket_from_chat(
  p_session_id uuid,
  p_lab uuid default null,
  p_category uuid default null,
  p_title text default null,
  p_resolution text default null,
  p_status text default 'Concluído'
)
returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare
  v_session record;
  v_tech_id uuid;
  v_protocol text;
  v_new_ticket_id uuid;
  v_chat_transcript text := '';
  v_msg record;
  v_title text;
  v_status text := coalesce(nullif(trim(p_status), ''), 'Concluído');
begin
  select cs.*, s.id as server_id, s.full_name as server_name, s.siape as server_siape, s.email as server_email
  into v_session
  from public.chat_sessions cs
  join public.servers s on s.id = cs.server_id
  where cs.id = p_session_id;

  if v_session.id is null then
    raise exception 'Sessão de chat não encontrada.';
  end if;

  -- Se já tiver chamado vinculado, apenas retorna os dados existentes
  if v_session.ticket_id is not null then
    select protocol into v_protocol from public.tickets where id = v_session.ticket_id;
    return jsonb_build_object(
      'ticket_id', v_session.ticket_id,
      'protocol', v_protocol,
      'status', v_status
    );
  end if;

  -- Identifica o técnico responsável
  v_tech_id := auth.uid();
  if v_tech_id is null then
    v_tech_id := v_session.technician_id;
  end if;

  -- Monta a transcrição do diálogo formatada
  for v_msg in
    select cm.sender_name, cm.sender_type, cm.message, cm.created_at
    from public.chat_messages cm
    where cm.session_id = p_session_id
    order by cm.created_at asc
  loop
    v_chat_transcript := v_chat_transcript || '[' || to_char(v_msg.created_at at time zone 'America/Cuiaba', 'DD/MM/YYYY HH24:MI') || '] ' || v_msg.sender_name || ': ' || v_msg.message || E'\n';
  end loop;

  -- Gera número de protocolo
  v_protocol := public.next_protocol(p_lab);
  v_title := coalesce(nullif(trim(p_title), ''), 'Atendimento via Chat: ' || coalesce(v_session.subject, 'Dúvida/Suporte'));

  -- Cria o chamado oficial com feedback_token
  insert into public.tickets(
    protocol,
    server_id,
    lab_id,
    category_id,
    title,
    description,
    status,
    source,
    assigned_to,
    resolution,
    started_at,
    closed_at,
    feedback_token
  )
  values (
    v_protocol,
    v_session.server_id,
    p_lab,
    p_category,
    left(v_title, 100),
    E'Atendimento realizado via Chat ao Vivo com a equipe de TI.\n\n--- TRANSCRIÇÃO DA CONVERSA ---\n' || v_chat_transcript,
    v_status,
    'Chat',
    v_tech_id,
    case when v_status = 'Concluído' then coalesce(nullif(trim(p_resolution), ''), 'Atendimento concluído via Chat ao Vivo.') else null end,
    coalesce(v_session.started_at, now()),
    case when v_status = 'Concluído' then now() else null end,
    gen_random_uuid()
  )
  returning tickets.id into v_new_ticket_id;

  -- Registra no histórico do chamado
  insert into public.ticket_updates(ticket_id, author_id, message, kind)
  values (
    v_new_ticket_id,
    v_tech_id,
    case when v_status = 'Concluído'
      then 'Chamado gerado e concluído a partir do Chat ao Vivo. Solução registrada: ' || coalesce(nullif(trim(p_resolution), ''), 'Atendimento prestado em tempo real.')
      else 'Chamado gerado a partir do Chat ao Vivo e mantido em atendimento presencial pela equipe técnica.'
    end,
    case when v_status = 'Concluído' then 'fechamento' else 'status' end
  );

  -- Atualiza e encerra a sessão de chat vinculando ao chamado
  update public.chat_sessions cs
  set status = 'closed',
      ticket_id = v_new_ticket_id,
      closed_at = now(),
      closed_by = coalesce(v_tech_id, cs.closed_by),
      notes = coalesce(nullif(trim(p_resolution), ''), cs.notes)
  where cs.id = p_session_id;

  -- Notificação no chat para o docente
  insert into public.chat_messages(session_id, sender_type, sender_id, sender_name, message)
  values (
    p_session_id,
    'system',
    v_tech_id,
    'Sistema LabInfo',
    'Atendimento finalizado! Um e-mail com os detalhes do chamado (' || v_protocol || ') e o link de confirmação foi enviado para ' || v_session.server_email || '.'
  );

  return jsonb_build_object(
    'ticket_id', v_new_ticket_id,
    'protocol', v_protocol,
    'status', v_status
  );
end $$;

grant execute on function public.create_ticket_from_chat(uuid, uuid, uuid, text, text, text) to anon, authenticated;

-- Encerrar chat garantindo criação de chamado e e-mail de feedback se for uma conversa ativa
create or replace function public.close_chat_session(p_session_id uuid, p_notes text default null)
returns boolean language plpgsql security definer set search_path = public, auth as $$
declare
  v_sess record;
begin
  select * into v_sess from public.chat_sessions where id = p_session_id;
  if v_sess.id is null then
    return false;
  end if;

  -- Se a sessão estava ativa e ainda não tinha chamado gerado, gera automaticamente o chamado concluído
  if v_sess.status = 'active' and v_sess.ticket_id is null then
    perform public.create_ticket_from_chat(
      p_session_id,
      null,
      null,
      null,
      coalesce(p_notes, 'Atendimento concluído via Chat ao Vivo.'),
      'Concluído'
    );
    return true;
  end if;

  update public.chat_sessions cs
  set status = 'closed',
      closed_at = now(),
      closed_by = coalesce(auth.uid(), cs.technician_id),
      notes = coalesce(p_notes, cs.notes)
  where cs.id = p_session_id and cs.status in ('waiting', 'active');

  insert into public.chat_messages(session_id, sender_type, sender_name, message)
  values (p_session_id, 'system', 'Sistema LabInfo', 'Atendimento de chat encerrado.');

  return true;
end $$;

grant execute on function public.close_chat_session(uuid, text) to anon, authenticated;
