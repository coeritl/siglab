-- Módulo de reservas dos Laboratórios de Informática.
create table if not exists public.reservation_counter (
  singleton boolean primary key default true check(singleton),
  last_number bigint not null default 0
);
insert into public.reservation_counter(singleton,last_number) values(true,0) on conflict(singleton) do nothing;

create table if not exists public.reservations (
  id uuid primary key default gen_random_uuid(),
  protocol text not null unique,
  server_id uuid not null references public.servers(id),
  lab_id uuid not null references public.labs(id),
  subject text not null check(length(btrim(subject)) between 2 and 160),
  notes text,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  status text not null default 'Aguardando confirmação' check(status in ('Aguardando confirmação','Aguardando autorização','Autorizada','Cancelada')),
  source text not null default 'Publico' check(source in ('Publico','Equipe','CSV')),
  recurrence_group uuid not null default gen_random_uuid(),
  recurrence text not null default 'none' check(recurrence in ('none','weekly')),
  confirmation_token uuid not null default gen_random_uuid() unique,
  confirmed_at timestamptz,
  authorized_at timestamptz,
  authorized_by uuid references public.profiles(id),
  cancelled_at timestamptz,
  cancellation_reason text,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(ends_at>starts_at),
  check(extract(epoch from (ends_at-starts_at))::integer % 2700=0)
);
create index if not exists reservations_schedule_idx on public.reservations(lab_id,starts_at,ends_at) where status<>'Cancelada';
create index if not exists reservations_server_idx on public.reservations(server_id,starts_at desc);

alter table public.reservations enable row level security;
drop policy if exists reservations_staff_read on public.reservations;
create policy reservations_staff_read on public.reservations for select to authenticated
using(public.current_role() in ('tecnico','supervisor'));

create or replace function public.next_reservation_protocol() returns text
language plpgsql security definer set search_path=public as $$
declare n bigint;
begin
  update public.reservation_counter set last_number=last_number+1 where singleton returning last_number into n;
  return 'RES-'||lpad(n::text,5,'0');
end $$;

create or replace function public.validate_reservation_slot(p_start timestamptz,p_end timestamptz)
returns void language plpgsql stable set search_path=public as $$
declare s timestamp:=p_start at time zone 'America/Cuiaba'; e timestamp:=p_end at time zone 'America/Cuiaba';
begin
  if extract(isodow from s) not between 1 and 6 or s::date<>e::date then raise exception 'Reservas são permitidas de segunda a sábado.'; end if;
  if extract(epoch from (p_end-p_start))::integer % 2700<>0 then raise exception 'A duração deve usar blocos de 45 minutos.'; end if;
  if not ((s::time>='07:00' and e::time<='12:35') or (s::time>='13:00' and e::time<='18:35') or (s::time>='18:45' and e::time<='22:50')) then
    raise exception 'Horário fora dos períodos de utilização dos laboratórios.';
  end if;
end $$;

create or replace function public.assert_reservation_available(p_lab uuid,p_start timestamptz,p_end timestamptz,p_ignore uuid default null)
returns void language plpgsql stable security definer set search_path=public as $$
begin
  perform public.validate_reservation_slot(p_start,p_end);
  if exists(select 1 from public.reservations where lab_id=p_lab and status<>'Cancelada' and id is distinct from p_ignore and starts_at<p_end and ends_at>p_start) then
    raise exception 'O laboratório já possui reserva neste horário.';
  end if;
end $$;

create or replace function public.reservation_payload(r public.reservations) returns jsonb
language sql stable security definer set search_path=public as $$
 select jsonb_build_object('protocol',r.protocol,'reservation_id',r.id,'server_name',s.full_name,'title',r.subject,'lab',l.name,
 'starts_at',r.starts_at,'ends_at',r.ends_at,'status',r.status,'reason',r.cancellation_reason,
 'portal_url','https://coeritl.github.io/labinfo/','confirmation_url','https://coeritl.github.io/labinfo/?confirm_reservation='||r.confirmation_token::text)
 from public.servers s join public.labs l on l.id=r.lab_id where s.id=r.server_id
$$;

alter table public.email_outbox add column if not exists reservation_id uuid references public.reservations(id) on delete cascade;
alter table public.email_outbox alter column ticket_id drop not null;
alter table public.email_outbox drop constraint if exists email_outbox_event_type_check;
alter table public.email_outbox add constraint email_outbox_event_type_check check(event_type in (
 'recebido','aberto_pelo_tecnico','em_atendimento','atualizacao','concluido','novo_chamado_tecnico','resposta_servidor_tecnico',
 'reserva_confirmar','reserva_confirmada','reserva_autorizada','reserva_cancelada','reserva_alterada'
));

