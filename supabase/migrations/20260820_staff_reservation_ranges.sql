-- Permite que técnicos criem e editem reservas por horário inicial e final.
-- As funções antigas baseadas em blocos são preservadas para compatibilidade.
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
begin
  if public.current_role() not in ('tecnico','supervisor') then raise exception 'Acesso negado.'; end if;
  perform public.validate_reservation_slot(p_start,p_end);
  if p_recurrence not in ('none','weekly') then raise exception 'Repetição inválida.'; end if;
  if final_date<(p_start at time zone 'America/Cuiaba')::date
     or final_date>(p_start at time zone 'America/Cuiaba')::date+interval '180 days' then
    raise exception 'Período inválido.';
  end if;
  loop
    if extract(isodow from occurrence at time zone 'America/Cuiaba') between 1 and 6 then
      finish:=occurrence+requested_duration;
      perform public.assert_reservation_available(p_lab,occurrence,finish,null);
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
    exit when p_recurrence='none' or (occurrence at time zone 'America/Cuiaba')::date>=final_date;
    occurrence:=occurrence+interval '7 days';
    exit when (occurrence at time zone 'America/Cuiaba')::date>final_date;
  end loop;
  if first_r.id is null then raise exception 'A série não possui nenhuma data válida.'; end if;
  return first_r;
end $$;

create or replace function public.staff_edit_reservation_range(
  p_id uuid, p_server uuid, p_lab uuid, p_subject text,
  p_start timestamptz, p_end timestamptz,
  p_notes text default null, p_scope text default 'occurrence'
)
returns public.reservations language plpgsql security definer set search_path=public as $$
declare
  base public.reservations; item public.reservations; result public.reservations;
  target_start timestamptz; target_end timestamptz;
  requested_duration interval:=p_end-p_start; shift interval; recipient text;
begin
  if public.current_role() not in ('tecnico','supervisor') then raise exception 'Acesso negado.'; end if;
  if p_scope not in ('occurrence','series') then raise exception 'Escopo inválido.'; end if;
  if length(btrim(coalesce(p_subject,''))) not between 2 and 160 then raise exception 'Informe a disciplina ou atividade.'; end if;
  perform public.validate_reservation_slot(p_start,p_end);
  select * into base from public.reservations where id=p_id for update;
  if base.id is null then raise exception 'Reserva não encontrada.'; end if;
  shift:=p_start-base.starts_at;
  for item in
    select * from public.reservations
    where id=p_id or (p_scope='series' and recurrence_group=base.recurrence_group)
    order by starts_at for update
  loop
    target_start:=case when p_scope='series' then item.starts_at+shift else p_start end;
    target_end:=target_start+requested_duration;
    perform public.validate_reservation_slot(target_start,target_end);
    perform public.assert_reservation_available(p_lab,target_start,target_end,item.id);
    update public.reservations set
      server_id=p_server,lab_id=p_lab,subject=btrim(p_subject),
      notes=nullif(btrim(coalesce(p_notes,'')),''),starts_at=target_start,
      ends_at=target_end,updated_at=now()
    where id=item.id;
  end loop;
  select * into result from public.reservations where id=p_id;
  select lower(email) into recipient from public.servers where id=p_server and active;
  if recipient is not null then
    insert into public.email_outbox(reservation_id,recipient,event_type,payload)
    values(result.id,recipient,'reserva_alterada',public.reservation_payload(result));
  end if;
  return result;
end $$;

grant execute on function public.staff_create_reservation_range(uuid,uuid,text,timestamptz,timestamptz,text,text,text,date) to authenticated;
grant execute on function public.staff_edit_reservation_range(uuid,uuid,uuid,text,timestamptz,timestamptz,text,text) to authenticated;
