-- Impede que séries cadastradas pela equipe sejam criadas parcialmente.
-- Todas as ocorrências são validadas antes da primeira inserção; se uma data
-- conflitar, a transação inteira é recusada com o diagnóstico da ocorrência.

create or replace function public.staff_create_reservation_range(
  p_server uuid, p_lab uuid, p_subject text, p_start timestamptz, p_end timestamptz,
  p_notes text default null, p_source text default 'Equipe',
  p_recurrence text default 'none', p_until date default null
)
returns public.reservations language plpgsql security definer set search_path=public as $$
declare
  r public.reservations;
  first_r public.reservations;
  occurrence timestamptz := p_start;
  finish timestamptz;
  requested_duration interval := p_end - p_start;
  final_date date := coalesce(p_until, (p_start at time zone 'America/Cuiaba')::date);
  group_id uuid := gen_random_uuid();
begin
  if public.current_role() not in ('tecnico', 'supervisor') then
    raise exception 'Acesso negado.';
  end if;

  perform public.cleanup_expired_reservations();
  perform public.validate_reservation_slot(p_start, p_end);

  if p_recurrence not in ('none', 'weekly') then
    raise exception 'Repetição inválida.';
  end if;
  if final_date < (p_start at time zone 'America/Cuiaba')::date
     or final_date > (p_start at time zone 'America/Cuiaba')::date + interval '180 days' then
    raise exception 'Período inválido.';
  end if;

  -- Primeira passagem: valida a série completa antes de gravar qualquer data.
  loop
    if extract(isodow from occurrence at time zone 'America/Cuiaba') between 1 and 6 then
      finish := occurrence + requested_duration;
      perform public.assert_reservation_available(p_lab, occurrence, finish, null);
    end if;

    exit when p_recurrence = 'none'
      or (occurrence at time zone 'America/Cuiaba')::date >= final_date;
    occurrence := occurrence + interval '7 days';
    exit when (occurrence at time zone 'America/Cuiaba')::date > final_date;
  end loop;

  -- Segunda passagem: somente ocorre se todas as datas estiverem livres.
  occurrence := p_start;
  loop
    if extract(isodow from occurrence at time zone 'America/Cuiaba') between 1 and 6 then
      finish := occurrence + requested_duration;
      insert into public.reservations(
        protocol, server_id, lab_id, subject, notes, starts_at, ends_at, status, source,
        confirmed_at, authorized_at, authorized_by, created_by, recurrence_group, recurrence
      ) values (
        public.next_reservation_protocol(), p_server, p_lab, btrim(p_subject),
        nullif(btrim(p_notes), ''), occurrence, finish, 'Autorizada',
        case when p_source = 'CSV' then 'CSV' else 'Equipe' end,
        now(), now(), auth.uid(), auth.uid(), group_id, p_recurrence
      ) returning * into r;

      if first_r.id is null then
        first_r := r;
      end if;
    end if;

    exit when p_recurrence = 'none'
      or (occurrence at time zone 'America/Cuiaba')::date >= final_date;
    occurrence := occurrence + interval '7 days';
    exit when (occurrence at time zone 'America/Cuiaba')::date > final_date;
  end loop;

  if first_r.id is null then
    raise exception 'A série não possui nenhuma data válida.';
  end if;

  return first_r;
exception
  when exclusion_violation then
    raise exception 'Conflito de horário detectado em %. Nenhuma reserva da série foi criada.',
      to_char(occurrence at time zone 'America/Cuiaba', 'DD/MM/YYYY');
end $$;

revoke all on function public.staff_create_reservation_range(
  uuid,uuid,text,timestamptz,timestamptz,text,text,text,date
) from public;
grant execute on function public.staff_create_reservation_range(
  uuid,uuid,text,timestamptz,timestamptz,text,text,text,date
) to authenticated;