create or replace function public.create_public_reservation(p_siape text,p_lab uuid,p_subject text,p_start timestamptz,p_blocks integer,p_notes text default null,p_recurrence text default 'none',p_until date default null)
returns table(id uuid,protocol text,status text) language plpgsql security definer set search_path=public as $$
declare s public.servers; r public.reservations; first_r public.reservations; finish timestamptz; occurrence timestamptz:=p_start; final_date date:=coalesce(p_until,(p_start at time zone 'America/Cuiaba')::date); group_id uuid:=gen_random_uuid(); count_items integer:=0;
begin
 select * into s from public.servers where siape=btrim(p_siape) and active limit 1;
 if s.id is null then raise exception 'Servidor não localizado ou inativo.'; end if;
 if p_blocks not between 1 and 8 then raise exception 'Selecione entre 1 e 8 blocos de aula.'; end if;
 if p_recurrence not in ('none','weekly') then raise exception 'Repetição inválida.';end if;
 if final_date<(p_start at time zone 'America/Cuiaba')::date or final_date>(p_start at time zone 'America/Cuiaba')::date+interval '180 days' then raise exception 'A data final deve estar dentro dos próximos 180 dias.';end if;
 loop
   if extract(isodow from occurrence at time zone 'America/Cuiaba') between 1 and 6 then
     finish:=occurrence+(p_blocks*interval '45 minutes');perform public.assert_reservation_available(p_lab,occurrence,finish,null);
     insert into public.reservations(protocol,server_id,lab_id,subject,notes,starts_at,ends_at,recurrence_group,recurrence)
     values(public.next_reservation_protocol(),s.id,p_lab,btrim(p_subject),nullif(btrim(p_notes),''),occurrence,finish,group_id,p_recurrence) returning * into r;
     if count_items=0 then first_r:=r;end if;count_items:=count_items+1;
   end if;
   exit when p_recurrence='none' or (occurrence at time zone 'America/Cuiaba')::date>=final_date;
   occurrence:=occurrence+interval '7 days';
   exit when (occurrence at time zone 'America/Cuiaba')::date>final_date;
 end loop;
 if count_items=0 then raise exception 'A série não possui nenhuma data válida.';end if;
 insert into public.email_outbox(reservation_id,recipient,event_type,payload) values(first_r.id,lower(s.email),'reserva_confirmar',public.reservation_payload(first_r)||jsonb_build_object('series_count',count_items,'series_until',final_date));
 return query select first_r.id,first_r.protocol,first_r.status;
end $$;

create or replace function public.confirm_reservation(p_token uuid)
returns table(protocol text,status text,confirmed_at timestamptz) language plpgsql security definer set search_path=public as $$
declare r public.reservations; s public.servers;
begin
 select * into r from public.reservations where confirmation_token=p_token order by starts_at limit 1;
 if r.id is null then raise exception 'Link inválido ou reserva indisponível.'; end if;
 update public.reservations set status='Aguardando autorização',confirmed_at=coalesce(reservations.confirmed_at,now()),updated_at=now()
 where recurrence_group=r.recurrence_group and public.reservations.status in ('Aguardando confirmação','Aguardando autorização');
 select * into r from public.reservations where id=r.id;
 select * into s from public.servers where id=r.server_id;
 if not exists(select 1 from public.email_outbox where reservation_id=r.id and event_type='reserva_confirmada') then
   insert into public.email_outbox(reservation_id,recipient,event_type,payload) values(r.id,lower(s.email),'reserva_confirmada',public.reservation_payload(r));
 end if;
 return query select r.protocol,r.status,r.confirmed_at;
end $$;

create or replace function public.my_reservations(p_siape text)
returns table(id uuid,protocol text,subject text,lab text,starts_at timestamptz,ends_at timestamptz,status text,confirmed_at timestamptz,reason text)
language sql stable security definer set search_path=public as $$
 select r.id,r.protocol,r.subject,l.name,r.starts_at,r.ends_at,r.status,r.confirmed_at,r.cancellation_reason
 from public.reservations r join public.servers s on s.id=r.server_id join public.labs l on l.id=r.lab_id
 where s.siape=btrim(p_siape) and s.active order by r.starts_at desc limit 100
$$;

create or replace function public.public_reservation_schedule(p_lab uuid,p_from date,p_to date)
returns table(id uuid,subject text,server_name text,starts_at timestamptz,ends_at timestamptz,status text)
language plpgsql stable security definer set search_path=public as $$
begin
 if p_to<p_from or p_to>p_from+42 then raise exception 'Período de consulta inválido.';end if;
 return query select r.id,
   case when r.status='Autorizada' then r.subject else 'Horário em análise' end,
   case when r.status='Autorizada' then s.full_name else null end,
   r.starts_at,r.ends_at,r.status
 from public.reservations r join public.servers s on s.id=r.server_id
 where r.lab_id=p_lab and r.status<>'Cancelada'
   and (r.starts_at at time zone 'America/Cuiaba')::date between p_from and p_to
 order by r.starts_at;
