-- Correção dos achados críticos da auditoria de 26/08/2026:
-- 1) Leitura/escrita pública irrestrita em chat_sessions/chat_messages (RLS "using(true)").
-- 2) create_ticket_from_chat liberada para anon sem checagem de autenticação.
-- Execute este arquivo por último, depois de todas as migrations anteriores já aplicadas.

-- ============================================================
-- 1. Chat ao vivo: RLS deixa de ser pública, escrita passa a ser
--    exclusivamente pelas funções de segurança (RPCs) já existentes.
-- ============================================================

drop policy if exists "chat_sessions_read" on public.chat_sessions;
drop policy if exists "chat_sessions_insert" on public.chat_sessions;
drop policy if exists "chat_sessions_update" on public.chat_sessions;
drop policy if exists "chat_messages_read" on public.chat_messages;
drop policy if exists "chat_messages_insert" on public.chat_messages;

-- Somente técnicos/supervisores autenticados podem consultar as tabelas
-- diretamente. O público (anon) passa a acessar exclusivamente pelas
-- funções security definer (request_chat_session, send_chat_message,
-- get_public_chat_session, get_public_chat_messages, close_chat_session),
-- que já existiam e já validam o que cada chamador pode fazer.
create policy chat_sessions_staff_read on public.chat_sessions
  for select to authenticated
  using (public.current_role() in ('tecnico','supervisor'));

create policy chat_sessions_staff_update on public.chat_sessions
  for update to authenticated
  using (public.current_role() in ('tecnico','supervisor'))
  with check (public.current_role() in ('tecnico','supervisor'));

create policy chat_messages_staff_read on public.chat_messages
  for select to authenticated
  using (public.current_role() in ('tecnico','supervisor'));

-- Nenhuma policy de insert é recriada: toda inserção (pelo público ou pela
-- equipe) passa pelas funções security definer, que continuam funcionando
-- normalmente porque funções security definer não são afetadas por RLS.

-- Função pública equivalente a loadPublicChatMessages, para o docente/servidor
-- acompanhar a própria conversa sem precisar de leitura direta na tabela.
-- Conhecer o session_id (UUID aleatório de 128 bits) já é a prova de posse
-- da sessão nesse fluxo anônimo; o que a policy antiga permitia e que este
-- fix elimina é listar TODAS as sessões/mensagens sem informar nenhum id.
create or replace function public.get_public_chat_messages(p_session_id uuid)
returns setof public.chat_messages
language sql stable security definer set search_path = public as $$
  select * from public.chat_messages
  where session_id = p_session_id
  order by created_at asc
$$;
grant execute on function public.get_public_chat_messages(uuid) to anon, authenticated;

-- ============================================================
-- 2. create_ticket_from_chat volta a exigir técnico autenticado.
--    A migration 20260818_fix_create_ticket_from_chat_ambiguity.sql
--    removeu essa checagem e liberou a função para "anon" — isso permitia
--    que qualquer visitante criasse chamados oficiais e disparasse e-mails
--    de "conclusão" em nome da equipe para qualquer servidor cadastrado.
-- ============================================================

drop function if exists public.create_ticket_from_chat(uuid, uuid, uuid, text, text, text);

