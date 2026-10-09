-- Atualização dos horários de funcionamento e cálculo de blocos oficiais do IFMS Campus Três Lagoas.
-- Matutino: 07:00-12:35 (Intervalo 09:15-09:35)
-- Vespertino: 13:00-18:35 (Intervalo 15:15-15:35)
-- Noturno: 18:50-22:50 (Intervalo 21:05-21:20)

create or replace function public.calculate_reservation_end(p_start timestamptz, p_blocks integer)
returns timestamptz language plpgsql stable set search_path = public as $$
declare
  v_local_start timestamp := p_start at time zone 'America/Cuiaba';
  v_time_str text := to_char(v_local_start, 'HH24:MI');
  v_slot_starts text[] := array[
    '07:00','07:45','08:30','09:35','10:20','11:05','11:50',
    '13:00','13:45','14:30','15:35','16:20','17:05','17:50',
    '18:50','19:35','20:20','21:20','22:05'
  ];
  v_slot_ends text[] := array[
    '07:45','08:30','09:15','10:20','11:05','11:50','12:35',
    '13:45','14:30','15:15','16:20','17:05','17:50','18:35',
    '19:35','20:20','21:05','22:05','22:50'
  ];
  v_idx integer;
  v_target_idx integer;
  v_end_time_str text;
  v_max_in_period integer;
begin
  if p_blocks is null or p_blocks < 1 then
    p_blocks := 1;
  end if;

  -- Localiza se o horário inicial corresponde a um dos 19 blocos padrão do IFMS
  for i in 1..array_length(v_slot_starts, 1) loop
    if v_slot_starts[i] = v_time_str then
      v_idx := i;
      exit;
    end if;
  end loop;

  if v_idx is not null then
    -- Determina o limite do período (matutino=7, vespertino=14, noturno=19)
    if v_idx <= 7 then
      v_max_in_period := 7;
    elsif v_idx <= 14 then
      v_max_in_period := 14;
    else
      v_max_in_period := 19;
    end if;

    v_target_idx := least(v_max_in_period, v_idx + p_blocks - 1);
    v_end_time_str := v_slot_ends[v_target_idx];

    return (v_local_start::date || ' ' || v_end_time_str || ':00')::timestamp at time zone 'America/Cuiaba';
  end if;

  -- Fallback para horários customizados fora da grade padrão
  return p_start + (p_blocks * interval '45 minutes');
end $$;

-- Atualiza validação de intervalos de funcionamento
create or replace function public.validate_reservation_slot(p_start timestamptz, p_end timestamptz)
returns void language plpgsql stable set search_path = public as $$
declare
  s timestamp := p_start at time zone 'America/Cuiaba';
  e timestamp := p_end at time zone 'America/Cuiaba';
  duration_seconds integer := extract(epoch from (p_end - p_start))::integer;
begin
  if extract(isodow from s) not between 1 and 6 or s::date <> e::date then
    raise exception 'Reservas são permitidas de segunda a sábado.';
  end if;
  if duration_seconds < 2400 or duration_seconds > 21600 then
    raise exception 'A reserva deve ter entre 40 minutos e 6 horas.';
  end if;
  if extract(minute from s)::integer % 5 <> 0 or extract(minute from e)::integer % 5 <> 0 then
    raise exception 'Informe início e fim em intervalos de 5 minutos.';
  end if;
  if not (
    (s::time >= '07:00' and e::time <= '12:35') or
    (s::time >= '13:00' and e::time <= '18:35') or
    (s::time >= '18:45' and e::time <= '22:50')
  ) then
    raise exception 'Horário fora dos períodos de funcionamento dos laboratórios.';
  end if;
end $$;

-- Atualiza criação de reserva pelo técnico para usar o cálculo oficial de blocos com intervalos
create or replace function public.staff_create_reservation(
  p_server uuid, p_lab uuid, p_subject text, p_start timestamptz, p_blocks integer,
  p_notes text default null, p_source text default 'Equipe', p_recurrence text default 'none', p_until date default null
)
returns public.reservations language plpgsql security definer set search_path = public as $$
declare
  r public.reservations; first_r public.reservations; finish timestamptz;
  occurrence timestamptz := p_start;
  final_date date := coalesce(p_until, (p_start at time zone 'America/Cuiaba')::date);
  group_id uuid := gen_random_uuid();
