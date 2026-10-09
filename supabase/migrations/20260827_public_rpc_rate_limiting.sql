-- Achado P1 2.1 da auditoria de 26/08/2026:
-- identify_server e request_chat_session funcionam como um "oráculo" público de
-- SIAPE: bastava tentar números em sequência para descobrir quais são válidos e
-- obter nome/e-mail do servidor associado. create_public_reservation_range
-- também é um alvo de abuso (flood de solicitações de reserva).
-- Esta migration adiciona um limitador de taxa genérico por IP de origem,
-- reaproveitado nas três funções.
--
-- Observação de projeto: o identificador usado é o IP de origem (cabeçalho
-- x-forwarded-for, que a infraestrutura do Supabase preenche automaticamente).
-- Como os laboratórios do campus provavelmente saem para a internet por um
-- NAT/IP compartilhado, os limites abaixo foram definidos de forma generosa
-- (dezenas de tentativas por janela de minutos) para não bloquear uso legítimo
-- simultâneo de várias pessoas atrás do mesmo IP, mantendo ainda assim uma
-- barreira relevante contra varredura automatizada de milhares de SIAPEs.

-- ============================================================
-- 1. Estrutura genérica de rate limiting
-- ============================================================

create table if not exists public.rate_limit_log (
  id bigserial primary key,
  scope text not null,
  identity text not null,
  created_at timestamptz not null default now()
);

create index if not exists rate_limit_log_lookup_idx
  on public.rate_limit_log(scope, identity, created_at);

-- Índice para a limpeza oportunista por data, evitando scan completo da tabela.
create index if not exists rate_limit_log_created_at_idx
  on public.rate_limit_log(created_at);

comment on table public.rate_limit_log is
  'Registro de tentativas para limitação de taxa de RPCs públicas. Linhas com '
  'mais de 1 dia são removidas automaticamente pelas próprias chamadas de '
  'enforce_rate_limit (limpeza oportunista, sem necessidade de job agendado).';

-- Extrai o IP de origem do cabeçalho que o PostgREST/Supabase expõe em
-- request.headers. Retorna 'unknown' quando não disponível (ex.: chamada feita
-- fora do contexto HTTP, como em testes via SQL editor).
create or replace function public.request_ip()
returns text
language sql
stable
as $$
  select coalesce(
    nullif(btrim(split_part(current_setting('request.headers', true)::json->>'x-forwarded-for', ',', 1)), ''),
    'unknown'
  )
$$;

