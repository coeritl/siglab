-- LabInfo TL — Migração para suporte a Chat ao Vivo entre Técnicos e Servidores
-- Execute no SQL Editor do Supabase para habilitar o módulo de chat em tempo real.

-- 1. Atualizar a constraint de tickets para aceitar 'Chat' como source
alter table public.tickets drop constraint if exists tickets_source_check;
alter table public.tickets add constraint tickets_source_check
  check (source in ('Formulario', 'Tecnico', 'Email', 'Chat'));

-- 2. Tabela de status online / disponibilidade dos técnicos
create table if not exists public.staff_chat_status (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  is_online boolean not null default false,
  last_heartbeat timestamptz not null default now()
);

-- 3. Tabela de sessões de chat
create table if not exists public.chat_sessions (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references servers(id),
  technician_id uuid references profiles(id),
  status text not null default 'waiting' check (status in ('waiting', 'active', 'closed', 'cancelled')),
  subject text,
  ticket_id uuid references tickets(id) on delete set null,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  closed_at timestamptz,
  closed_by uuid references profiles(id),
  notes text
);

-- 4. Tabela de mensagens do chat
create table if not exists public.chat_messages (
  id bigint generated always as identity primary key,
  session_id uuid not null references public.chat_sessions(id) on delete cascade,
  sender_type text not null check (sender_type in ('server', 'technician', 'system')),
  sender_id uuid,
  sender_name text not null,
  message text not null,
  created_at timestamptz not null default now()
);

-- Índices para performance
create index if not exists chat_sessions_status_idx on public.chat_sessions(status, created_at desc);
create index if not exists chat_sessions_server_idx on public.chat_sessions(server_id, created_at desc);
create index if not exists chat_messages_session_idx on public.chat_messages(session_id, created_at asc);

-- 5. Habilitar Realtime
alter publication supabase_realtime add table public.staff_chat_status;
alter publication supabase_realtime add table public.chat_sessions;
alter publication supabase_realtime add table public.chat_messages;

alter table public.staff_chat_status replica identity full;
alter table public.chat_sessions replica identity full;
alter table public.chat_messages replica identity full;

-- 6. Habilitar RLS
alter table public.staff_chat_status enable row level security;
alter table public.chat_sessions enable row level security;
alter table public.chat_messages enable row level security;

-- Políticas de RLS
create policy "staff_status_read_all" on public.staff_chat_status
  for select using (true);

create policy "staff_status_write_auth" on public.staff_chat_status
  for all using (auth.role() = 'authenticated');

create policy "chat_sessions_read" on public.chat_sessions
  for select using (true);

create policy "chat_sessions_insert" on public.chat_sessions
  for insert with check (true);

create policy "chat_sessions_update" on public.chat_sessions
  for update using (auth.role() = 'authenticated' or status in ('waiting', 'active', 'closed'));

create policy "chat_messages_read" on public.chat_messages
  for select using (true);

create policy "chat_messages_insert" on public.chat_messages
  for insert with check (true);

-- 7. Funções RPC de Negócio

-- Obter disponibilidade geral (se há algum técnico online com heartbeat recente nos últimos 3 minutos)
drop function if exists public.get_chat_availability();
create or replace function public.get_chat_availability()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_online_count integer;
  v_technicians jsonb;
begin
  -- Marca como offline quem não deu heartbeat há mais de 3 minutos
  update public.staff_chat_status
  set is_online = false
  where is_online = true and last_heartbeat < (now() - interval '3 minutes');

  select count(*), jsonb_agg(jsonb_build_object('id', p.id, 'name', p.full_name, 'role', p.role, 'email', p.email))
  into v_online_count, v_technicians
  from public.staff_chat_status s
  join public.profiles p on p.id = s.profile_id
  where s.is_online = true and p.active = true and p.role in ('tecnico', 'supervisor') and s.last_heartbeat >= (now() - interval '3 minutes');

  return jsonb_build_object(
    'available', (coalesce(v_online_count, 0) > 0),
    'online_count', coalesce(v_online_count, 0),
    'technicians', coalesce(v_technicians, '[]'::jsonb)
  );
end $$;
grant execute on function public.get_chat_availability() to anon, authenticated;

-- Atualizar status do técnico logado
drop function if exists public.set_staff_chat_status(boolean);
create or replace function public.set_staff_chat_status(p_online boolean)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid;
begin
  v_uid := auth.uid();
  if v_uid is null then
    raise exception 'Apenas usuários autenticados podem alterar status.';
  end if;

  insert into public.staff_chat_status (profile_id, is_online, last_heartbeat)
  values (v_uid, p_online, now())
  on conflict (profile_id) do update
  set is_online = p_online,
      last_heartbeat = now();

  return p_online;
end $$;
grant execute on function public.set_staff_chat_status(boolean) to authenticated;

