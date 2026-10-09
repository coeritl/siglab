-- Proteções finais do módulo de reservas para uso em produção.
create extension if not exists btree_gist with schema extensions;

alter table public.reservations add column if not exists confirmation_expires_at timestamptz;
update public.reservations set confirmation_expires_at=created_at+interval '72 hours' where confirmation_expires_at is null;
alter table public.reservations
  alter column confirmation_expires_at set default (now()+interval '72 hours'),
  alter column confirmation_expires_at set not null;

alter table public.reservations drop constraint if exists reservations_no_schedule_overlap;
alter table public.reservations add constraint reservations_no_schedule_overlap
  exclude using gist (lab_id with =,tstzrange(starts_at,ends_at,'[)') with &&)
  where (status<>'Cancelada');

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
  select * into s from public.servers where siape=btrim(p_siape) and active limit 1;
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

create or replace function public.confirm_reservation(p_token uuid)
returns table(protocol text,status text,confirmed_at timestamptz)
language plpgsql security definer set search_path=public as $$
declare r public.reservations;s public.servers;
begin
  select reservation.* into r from public.reservations reservation
  where reservation.confirmation_token=p_token order by reservation.starts_at limit 1 for update;
  if r.id is null then raise exception 'Link inválido ou reserva indisponível.';end if;
  if r.status not in ('Aguardando confirmação','Aguardando autorização') then
    raise exception 'Esta reserva não está mais aguardando confirmação.';
  end if;
  if r.confirmed_at is null and r.confirmation_expires_at<now() then
    raise exception 'Este link de confirmação expirou. Entre em contato com a equipe técnica.';
  end if;
  if r.confirmed_at is null then
    update public.reservations reservation set status='Aguardando autorização',confirmed_at=now(),updated_at=now()
    where reservation.recurrence_group=r.recurrence_group and reservation.status='Aguardando confirmação';
  end if;
  select reservation.* into r from public.reservations reservation where reservation.id=r.id;
  select server.* into s from public.servers server where server.id=r.server_id and server.active;
  if r.confirmed_at is not null and s.id is not null and not exists(
    select 1 from public.email_outbox outbox where outbox.reservation_id=r.id and outbox.event_type='reserva_confirmada'
  ) then
    insert into public.email_outbox(reservation_id,recipient,event_type,payload)
    values(r.id,lower(s.email),'reserva_confirmada',public.reservation_payload(r));
  end if;
  return query select r.protocol,r.status,r.confirmed_at;
end $$;

create or replace function public.public_reservation_schedule(p_lab uuid,p_from date,p_to date)
returns table(id uuid,subject text,server_name text,starts_at timestamptz,ends_at timestamptz,status text)
language plpgsql stable security definer set search_path=public as $$
begin
  if p_to<p_from or p_to>p_from+42 then raise exception 'Período de consulta inválido.';end if;
  if not exists(select 1 from public.labs lab where lab.id=p_lab and lab.active and lab.reservation_enabled) then
    raise exception 'Laboratório indisponível para consulta pública.';
  end if;
  return query select r.id,
    case when r.status='Autorizada' then r.subject else 'Horário em análise' end,
    case when r.status='Autorizada' then s.full_name else null end,
    r.starts_at,r.ends_at,r.status
  from public.reservations r join public.servers s on s.id=r.server_id
  where r.lab_id=p_lab and r.status<>'Cancelada'
    and (r.starts_at at time zone 'America/Cuiaba')::date between p_from and p_to order by r.starts_at;
end $$;

grant execute on function public.create_public_reservation_range(text,uuid,text,timestamptz,timestamptz,text,text,date) to anon,authenticated;
grant execute on function public.confirm_reservation(uuid) to anon,authenticated;
grant execute on function public.public_reservation_schedule(uuid,date,date) to anon,authenticated;