-- Registra uma tentativa no escopo informado e levanta exceção quando o total
-- de tentativas dentro da janela (contando a atual) ultrapassa p_max.
-- security definer + search_path fixo + revogado de anon/authenticated: só é
-- chamável a partir de outras funções security definer (que executam como o
-- dono da função, ignorando o revoke), nunca diretamente pelo público.
create or replace function public.enforce_rate_limit(
  p_scope text,
  p_identity text,
  p_max_per_window integer,
  p_window interval
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  insert into public.rate_limit_log(scope, identity) values (p_scope, coalesce(nullif(btrim(p_identity), ''), 'unknown'));

  select count(*) into v_count
  from public.rate_limit_log
  where scope = p_scope
    and identity = coalesce(nullif(btrim(p_identity), ''), 'unknown')
    and created_at > now() - p_window;

  if v_count > p_max_per_window then
    raise exception 'Muitas tentativas em pouco tempo. Aguarde alguns minutos antes de tentar novamente.';
  end if;

  -- Limpeza oportunista: evita que a tabela cresça indefinidamente sem
  -- depender de um job agendado (pg_cron não é garantido no plano gratuito).
  if random() < 0.02 then
    delete from public.rate_limit_log where created_at < now() - interval '1 day';
  end if;
end $$;

revoke all on function public.enforce_rate_limit(text, text, integer, interval) from public;
revoke all on function public.enforce_rate_limit(text, text, integer, interval) from anon;
revoke all on function public.enforce_rate_limit(text, text, integer, interval) from authenticated;

revoke all on function public.request_ip() from public;
grant execute on function public.request_ip() to anon, authenticated;

-- ============================================================
-- 2. identify_server: era "language sql" sem nenhuma limitação; convertida
--    para plpgsql para poder aplicar o rate limit antes da consulta.
-- ============================================================

drop function if exists public.identify_server(text);

create or replace function public.identify_server(p_siape text)
returns table(id uuid, full_name text, email text)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.enforce_rate_limit('identify_server', public.request_ip(), 30, interval '10 minutes');

  return query
  select s.id, s.full_name, s.email
  from public.servers s
  where s.siape = p_siape and s.active
  limit 1;
end $$;

revoke all on function public.identify_server(text) from public;
grant execute on function public.identify_server(text) to anon, authenticated;

-- ============================================================
-- 3. request_chat_session: mesmo padrão de oráculo de SIAPE.
-- ============================================================

create or replace function public.request_chat_session(p_siape text, p_subject text)
returns table(session_id uuid, server_id uuid, server_name text, server_email text, status text)
language plpgsql security definer set search_path = public as $$
declare
  v_server record;
  v_session_id uuid;
begin
  perform public.enforce_rate_limit('request_chat_session', public.request_ip(), 20, interval '10 minutes');

  select s.id, s.full_name, s.email, s.active into v_server
  from public.servers s
  where s.siape = trim(p_siape) and s.active = true;

  if v_server.id is null then
    raise exception 'SIAPE não localizado ou cadastro inativo. Procure a equipe técnica.';
  end if;

  insert into public.chat_sessions(server_id, status, subject)
  values (v_server.id, 'waiting', left(coalesce(nullif(trim(p_subject), ''), 'Atendimento rápido via chat'), 160))
  returning chat_sessions.id into v_session_id;

  -- Mensagem automática do sistema de boas-vindas
  insert into public.chat_messages(session_id, sender_type, sender_name, message)
  values (v_session_id, 'system', 'Sistema LabInfo', 'Sua solicitação foi enviada aos técnicos de plantão. Aguarde um momento enquanto um técnico se conecta.');

  return query
  select v_session_id, v_server.id, v_server.full_name, v_server.email, 'waiting'::text;
end $$;

revoke all on function public.request_chat_session(text, text) from public;
grant execute on function public.request_chat_session(text, text) to anon, authenticated;

-- ============================================================
-- 4. create_public_reservation_range: throttle contra flood de solicitações
--    de reserva (a validação de conflito de horário já existe via exclusion
--    constraint; isto complementa contra abuso volumétrico).
-- ============================================================

create or replace function public.create_public_reservation_range(
  p_siape text,p_lab uuid,p_subject text,p_start timestamptz,p_end timestamptz,
  p_notes text default null,p_recurrence text default 'none',p_until date default null
)
returns table(id uuid,protocol text,status text) language plpgsql security definer set search_path=public,extensions as $$
declare
  s public.servers;r public.reservations;first_r public.reservations;
  occurrence timestamptz:=p_start;finish timestamptz;requested_duration interval:=p_end-p_start;
  final_date date:=coalesce(p_until,(p_start at time zone 'America/Cuiaba')::date);
  group_id uuid:=gen_random_uuid();count_items integer:=0;
begin
  perform public.enforce_rate_limit('create_public_reservation_range', public.request_ip(), 20, interval '1 hour');

  select server.* into s from public.servers server where server.siape=btrim(p_siape) and server.active limit 1;
  if s.id is null then raise exception 'Servidor não localizado ou inativo.';end if;
  if not exists(select 1 from public.labs lab where lab.id=p_lab and lab.active and lab.reservation_enabled) then
    raise exception 'Laboratório indisponível para reservas públicas.';
  end if;
  if p_start<=now() then raise exception 'Não é possível solicitar uma reserva em data ou horário passado.';end if;
  if length(btrim(coalesce(p_subject,''))) not between 2 and 160 then raise exception 'Informe a disciplina ou atividade.';end if;
  perform public.validate_reservation_slot(p_start,p_end);
  if p_recurrence not in ('none','weekly') then raise exception 'Repetição inválida.';end if;
  if final_date<(p_start at time zone 'America/Cuiaba')::date or final_date>(p_start at time zone 'America/Cuiaba')::date+interval '180 days' then
    raise exception 'A data final deve estar dentro dos próximos 180 dias.';
  end if;
  loop
    if extract(isodow from occurrence at time zone 'America/Cuiaba') between 1 and 6 then
      finish:=occurrence+requested_duration;
      perform public.assert_reservation_available(p_lab,occurrence,finish,null);
      insert into public.reservations(protocol,server_id,lab_id,subject,notes,starts_at,ends_at,recurrence_group,recurrence)
      values(public.next_reservation_protocol(),s.id,p_lab,btrim(p_subject),nullif(btrim(p_notes),''),occurrence,finish,group_id,p_recurrence)
      returning * into r;
      if count_items=0 then first_r:=r;end if;count_items:=count_items+1;
    end if;
    exit when p_recurrence='none' or (occurrence at time zone 'America/Cuiaba')::date>=final_date;
    occurrence:=occurrence+interval '7 days';
    exit when (occurrence at time zone 'America/Cuiaba')::date>final_date;
  end loop;
  if count_items=0 then raise exception 'A série não possui nenhuma data válida.';end if;
  insert into public.email_outbox(reservation_id,recipient,event_type,payload)
  values(first_r.id,lower(s.email),'reserva_confirmar',public.reservation_payload(first_r)||jsonb_build_object('series_count',count_items,'series_until',final_date));
  return query select first_r.id,first_r.protocol,first_r.status;
exception when exclusion_violation then
  raise exception 'O laboratório já possui reserva neste horário.';
end $$;

revoke all on function public.create_public_reservation_range(text,uuid,text,timestamptz,timestamptz,text,text,date) from public;
grant execute on function public.create_public_reservation_range(text,uuid,text,timestamptz,timestamptz,text,text,date) to anon, authenticated;

-- ============================================================
-- 5. send_chat_message: limite leve contra flood de mensagens dentro de uma
--    sessão de chat já existente (defesa em profundidade; item opcional do
--    achado P1 2.1).
-- ============================================================

create or replace function public.send_chat_message(
  p_session_id uuid,
  p_sender_type text,
  p_message text,
  p_sender_name text default null,
  p_siape text default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare
  v_session record;
  v_sender_name text := trim(coalesce(p_sender_name, ''));
  v_sender_id uuid := null;
  v_msg_id bigint;
  v_now timestamptz := now();
begin
  if p_sender_type <> 'technician' then
    perform public.enforce_rate_limit('send_chat_message:' || p_session_id::text, public.request_ip(), 60, interval '5 minutes');
  end if;

  if length(trim(p_message)) < 1 then
    raise exception 'A mensagem não pode ser vazia.';
  end if;

  select cs.*, s.full_name as server_name, s.siape as server_siape
  into v_session
  from public.chat_sessions cs
  left join public.servers s on s.id = cs.server_id
  where cs.id = p_session_id;

  if v_session.id is null then
    raise exception 'Sessão de chat não encontrada.';
  end if;

  if v_session.status = 'closed' then
    raise exception 'Este atendimento já foi encerrado.';
  end if;

  if p_sender_type = 'technician' then
    v_sender_id := auth.uid();
    if v_sender_id is null then
      raise exception 'Acesso não autorizado.';
    end if;
    select coalesce(p.full_name, 'Técnico') into v_sender_name
    from public.profiles p
    where p.id = v_sender_id;

    if v_sender_name is null or length(trim(v_sender_name)) = 0 then
      v_sender_name := 'Técnico de Plantão';
    end if;
  elsif p_sender_type = 'server' then
    if length(v_sender_name) < 2 then
      v_sender_name := coalesce(v_session.server_name, 'Servidor');
    end if;
    v_sender_id := v_session.server_id;
  else
    p_sender_type := 'system';
    v_sender_name := 'Sistema LabInfo';
  end if;

  insert into public.chat_messages(session_id, sender_type, sender_id, sender_name, message, created_at)
  values (p_session_id, p_sender_type, v_sender_id, v_sender_name, trim(p_message), v_now)
  returning chat_messages.id into v_msg_id;

  return jsonb_build_object(
    'id', v_msg_id,
    'session_id', p_session_id,
    'sender_type', p_sender_type,
    'sender_name', v_sender_name,
    'message', trim(p_message),
    'created_at', v_now
  );
end $$;
grant execute on function public.send_chat_message(uuid, text, text, text, text) to anon, authenticated;
