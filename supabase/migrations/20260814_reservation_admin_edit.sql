-- Edição administrativa de uma ocorrência ou de toda a série recorrente.
create or replace function public.staff_edit_reservation(
  p_id uuid,p_server uuid,p_lab uuid,p_subject text,p_start timestamptz,
  p_blocks integer,p_notes text default null,p_scope text default 'occurrence'
)
returns public.reservations language plpgsql security definer set search_path=public as $$
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
  select * into base from public.reservations where id=p_id for update;
  if base.id is null then raise exception 'Reserva não encontrada.'; end if;
  shift:=p_start-base.starts_at;

  for item in
    select * from public.reservations
    where id=p_id or (p_scope='series' and recurrence_group=base.recurrence_group)
    order by starts_at for update
  loop
    target_start:=case when p_scope='series' then item.starts_at+shift else p_start end;
    target_end:=target_start+(p_blocks*interval '45 minutes');
    perform public.assert_reservation_available(p_lab,target_start,target_end,item.id);
    update public.reservations set server_id=p_server,lab_id=p_lab,subject=btrim(p_subject),notes=nullif(btrim(coalesce(p_notes,'')),''),starts_at=target_start,ends_at=target_end,updated_at=now() where id=item.id;
  end loop;

  select * into result from public.reservations where id=p_id;
  select lower(email) into recipient from public.servers where id=p_server and active;
  if recipient is null then raise exception 'Servidor não encontrado ou inativo.'; end if;
  insert into public.email_outbox(reservation_id,recipient,event_type,payload)
  values(result.id,recipient,'reserva_alterada',public.reservation_payload(result));
  return result;
end $$;

grant execute on function public.staff_edit_reservation(uuid,uuid,uuid,text,timestamptz,integer,text,text) to authenticated;
