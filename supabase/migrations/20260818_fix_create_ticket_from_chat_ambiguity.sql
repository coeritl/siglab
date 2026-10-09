-- Migration: Resolução de ambiguidade na função create_ticket_from_chat
-- Elimina sobrecargas duplicadas e estabelece uma assinatura única canônica

-- 1. Remove explicitamente todas as versões sobrecarregadas anteriores
DROP FUNCTION IF EXISTS public.create_ticket_from_chat(uuid, uuid, uuid, text, text, public.ticket_status);
DROP FUNCTION IF EXISTS public.create_ticket_from_chat(uuid, uuid, uuid, text, text, text);
DROP FUNCTION IF EXISTS public.create_ticket_from_chat(uuid, uuid, uuid, text, text);
DROP FUNCTION IF EXISTS public.create_ticket_from_chat(uuid, text, text, text, text, text);
DROP FUNCTION IF EXISTS public.create_ticket_from_chat(uuid, text, text);
DROP FUNCTION IF EXISTS public.create_ticket_from_chat(uuid);

-- 2. Cria a função canônica com assinatura única
CREATE OR REPLACE FUNCTION public.create_ticket_from_chat(
  p_session_id uuid,
  p_lab uuid default null,
  p_category uuid default null,
  p_title text default null,
  p_resolution text default null,
  p_status text default 'Concluído'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth AS $$
DECLARE
  v_session record;
  v_tech_id uuid;
  v_protocol text;
  v_new_ticket_id uuid;
  v_chat_transcript text := '';
  v_msg record;
  v_title text;
  v_status_clean text;
  v_status_enum public.ticket_status;
BEGIN
  -- Garante status válido
  v_status_clean := coalesce(nullif(trim(p_status), ''), 'Concluído');
  IF v_status_clean NOT IN ('Recebido', 'Em atendimento', 'Concluído') THEN
    v_status_clean := 'Concluído';
  END IF;
  v_status_enum := v_status_clean::public.ticket_status;

  SELECT cs.*, s.id as server_id, s.full_name as server_name, s.siape as server_siape, s.email as server_email
  INTO v_session
  FROM public.chat_sessions cs
  JOIN public.servers s ON s.id = cs.server_id
  WHERE cs.id = p_session_id;

  IF v_session.id IS NULL THEN
    RAISE EXCEPTION 'Sessão de chat não encontrada.';
  END IF;

  -- Se já tiver chamado vinculado, apenas retorna os dados existentes
  IF v_session.ticket_id IS NOT NULL THEN
    SELECT protocol INTO v_protocol FROM public.tickets WHERE id = v_session.ticket_id;
    RETURN jsonb_build_object(
      'ticket_id', v_session.ticket_id,
      'protocol', v_protocol,
      'status', v_status_clean
    );
  END IF;

  -- Identifica o técnico responsável
  v_tech_id := auth.uid();
  IF v_tech_id IS NULL THEN
    v_tech_id := v_session.technician_id;
  END IF;

  -- Monta a transcrição do diálogo formatada
  FOR v_msg IN
    SELECT cm.sender_name, cm.sender_type, cm.message, cm.created_at
    FROM public.chat_messages cm
    WHERE cm.session_id = p_session_id
    ORDER BY cm.created_at ASC
  LOOP
    v_chat_transcript := v_chat_transcript || '[' || to_char(v_msg.created_at at time zone 'America/Cuiaba', 'DD/MM/YYYY HH24:MI') || '] ' || v_msg.sender_name || ': ' || v_msg.message || E'\n';
  END LOOP;

  -- Gera número de protocolo
  v_protocol := public.next_protocol(p_lab);
  v_title := coalesce(nullif(trim(p_title), ''), 'Atendimento via Chat: ' || coalesce(v_session.subject, 'Dúvida/Suporte'));

  -- Cria o chamado oficial com feedback_token
  INSERT INTO public.tickets(
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
  VALUES (
    v_protocol,
    v_session.server_id,
    p_lab,
    p_category,
    left(v_title, 100),
    E'Atendimento realizado via Chat ao Vivo com a equipe de TI.\n\n--- TRANSCRIÇÃO DA CONVERSA ---\n' || v_chat_transcript,
    v_status_enum,
    'Chat',
    v_tech_id,
    CASE WHEN v_status_clean = 'Concluído' THEN coalesce(nullif(trim(p_resolution), ''), 'Atendimento concluído via Chat ao Vivo.') ELSE NULL END,
    coalesce(v_session.started_at, now()),
    CASE WHEN v_status_clean = 'Concluído' THEN now() ELSE NULL END,
    gen_random_uuid()
  )
  RETURNING tickets.id INTO v_new_ticket_id;

  -- Registra no histórico do chamado
  INSERT INTO public.ticket_updates(ticket_id, author_id, message, kind)
  VALUES (
    v_new_ticket_id,
    v_tech_id,
    CASE WHEN v_status_clean = 'Concluído'
      THEN 'Chamado gerado e concluído a partir do Chat ao Vivo. Solução registrada: ' || coalesce(nullif(trim(p_resolution), ''), 'Atendimento prestado em tempo real.')
      ELSE 'Chamado gerado a partir do Chat ao Vivo e mantido em atendimento presencial pela equipe técnica.'
    END,
    CASE WHEN v_status_clean = 'Concluído' THEN 'fechamento' ELSE 'status' END
  );

  -- Atualiza e encerra a sessão de chat vinculando ao chamado
  UPDATE public.chat_sessions cs
  SET status = 'closed',
      ticket_id = v_new_ticket_id,
      closed_at = now(),
      closed_by = coalesce(v_tech_id, cs.closed_by),
      notes = coalesce(nullif(trim(p_resolution), ''), cs.notes)
  WHERE cs.id = p_session_id;

  -- Notificação no chat para o docente
  INSERT INTO public.chat_messages(session_id, sender_type, sender_id, sender_name, message)
  VALUES (
    p_session_id,
    'system',
    v_tech_id,
    'Sistema LabInfo',
    'Atendimento finalizado! Um e-mail com os detalhes do chamado (' || v_protocol || ') e o link de confirmação foi enviado para ' || v_session.server_email || '.'
  );

  RETURN jsonb_build_object(
    'ticket_id', v_new_ticket_id,
    'protocol', v_protocol,
    'status', v_status_clean
  );
END $$;

GRANT EXECUTE ON FUNCTION public.create_ticket_from_chat(uuid, uuid, uuid, text, text, text) TO anon, authenticated;

-- 3. Atualiza close_chat_session para usar a assinatura canônica
CREATE OR REPLACE FUNCTION public.close_chat_session(p_session_id uuid, p_notes text default null)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth AS $$
DECLARE
  v_sess record;
BEGIN
  SELECT * INTO v_sess FROM public.chat_sessions WHERE id = p_session_id;
  IF v_sess.id IS NULL THEN
    RETURN false;
  END IF;

  -- Se a sessão estava ativa e ainda não tinha chamado gerado, gera automaticamente o chamado concluído
  IF v_sess.status = 'active' AND v_sess.ticket_id IS NULL THEN
    PERFORM public.create_ticket_from_chat(
      p_session_id,
      null,
      null,
      null,
      coalesce(p_notes, 'Atendimento concluído via Chat ao Vivo.'),
      'Concluído'
    );
    RETURN true;
  END IF;

  UPDATE public.chat_sessions cs
  SET status = 'closed',
      closed_at = now(),
      closed_by = coalesce(auth.uid(), cs.technician_id),
      notes = coalesce(p_notes, cs.notes)
  WHERE cs.id = p_session_id AND cs.status IN ('waiting', 'active');

  INSERT INTO public.chat_messages(session_id, sender_type, sender_name, message)
  VALUES (p_session_id, 'system', 'Sistema LabInfo', 'Atendimento de chat encerrado.');

  RETURN true;
END $$;

GRANT EXECUTE ON FUNCTION public.close_chat_session(uuid, text) TO anon, authenticated;
