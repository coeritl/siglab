-- Permite editar ou cancelar reservas sem obrigar o envio de e-mail.
-- As funções existentes são preservadas para compatibilidade com outras telas.

create or replace function public.staff_edit_reservation_range_notification(
  p_id uuid, p_server uuid, p_lab uuid, p_subject text,
  p_start timestamptz, p_end timestamptz,
  p_notes text default null, p_scope text default 'occurrence',
  p_notify boolean default true
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
  if coalesce(p_notify,true) then
    select lower(email) into recipient from public.servers where id=p_server and active;
    if recipient is not null then
      insert into public.email_outbox(reservation_id,recipient,event_type,payload)
      values(result.id,recipient,'reserva_alterada',public.reservation_payload(result));
    end if;
  end if;
  return result;
end $$;

create or replace function public.staff_cancel_reservation_notification(
  p_id uuid, p_reason text, p_notify boolean default true
)
returns public.reservations language plpgsql security definer set search_path=public as $$
declare
  base public.reservations; result public.reservations; recipient text;
begin
  if public.current_role() not in ('tecnico','supervisor') then raise exception 'Acesso negado.'; end if;
  if length(btrim(coalesce(p_reason,'')))<3 then raise exception 'Informe o motivo do cancelamento.'; end if;
  select * into base from public.reservations where id=p_id for update;
  if base.id is null then raise exception 'Reserva não encontrada.'; end if;
  update public.reservations set
    status='Cancelada',cancelled_at=now(),cancellation_reason=btrim(p_reason),updated_at=now()
  where id=base.id or (base.recurrence_group is not null and recurrence_group=base.recurrence_group);
  select * into result from public.reservations where id=p_id;
  if coalesce(p_notify,true) then
    select lower(email) into recipient from public.servers where id=result.server_id and active;
    if recipient is not null then
      insert into public.email_outbox(reservation_id,recipient,event_type,payload)
      values(result.id,recipient,'reserva_cancelada',public.reservation_payload(result));
    end if;
  end if;
  return result;
end $$;

grant execute on function public.staff_edit_reservation_range_notification(uuid,uuid,uuid,text,timestamptz,timestamptz,text,text,boolean) to authenticated;
grant execute on function public.staff_cancel_reservation_notification(uuid,text,boolean) to authenticated;