end $$;

create or replace function public.staff_create_reservation(p_server uuid,p_lab uuid,p_subject text,p_start timestamptz,p_blocks integer,p_notes text default null,p_source text default 'Equipe',p_recurrence text default 'none',p_until date default null)
returns public.reservations language plpgsql security definer set search_path=public as $$
declare r public.reservations; first_r public.reservations; finish timestamptz; occurrence timestamptz:=p_start; final_date date:=coalesce(p_until,(p_start at time zone 'America/Cuiaba')::date);group_id uuid:=gen_random_uuid();
begin
 if public.current_role() not in ('tecnico','supervisor') then raise exception 'Acesso negado.'; end if;
 if p_blocks not between 1 and 8 then raise exception 'Quantidade de blocos inválida.'; end if;
 if p_recurrence not in ('none','weekly') then raise exception 'Repetição inválida.';end if;
 if final_date<(p_start at time zone 'America/Cuiaba')::date or final_date>(p_start at time zone 'America/Cuiaba')::date+interval '180 days' then raise exception 'Período inválido.';end if;
 loop
  if extract(isodow from occurrence at time zone 'America/Cuiaba') between 1 and 6 then
   finish:=occurrence+(p_blocks*interval '45 minutes');perform public.assert_reservation_available(p_lab,occurrence,finish,null);
   insert into public.reservations(protocol,server_id,lab_id,subject,notes,starts_at,ends_at,status,source,confirmed_at,authorized_at,authorized_by,created_by,recurrence_group,recurrence)
   values(public.next_reservation_protocol(),p_server,p_lab,btrim(p_subject),nullif(btrim(p_notes),''),occurrence,finish,'Autorizada',case when p_source='CSV' then 'CSV' else 'Equipe' end,now(),now(),auth.uid(),auth.uid(),group_id,p_recurrence) returning * into r;
   if first_r.id is null then first_r:=r;end if;
  end if;
  exit when p_recurrence='none' or (occurrence at time zone 'America/Cuiaba')::date>=final_date;
  occurrence:=occurrence+interval '7 days';exit when (occurrence at time zone 'America/Cuiaba')::date>final_date;
 end loop;
 return first_r;
end $$;

create or replace function public.staff_update_reservation(p_id uuid,p_start timestamptz default null,p_lab uuid default null,p_status text default null,p_reason text default null)
returns public.reservations language plpgsql security definer set search_path=public as $$
declare old public.reservations; r public.reservations; new_start timestamptz; new_end timestamptz; new_lab uuid; recipient text; event text;
begin
 if public.current_role() not in ('tecnico','supervisor') then raise exception 'Acesso negado.'; end if;
 select * into old from public.reservations where id=p_id for update;if old.id is null then raise exception 'Reserva não encontrada.';end if;
 new_start:=coalesce(p_start,old.starts_at);new_end:=new_start+(old.ends_at-old.starts_at);new_lab:=coalesce(p_lab,old.lab_id);
 if p_status is null then
   perform public.assert_reservation_available(new_lab,new_start,new_end,old.id);
   update public.reservations set starts_at=new_start,ends_at=new_end,lab_id=new_lab,updated_at=now() where id=p_id;
 else
   update public.reservations set status=p_status,
   authorized_at=case when p_status='Autorizada' then now() else authorized_at end,authorized_by=case when p_status='Autorizada' then auth.uid() else authorized_by end,
   cancelled_at=case when p_status='Cancelada' then now() else cancelled_at end,cancellation_reason=case when p_status='Cancelada' then nullif(btrim(p_reason),'') else cancellation_reason end,updated_at=now()
   where recurrence_group=old.recurrence_group;
 end if;
 select * into r from public.reservations where id=p_id;
 event:=case when p_status='Autorizada' then 'reserva_autorizada' when p_status='Cancelada' then 'reserva_cancelada' when p_start is not null or p_lab is not null then 'reserva_alterada' end;
 if event is not null then select lower(email) into recipient from public.servers where id=r.server_id;insert into public.email_outbox(reservation_id,recipient,event_type,payload) values(r.id,recipient,event,public.reservation_payload(r));end if;
 return r;
end $$;

grant execute on function public.create_public_reservation(text,uuid,text,timestamptz,integer,text,text,date) to anon,authenticated;
grant execute on function public.confirm_reservation(uuid) to anon,authenticated;
grant execute on function public.my_reservations(text) to anon,authenticated;
grant execute on function public.public_reservation_schedule(uuid,date,date) to anon,authenticated;
grant execute on function public.staff_create_reservation(uuid,uuid,text,timestamptz,integer,text,text,text,date) to authenticated;
grant execute on function public.staff_update_reservation(uuid,timestamptz,uuid,text,text) to authenticated;

do $$ begin alter publication supabase_realtime add table public.reservations; exception when duplicate_object then null; end $$;
