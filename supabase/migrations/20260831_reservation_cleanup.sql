-- Limpeza oportunista de reservas expiradas
-- Evita que reservas públicas que nunca foram confirmadas por e-mail fiquem bloqueando horários para sempre.

create or replace function public.cleanup_expired_reservations()
returns void language plpgsql security definer set search_path=public as $$
begin
  -- Altera o status para 'Cancelada' das reservas que expiraram e ainda não foram confirmadas
  update public.reservations
     set status = 'Cancelada',
         cancelled_at = now(),
         cancellation_reason = 'Expirou o prazo de 72h para confirmação por e-mail.',
         updated_at = now()
   where status = 'Aguardando confirmação'
     and confirmation_expires_at < now();
end $$;

-- Atualizamos as funções de criação para chamarem a limpeza antes de tentarem criar/validar
create or replace function public.staff_create_reservation_range(
  p_server uuid, p_lab uuid, p_subject text, p_start timestamptz, p_end timestamptz,
  p_notes text default null, p_source text default 'Equipe',
  p_recurrence text default 'none', p_until date default null
)
returns public.reservations language plpgsql security definer set search_path=public as $$
declare
  r public.reservations; first_r public.reservations;
  occurrence timestamptz:=p_start; finish timestamptz;
  requested_duration interval:=p_end-p_start;
  final_date date:=coalesce(p_until,(p_start at time zone 'America/Cuiaba')::date);
  group_id uuid:=gen_random_uuid();
  conflict_info text;
  skipped_dates text[];
begin
  if public.current_role() not in ('tecnico','supervisor') then raise exception 'Acesso negado.'; end if;
  
  -- Limpa as expiradas ANTES de verificar conflitos
  perform public.cleanup_expired_reservations();

  perform public.validate_reservation_slot(p_start,p_end);
  if p_recurrence not in ('none','weekly') then raise exception 'Repetição inválida.'; end if;
  if final_date<(p_start at time zone 'America/Cuiaba')::date
     or final_date>(p_start at time zone 'America/Cuiaba')::date+interval '180 days' then
    raise exception 'Período inválido.';
  end if;
  loop
    if extract(isodow from occurrence at time zone 'America/Cuiaba') between 1 and 6 then
      finish:=occurrence+requested_duration;
      select res.subject || ' (' || s.full_name || ', ' || res.status || ')'
        into conflict_info
        from public.reservations res
        join public.servers s on s.id = res.server_id
       where res.lab_id=p_lab and res.status<>'Cancelada'
         and res.starts_at<finish and res.ends_at>occurrence
       limit 1;
      if conflict_info is not null then
        skipped_dates := array_append(skipped_dates,
          to_char(occurrence at time zone 'America/Cuiaba', 'DD/MM') || ': ' || conflict_info);
        conflict_info := null;
      else
        perform public.validate_reservation_slot(occurrence, finish);
        insert into public.reservations(
          protocol,server_id,lab_id,subject,notes,starts_at,ends_at,status,source,
          confirmed_at,authorized_at,authorized_by,created_by,recurrence_group,recurrence
        ) values (
          public.next_reservation_protocol(),p_server,p_lab,btrim(p_subject),nullif(btrim(p_notes),''),
          occurrence,finish,'Autorizada',case when p_source='CSV' then 'CSV' else 'Equipe' end,
          now(),now(),auth.uid(),auth.uid(),group_id,p_recurrence
        ) returning * into r;
        if first_r.id is null then first_r:=r; end if;
      end if;
    end if;
    exit when p_recurrence='none' or (occurrence at time zone 'America/Cuiaba')::date>=final_date;
    occurrence:=occurrence+interval '7 days';
    exit when (occurrence at time zone 'America/Cuiaba')::date>final_date;
  end loop;
  if first_r.id is null then
    if skipped_dates is not null and array_length(skipped_dates, 1) > 0 then
      raise exception 'Todas as datas possuem conflito: %. Nenhuma reserva foi criada.',
        array_to_string(skipped_dates, ' | ');
    else
      raise exception 'A série não possui nenhuma data válida.';
    end if;
  end if;
  return first_r;
end $$;

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
  
  -- Limpa as expiradas ANTES de verificar conflitos
  perform public.cleanup_expired_reservations();

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
  raise exception 'Conflito de horário detectado em %. O laboratório já possui reserva neste horário.',
    to_char(occurrence at time zone 'America/Cuiaba', 'DD/MM/YYYY');
end $$;

-- Grants
revoke all on function public.create_public_reservation_range(text,uuid,text,timestamptz,timestamptz,text,text,date) from public;
grant execute on function public.staff_create_reservation_range(uuid,uuid,text,timestamptz,timestamptz,text,text,text,date) to authenticated;
grant execute on function public.create_public_reservation_range(text,uuid,text,timestamptz,timestamptz,text,text,date) to anon,authenticated;