begin
  if public.current_role() not in ('tecnico','supervisor') then raise exception 'Acesso negado.'; end if;
  if p_blocks not between 1 and 8 then raise exception 'Quantidade de blocos inválida.'; end if;
  if p_recurrence not in ('none','weekly') then raise exception 'Repetição inválida.'; end if;
  if final_date < (p_start at time zone 'America/Cuiaba')::date or final_date > (p_start at time zone 'America/Cuiaba')::date + interval '180 days' then
    raise exception 'Período inválido.';
  end if;
  loop
    if extract(isodow from occurrence at time zone 'America/Cuiaba') between 1 and 6 then
      finish := public.calculate_reservation_end(occurrence, p_blocks);
      perform public.validate_reservation_slot(occurrence, finish);
      perform public.assert_reservation_available(p_lab, occurrence, finish, null);
      insert into public.reservations(
        protocol, server_id, lab_id, subject, notes, starts_at, ends_at, recurrence_group, recurrence, source
      )
      values(
        public.next_reservation_protocol(), p_server, p_lab, btrim(p_subject), nullif(btrim(p_notes),''), occurrence, finish, group_id, p_recurrence, p_source
      )
      returning * into r;
      if first_r.id is null then first_r := r; end if;
    end if;
    exit when p_recurrence = 'none' or (occurrence at time zone 'America/Cuiaba')::date >= final_date;
    occurrence := occurrence + interval '7 days';
    exit when (occurrence at time zone 'America/Cuiaba')::date > final_date;
  end loop;
  return first_r;
end $$;

-- Atualiza edição de reserva para usar o cálculo oficial de blocos com intervalos
create or replace function public.staff_edit_reservation(
  p_id uuid, p_server uuid, p_lab uuid, p_subject text, p_start timestamptz,
  p_blocks integer, p_notes text default null, p_scope text default 'occurrence'
)
returns public.reservations language plpgsql security definer set search_path = public as $$
declare
  base public.reservations;
  item public.reservations;
  result public.reservations;
  target_start timestamptz;
  target_end timestamptz;
  shift interval;
  recipient text;
begin
  if public.current_role() not in ('tecnico','supervisor') then raise exception 'Acesso negado.'; end if;
  if p_scope not in ('occurrence','series') then raise exception 'Escopo inválido.'; end if;
  if p_blocks not between 1 and 8 then raise exception 'Quantidade de blocos inválida.'; end if;
  if length(btrim(coalesce(p_subject,''))) not between 2 and 160 then raise exception 'Informe a disciplina ou atividade.'; end if;
  select * into base from public.reservations where id = p_id for update;
  if base.id is null then raise exception 'Reserva não encontrada.'; end if;
  shift := p_start - base.starts_at;

  for item in
    select * from public.reservations
    where id = p_id or (p_scope = 'series' and recurrence_group = base.recurrence_group)
    order by starts_at for update
  loop
    target_start := case when p_scope = 'series' then item.starts_at + shift else p_start end;
    target_end := public.calculate_reservation_end(target_start, p_blocks);
    perform public.validate_reservation_slot(target_start, target_end);
    perform public.assert_reservation_available(p_lab, target_start, target_end, item.id);
    update public.reservations
    set server_id = p_server,
        lab_id = p_lab,
        subject = btrim(p_subject),
        notes = nullif(btrim(coalesce(p_notes,'')), ''),
        starts_at = target_start,
        ends_at = target_end,
        updated_at = now()
    where id = item.id;
  end loop;

  select * into result from public.reservations where id = p_id;
  select lower(email) into recipient from public.servers where id = p_server and active;
  if recipient is not null then
    insert into public.email_outbox(reservation_id, recipient, event_type, payload)
    values(result.id, recipient, 'reserva_alterada', public.reservation_payload(result));
  end if;
  return result;
end $$;