-- Heartbeat periódico do técnico logado para manter status ativo
drop function if exists public.staff_chat_heartbeat();
create or replace function public.staff_chat_heartbeat()
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid;
begin
  v_uid := auth.uid();
  if v_uid is null then return false; end if;

  update public.staff_chat_status
  set last_heartbeat = now()
  where profile_id = v_uid and is_online = true;

  return true;
end $$;
grant execute on function public.staff_chat_heartbeat() to authenticated;

-- Solicitar uma nova sessão de chat pelo servidor/docente (validação por SIAPE)
drop function if exists public.request_chat_session(text, text);
create or replace function public.request_chat_session(p_siape text, p_subject text)
returns table(session_id uuid, server_id uuid, server_name text, server_email text, status text)
language plpgsql security definer set search_path = public as $$
declare
  v_server record;
  v_session_id uuid;
begin
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
grant execute on function public.request_chat_session(text, text) to anon, authenticated;

-- Técnico aceita a sessão de chat
drop function if exists public.accept_chat_session(uuid);
create or replace function public.accept_chat_session(p_session_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare
  v_uid uuid;
  v_tech_name text;
  v_first_name text;
  v_session record;
begin
  v_uid := auth.uid();
  if v_uid is null then
    raise exception 'Apenas técnicos autenticados podem aceitar chats.';
  end if;

  select coalesce(p.full_name, 'Técnico') into v_tech_name
  from public.profiles p
  where p.id = v_uid;

  if v_tech_name is null or length(trim(v_tech_name)) = 0 then
    v_tech_name := 'Técnico de Plantão';
  end if;

  v_first_name := coalesce(nullif(split_part(trim(v_tech_name), ' ', 1), ''), 'Técnico(a)');

  update public.chat_sessions cs
  set technician_id = coalesce(cs.technician_id, v_uid),
      status = 'active',
      started_at = coalesce(cs.started_at, now())
  where cs.id = p_session_id and cs.status in ('waiting', 'active');

  select cs.*, s.full_name as server_name, s.siape as server_siape, s.email as server_email
  into v_session
  from public.chat_sessions cs
  left join public.servers s on s.id = cs.server_id
  where cs.id = p_session_id;

  if v_session.id is null then
    raise exception 'Sessão de chat não encontrada.';
  end if;

  -- Insere aviso no chat informando quem atendeu (se ainda não houver aviso)
  if not exists (
    select 1 from public.chat_messages cm
    where cm.session_id = p_session_id and cm.sender_type = 'system' and cm.message like '%entrou na sala%'
  ) then
    insert into public.chat_messages(session_id, sender_type, sender_id, sender_name, message)
    values (p_session_id, 'system', v_uid, 'Sistema LabInfo', 'O(A) técnico(a) ' || v_tech_name || ' entrou na sala e iniciou o atendimento.');
  end if;

  -- Mensagem automática de boas-vindas personalizada em nome do próprio perfil que atendeu
  if not exists (
    select 1 from public.chat_messages cm
    where cm.session_id = p_session_id and cm.sender_type = 'technician'
  ) then
    insert into public.chat_messages(session_id, sender_type, sender_id, sender_name, message)
    values (p_session_id, 'technician', v_uid, v_tech_name, 'Olá, sou ' || v_first_name || '. Em que posso ajudar?');
  end if;

  return jsonb_build_object(
    'session_id', v_session.id,
    'technician_id', v_uid,
    'technician_name', v_tech_name,
    'status', v_session.status,
    'server_name', v_session.server_name,
    'server_siape', v_session.server_siape,
    'server_email', v_session.server_email,
    'subject', v_session.subject
  );
end $$;
grant execute on function public.accept_chat_session(uuid) to authenticated;

-- Enviar mensagem no chat (pelo servidor ou pelo técnico)
drop function if exists public.send_chat_message(uuid, text, text, text, text);
drop function if exists public.send_chat_message(uuid, text, text, text);
drop function if exists public.send_chat_message(uuid, text, text);
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

-- Gerar chamado oficial a partir do chat ao vivo (ação assistida do técnico)
drop function if exists public.create_ticket_from_chat(uuid, uuid, uuid, text, text, text);
drop function if exists public.create_ticket_from_chat(uuid, uuid, uuid, text, text);
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
  v_tech_id := auth.uid();
  if v_tech_id is null then
    raise exception 'Apenas técnicos autenticados podem gerar chamados a partir do chat.';
  end if;

  select cs.*, s.id as server_id, s.full_name as server_name, s.siape as server_siape, s.email as server_email
  into v_session
  from public.chat_sessions cs
  join public.servers s on s.id = cs.server_id
  where cs.id = p_session_id;

  if v_session.id is null then
    raise exception 'Sessão de chat não encontrada.';
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

  -- Cria o chamado
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
    closed_at
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
    case when v_status = 'Concluído' then now() else null end
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
      closed_by = v_tech_id,
      notes = coalesce(nullif(trim(p_resolution), ''), cs.notes)
  where cs.id = p_session_id;

  -- Notificação no chat para o docente
  insert into public.chat_messages(session_id, sender_type, sender_id, sender_name, message)
  values (
    p_session_id,
    'system',
    v_tech_id,
    'Sistema LabInfo',
    'Atendimento finalizado! Foi gerado o protocolo oficial de chamado: ' || v_protocol || '. Você também receberá os detalhes no seu e-mail institucional.'
  );

  return jsonb_build_object(
    'ticket_id', v_new_ticket_id,
    'protocol', v_protocol,
    'status', v_status
  );
end $$;
grant execute on function public.create_ticket_from_chat(uuid, uuid, uuid, text, text, text) to authenticated;

-- Encerrar chat simples (caso queira encerrar pelo docente ou sem formulário)
drop function if exists public.close_chat_session(uuid, text);
drop function if exists public.close_chat_session(uuid);
create or replace function public.close_chat_session(p_session_id uuid, p_notes text default null)
returns boolean language plpgsql security definer set search_path = public, auth as $$
begin
  update public.chat_sessions cs
  set status = 'closed',
      closed_at = now(),
      closed_by = auth.uid(),
      notes = coalesce(p_notes, cs.notes)
  where cs.id = p_session_id and cs.status in ('waiting', 'active');

  insert into public.chat_messages(session_id, sender_type, sender_name, message)
  values (p_session_id, 'system', 'Sistema LabInfo', 'Atendimento de chat encerrado.');

  return true;
end $$;
grant execute on function public.close_chat_session(uuid, text) to anon, authenticated;

-- Obter dados consolidados da sessao de chat (publico ou autenticado)
drop function if exists public.get_public_chat_session(uuid);
create or replace function public.get_public_chat_session(p_session_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_session record;
  v_tech_name text := null;
  v_protocol text := null;
begin
  select cs.*, s.full_name as server_name, s.siape as server_siape
  into v_session
  from public.chat_sessions cs
  left join public.servers s on s.id = cs.server_id
  where cs.id = p_session_id;

  if v_session.id is null then
    return null;
  end if;

  if v_session.technician_id is not null then
    select p.full_name into v_tech_name
    from public.profiles p
    where p.id = v_session.technician_id;
  end if;

  if v_session.ticket_id is not null then
    select t.protocol into v_protocol
    from public.tickets t
    where t.id = v_session.ticket_id;
  end if;

  return jsonb_build_object(
    'id', v_session.id,
    'status', v_session.status,
    'subject', v_session.subject,
    'server_name', v_session.server_name,
    'server_siape', v_session.server_siape,
    'technician_name', coalesce(v_tech_name, 'Técnico de Plantão'),
    'protocol', v_protocol,
    'started_at', v_session.started_at,
    'closed_at', v_session.closed_at
  );
end $$;
grant execute on function public.get_public_chat_session(uuid) to anon, authenticated;

-- Obter lista consolidada de sessoes para o painel administrativo do tecnico
drop function if exists public.get_admin_chat_dashboard();
create or replace function public.get_admin_chat_dashboard()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_sessions jsonb;
begin
  -- Auto-encerra solicitações que ficaram esperando por mais de 20 minutos sem atendimento
  update public.chat_sessions
  set status = 'closed',
      closed_at = now(),
      notes = coalesce(notes, 'Expirado por inatividade na fila')
  where status = 'waiting' and created_at < (now() - interval '20 minutes');

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', cs.id,
    'status', cs.status,
    'subject', cs.subject,
    'created_at', cs.created_at,
    'started_at', cs.started_at,
    'closed_at', cs.closed_at,
    'notes', cs.notes,
    'server_id', cs.server_id,
    'server_name', coalesce(s.full_name, 'Servidor'),
    'server_siape', s.siape,
    'server_email', s.email,
    'technician_id', cs.technician_id,
    'technician_name', p.full_name,
    'ticket_id', cs.ticket_id,
    'ticket_protocol', t.protocol
  ) order by cs.created_at desc), '[]'::jsonb)
  into v_sessions
  from (
    select * from public.chat_sessions
    order by created_at desc
    limit 60
  ) cs
  left join public.servers s on s.id = cs.server_id
  left join public.profiles p on p.id = cs.technician_id
  left join public.tickets t on t.id = cs.ticket_id;

  return v_sessions;
end $$;
grant execute on function public.get_admin_chat_dashboard() to authenticated;

-- Limpar chamadas pendentes da fila de espera
drop function if exists public.clear_stale_chat_sessions();
create or replace function public.clear_stale_chat_sessions()
returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_count integer;
begin
  update public.chat_sessions
  set status = 'closed',
      closed_at = now(),
      notes = 'Fila limpa pelo técnico'
  where status = 'waiting';

  get diagnostics v_count = row_count;
  return v_count;
end $$;
grant execute on function public.clear_stale_chat_sessions() to authenticated;


