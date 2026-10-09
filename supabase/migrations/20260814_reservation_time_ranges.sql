-- Permite informar inicio e fim reais, incluindo intervalos entre blocos de aula.
create or replace function public.validate_reservation_slot(p_start timestamptz,p_end timestamptz)
returns void language plpgsql stable set search_path=public as $$
declare
  s timestamp:=p_start at time zone 'America/Cuiaba';
  e timestamp:=p_end at time zone 'America/Cuiaba';
  duration_seconds integer:=extract(epoch from (p_end-p_start))::integer;
begin
  if extract(isodow from s) not between 1 and 6 or s::date<>e::date then
    raise exception 'Reservas são permitidas de segunda a sábado.';
  end if;
  if duration_seconds<2700 or duration_seconds>21600 then
    raise exception 'A reserva deve ter entre 45 minutos e 6 horas.';
  end if;
  if extract(minute from s)::integer%5<>0 or extract(minute from e)::integer%5<>0 then
    raise exception 'Informe início e fim em intervalos de 5 minutos.';
  end if;
  if not ((s::time>='07:00' and e::time<='12:35') or (s::time>='13:00' and e::time<='18:35') or (s::time>='18:45' and e::time<='22:50')) then
    raise exception 'Horário fora dos períodos de utilização dos laboratórios.';
  end if;
end $$;

create or replace function public.create_public_reservation_range(
  p_siape text,p_lab uuid,p_subject text,p_start timestamptz,p_end timestamptz,
  p_notes text default null,p_recurrence text default 'none',p_until date default null
)
returns table(id uuid,protocol text,status text) language plpgsql security definer set search_path=public as $$
declare
  s public.servers; r public.reservations; first_r public.reservations;
  occurrence timestamptz:=p_start; finish timestamptz;
  requested_duration interval:=p_end-p_start;
  final_date date:=coalesce(p_until,(p_start at time zone 'America/Cuiaba')::date);
  group_id uuid:=gen_random_uuid(); count_items integer:=0;
begin
  select * into s from public.servers where siape=btrim(p_siape) and active limit 1;
  if s.id is null then raise exception 'Servidor não localizado ou inativo.'; end if;
  perform public.validate_reservation_slot(p_start,p_end);
  if p_recurrence not in ('none','weekly') then raise exception 'Repetição inválida.'; end if;
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
      if count_items=0 then first_r:=r; end if;
      count_items:=count_items+1;
    end if;
    exit when p_recurrence='none' or (occurrence at time zone 'America/Cuiaba')::date>=final_date;
    occurrence:=occurrence+interval '7 days';
    exit when (occurrence at time zone 'America/Cuiaba')::date>final_date;
  end loop;
  if count_items=0 then raise exception 'A série não possui nenhuma data válida.'; end if;
  insert into public.email_outbox(reservation_id,recipient,event_type,payload)
  values(first_r.id,lower(s.email),'reserva_confirmar',public.reservation_payload(first_r)||jsonb_build_object('series_count',count_items,'series_until',final_date));
  return query select first_r.id,first_r.protocol,first_r.status;
end $$;

grant execute on function public.create_public_reservation_range(text,uuid,text,timestamptz,timestamptz,text,text,date) to anon,authenticated;