create or replace function public.create_ticket_from_chat(
  p_session_id uuid,
  p_lab uuid default null,
  p_category uuid default null,
  p_title text default null,
  p_resolution text default null,
  p_status text default 'Concluído'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth as $$
declare
  v_session record;
  v_tech_id uuid;
  v_protocol text;
  v_new_ticket_id uuid;
  v_chat_transcript text := '';
  v_msg record;
  v_title text;
  v_status_clean text;
  v_status_enum public.ticket_status;
begin
  -- Exige técnico/supervisor autenticado; nada de fallback silencioso.
  v_tech_id := auth.uid();
  if v_tech_id is null or public.current_role() not in ('tecnico','supervisor') then
    raise exception 'Apenas técnicos autenticados podem gerar chamados a partir do chat.';
  end if;

  v_status_clean := coalesce(nullif(trim(p_status), ''), 'Concluído');
  if v_status_clean not in ('Recebido', 'Em atendimento', 'Concluído') then
    v_status_clean := 'Concluído';
  end if;
  v_status_enum := v_status_clean::public.ticket_status;

  select cs.*, s.id as server_id, s.full_name as server_name, s.siape as server_siape, s.email as server_email
  into v_session
  from public.chat_sessions cs
  join public.servers s on s.id = cs.server_id
  where cs.id = p_session_id;

  if v_session.id is null then
    raise exception 'Sessão de chat não encontrada.';
  end if;

  if v_session.ticket_id is not null then
    select protocol into v_protocol from public.tickets where id = v_session.ticket_id;
    return jsonb_build_object('ticket_id', v_session.ticket_id, 'protocol', v_protocol, 'status', v_status_clean);
  end if;

  for v_msg in
    select cm.sender_name, cm.sender_type, cm.message, cm.created_at
    from public.chat_messages cm
    where cm.session_id = p_session_id
    order by cm.created_at asc
  loop
    v_chat_transcript := v_chat_transcript || '[' || to_char(v_msg.created_at at time zone 'America/Cuiaba', 'DD/MM/YYYY HH24:MI') || '] ' || v_msg.sender_name || ': ' || v_msg.message || E'\n';
  end loop;

  v_protocol := public.next_protocol(p_lab);
  v_title := coalesce(nullif(trim(p_title), ''), 'Atendimento via Chat: ' || coalesce(v_session.subject, 'Dúvida/Suporte'));

  insert into public.tickets(
    protocol, server_id, lab_id, category_id, title, description, status, source,
    assigned_to, resolution, started_at, closed_at, feedback_token
  ) values (
    v_protocol, v_session.server_id, p_lab, p_category, left(v_title, 100),
    E'Atendimento realizado via Chat ao Vivo com a equipe de TI.\n\n--- TRANSCRIÇÃO DA CONVERSA ---\n' || v_chat_transcript,
    v_status_enum, 'Chat', v_tech_id,
    case when v_status_clean = 'Concluído' then coalesce(nullif(trim(p_resolution), ''), 'Atendimento concluído via Chat ao Vivo.') else null end,
    coalesce(v_session.started_at, now()),
    case when v_status_clean = 'Concluído' then now() else null end,
    gen_random_uuid()
  ) returning tickets.id into v_new_ticket_id;

  insert into public.ticket_updates(ticket_id, author_id, message, kind)
  values (
    v_new_ticket_id, v_tech_id,
    case when v_status_clean = 'Concluído'
      then 'Chamado gerado e concluído a partir do Chat ao Vivo. Solução registrada: ' || coalesce(nullif(trim(p_resolution), ''), 'Atendimento prestado em tempo real.')
      else 'Chamado gerado a partir do Chat ao Vivo e mantido em atendimento presencial pela equipe técnica.'
    end,
    case when v_status_clean = 'Concluído' then 'fechamento' else 'status' end
  );

  update public.chat_sessions cs
  set status = 'closed', ticket_id = v_new_ticket_id, closed_at = now(),
      closed_by = coalesce(v_tech_id, cs.closed_by),
      notes = coalesce(nullif(trim(p_resolution), ''), cs.notes)
  where cs.id = p_session_id;

  insert into public.chat_messages(session_id, sender_type, sender_id, sender_name, message)
  values (
    p_session_id, 'system', v_tech_id, 'Sistema LabInfo',
    'Atendimento finalizado! Um e-mail com os detalhes do chamado (' || v_protocol || ') e o link de confirmação foi enviado para ' || v_session.server_email || '.'
  );

  return jsonb_build_object('ticket_id', v_new_ticket_id, 'protocol', v_protocol, 'status', v_status_clean);
end $$;

-- Remove o acesso público concedido pela migration de ambiguidade e deixa
-- a função disponível somente para técnicos/supervisores autenticados.
revoke all on function public.create_ticket_from_chat(uuid, uuid, uuid, text, text, text) from public;
revoke all on function public.create_ticket_from_chat(uuid, uuid, uuid, text, text, text) from anon;
grant execute on function public.create_ticket_from_chat(uuid, uuid, uuid, text, text, text) to authenticated;
