-- Solicitação pública e auditável de cancelamento de reservas confirmadas.
-- O SIAPE apenas dispara um link de acesso para o e-mail cadastrado. O pedido
-- ainda exige uma segunda confirmação por e-mail antes de chegar à equipe.

create table if not exists public.reservation_access_tokens (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references public.servers(id) on delete cascade,
  token_hash text not null unique,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create index if not exists reservation_access_tokens_expiry_idx
  on public.reservation_access_tokens(expires_at);

create table if not exists public.reservation_cancellation_requests (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  server_id uuid not null references public.servers(id) on delete cascade,
  scope text not null check (scope in ('occurrence','future','series')),
  reason text,
  status text not null default 'awaiting_email'
    check (status in ('awaiting_email','pending','approved','rejected','expired')),
  confirmation_token_hash text not null unique,
  confirmation_expires_at timestamptz not null,
  email_confirmed_at timestamptz,
  reviewed_by uuid references public.profiles(id),
  reviewed_at timestamptz,
  review_notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists reservation_cancellation_active_request_key
  on public.reservation_cancellation_requests(reservation_id)
  where status in ('awaiting_email','pending');
create index if not exists reservation_cancellation_pending_idx
  on public.reservation_cancellation_requests(status,created_at);

alter table public.reservation_access_tokens enable row level security;
alter table public.reservation_cancellation_requests enable row level security;

drop policy if exists reservation_cancellation_staff_read on public.reservation_cancellation_requests;
create policy reservation_cancellation_staff_read
  on public.reservation_cancellation_requests for select to authenticated
  using (public.current_role() in ('tecnico','supervisor'));

alter table public.email_outbox drop constraint if exists email_outbox_event_type_check;
alter table public.email_outbox add constraint email_outbox_event_type_check check(event_type in (
  'recebido','aberto_pelo_tecnico','em_atendimento','atualizacao','concluido',
  'novo_chamado_tecnico','resposta_servidor_tecnico',
  'reserva_confirmar','reserva_confirmada','reserva_autorizada','reserva_cancelada','reserva_alterada',
  'reserva_acesso','reserva_cancelamento_confirmar',
  'reserva_cancelamento_aprovado','reserva_cancelamento_rejeitado'
));

create or replace function public.request_reservation_access(p_siape text)
returns boolean language plpgsql security definer set search_path=public,extensions as $$
declare
  s public.servers;
  raw_token uuid:=gen_random_uuid();
  token_digest text:=encode(digest(raw_token::text,'sha256'),'hex');
begin
  perform public.enforce_rate_limit('reservation_access',public.request_ip(),10,interval '1 hour');
  delete from public.reservation_access_tokens where expires_at<now();

  select server.* into s
  from public.servers server
  where server.siape=btrim(p_siape) and server.active
  limit 1;

  -- Resposta deliberadamente genérica para não revelar SIAPEs cadastrados.
  if s.id is null then return true; end if;

  insert into public.reservation_access_tokens(server_id,token_hash,expires_at)
  values(s.id,token_digest,now()+interval '30 minutes');

  insert into public.email_outbox(recipient,event_type,payload)
  values(lower(s.email),'reserva_acesso',jsonb_build_object(
    'server_name',s.full_name,
    'access_url','https://labinfo.tl.ifms.edu.br/reservas/?manage_reservations='||raw_token::text
  ));
  return true;
end $$;

create or replace function public.list_my_reservations_secure(p_token uuid)
returns table(
  id uuid,protocol text,subject text,lab text,starts_at timestamptz,ends_at timestamptz,
  status text,recurrence text,recurrence_group uuid,occurrence_count bigint,request_pending boolean
) language plpgsql stable security definer set search_path=public,extensions as $$
declare owner_id uuid;
begin
  select access.server_id into owner_id
  from public.reservation_access_tokens access
  where access.token_hash=encode(digest(p_token::text,'sha256'),'hex')
    and access.expires_at>now();
  if owner_id is null then raise exception 'Este link é inválido ou expirou. Solicite um novo acesso.'; end if;

  return query
  select r.id,r.protocol,r.subject,l.name,r.starts_at,r.ends_at,r.status,r.recurrence,
    r.recurrence_group,
    count(*) over(partition by r.recurrence_group),
    exists(select 1 from public.reservation_cancellation_requests cr
      where cr.reservation_id=r.id and cr.status in ('awaiting_email','pending'))
  from public.reservations r
  join public.labs l on l.id=r.lab_id
  where r.server_id=owner_id
    and r.status in ('Aguardando autorização','Autorizada')
    and r.ends_at>now()
  order by r.starts_at;
end $$;

create or replace function public.request_reservation_cancellation(
  p_access_token uuid,p_reservation uuid,p_scope text,p_reason text default null
) returns table(protocol text,status text)
language plpgsql security definer set search_path=public,extensions as $$
declare
  owner_id uuid;
  r public.reservations;
  s public.servers;
  raw_token uuid:=gen_random_uuid();
begin
  if p_scope not in ('occurrence','future','series') then raise exception 'Selecione o alcance do cancelamento.'; end if;
  if length(btrim(coalesce(p_reason,'')))>500 then raise exception 'O motivo deve ter até 500 caracteres.'; end if;

  select access.server_id into owner_id
  from public.reservation_access_tokens access
  where access.token_hash=encode(digest(p_access_token::text,'sha256'),'hex')
    and access.expires_at>now();
  if owner_id is null then raise exception 'Este link é inválido ou expirou. Solicite um novo acesso.'; end if;

  select reservation.* into r from public.reservations reservation
  where reservation.id=p_reservation and reservation.server_id=owner_id for update;
  if r.id is null then raise exception 'Reserva não localizada.'; end if;
  if r.status not in ('Aguardando autorização','Autorizada') or r.ends_at<=now() then
    raise exception 'Esta reserva não aceita solicitação de cancelamento.';
  end if;
  update public.reservation_cancellation_requests cr set status='expired',updated_at=now()
  where cr.reservation_id=r.id and cr.status='awaiting_email' and cr.confirmation_expires_at<now();
  if exists(select 1 from public.reservation_cancellation_requests cr
    where cr.reservation_id=r.id and cr.status in ('awaiting_email','pending')) then
    raise exception 'Já existe uma solicitação de cancelamento em andamento para esta reserva.';
  end if;

  select server.* into s from public.servers server where server.id=owner_id;
  insert into public.reservation_cancellation_requests(
    reservation_id,server_id,scope,reason,confirmation_token_hash,confirmation_expires_at
  ) values (
    r.id,owner_id,p_scope,nullif(btrim(p_reason),''),
    encode(digest(raw_token::text,'sha256'),'hex'),now()+interval '2 hours'
  );

  insert into public.email_outbox(reservation_id,recipient,event_type,payload)
  values(r.id,lower(s.email),'reserva_cancelamento_confirmar',
    public.reservation_payload(r)||jsonb_build_object(
      'scope',p_scope,'request_reason',nullif(btrim(p_reason),''),
      'cancellation_request_url','https://labinfo.tl.ifms.edu.br/reservas/?confirm_cancel_request='||raw_token::text
    ));
  return query select r.protocol,'awaiting_email'::text;
end $$;

create or replace function public.confirm_reservation_cancellation_request(p_token uuid)
returns table(protocol text,status text)
language plpgsql security definer set search_path=public,extensions as $$
declare req public.reservation_cancellation_requests; r public.reservations;
begin
  update public.reservation_cancellation_requests cr set
    status='expired',updated_at=now()
  where cr.status='awaiting_email' and cr.confirmation_expires_at<now();

  select cr.* into req from public.reservation_cancellation_requests cr
  where cr.confirmation_token_hash=encode(digest(p_token::text,'sha256'),'hex') for update;
  if req.id is null then raise exception 'Link de confirmação inválido.'; end if;
  if req.status='expired' then raise exception 'Este link expirou. Solicite novamente pelo portal.'; end if;
  if req.status<>'awaiting_email' then
    select * into r from public.reservations where id=req.reservation_id;
    return query select r.protocol,req.status; return;
  end if;

  update public.reservation_cancellation_requests set
    status='pending',email_confirmed_at=now(),updated_at=now()
  where id=req.id;
  select * into r from public.reservations where id=req.reservation_id;
  return query select r.protocol,'pending'::text;
end $$;

create or replace function public.staff_review_reservation_cancellation(
  p_request uuid,p_approve boolean,p_notes text default null
) returns table(protocol text,status text,affected_count integer)
language plpgsql security definer set search_path=public as $$
declare
  req public.reservation_cancellation_requests;
  r public.reservations;
  s public.servers;
  affected integer:=0;
  result_status text;
  event_name text;
begin
  if public.current_role() not in ('tecnico','supervisor') then raise exception 'Acesso negado.'; end if;
  if length(btrim(coalesce(p_notes,'')))>500 then raise exception 'A observação deve ter até 500 caracteres.'; end if;

  select cr.* into req from public.reservation_cancellation_requests cr where cr.id=p_request for update;
  if req.id is null then raise exception 'Solicitação não localizada.'; end if;
  if req.status<>'pending' then raise exception 'Esta solicitação já foi analisada ou ainda não foi confirmada.'; end if;
  select * into r from public.reservations where id=req.reservation_id for update;
  select * into s from public.servers where id=req.server_id;

  if p_approve then
    update public.reservations reservation set
      status='Cancelada',cancelled_at=now(),updated_at=now(),
      cancellation_reason=coalesce(nullif(btrim(req.reason),''),'Cancelamento solicitado pelo servidor e aprovado pela equipe.')
    where reservation.status<>'Cancelada' and reservation.ends_at>now() and (
      (req.scope='occurrence' and reservation.id=r.id) or
      (req.scope='future' and reservation.recurrence_group=r.recurrence_group and reservation.starts_at>=r.starts_at) or
      (req.scope='series' and reservation.recurrence_group=r.recurrence_group)
    );
    get diagnostics affected=row_count;
    result_status:='approved';event_name:='reserva_cancelamento_aprovado';
  else
    result_status:='rejected';event_name:='reserva_cancelamento_rejeitado';
  end if;

  update public.reservation_cancellation_requests set
    status=result_status,reviewed_by=auth.uid(),reviewed_at=now(),
    review_notes=nullif(btrim(p_notes),''),updated_at=now()
  where id=req.id;

  insert into public.email_outbox(reservation_id,recipient,event_type,payload)
  values(r.id,lower(s.email),event_name,public.reservation_payload(r)||jsonb_build_object(
    'scope',req.scope,'request_reason',req.reason,'review_notes',nullif(btrim(p_notes),''),
    'affected_count',affected
  ));
  return query select r.protocol,result_status,affected;
end $$;

revoke all on function public.request_reservation_access(text) from public;
revoke all on function public.list_my_reservations_secure(uuid) from public;
revoke all on function public.request_reservation_cancellation(uuid,uuid,text,text) from public;
revoke all on function public.confirm_reservation_cancellation_request(uuid) from public;
revoke all on function public.staff_review_reservation_cancellation(uuid,boolean,text) from public;
grant execute on function public.request_reservation_access(text) to anon,authenticated;
grant execute on function public.list_my_reservations_secure(uuid) to anon,authenticated;
grant execute on function public.request_reservation_cancellation(uuid,uuid,text,text) to anon,authenticated;
grant execute on function public.confirm_reservation_cancellation_request(uuid) to anon,authenticated;
grant execute on function public.staff_review_reservation_cancellation(uuid,boolean,text) to authenticated;

do $$ begin
  alter publication supabase_realtime add table public.reservation_cancellation_requests;
exception when duplicate_object then null; end $$;
