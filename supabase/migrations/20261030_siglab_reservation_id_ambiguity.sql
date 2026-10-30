-- SIGLAB exclusivamente: corrige conflito entre a saída id e servers.id.
-- Mantém autorização, validação de conflitos, série atômica e notificação.
begin;

create or replace function public.create_my_reservation_range(
  p_lab uuid,p_subject text,p_start timestamptz,p_end timestamptz,
  p_notes text default null,p_recurrence text default 'none',p_until date default null
)
returns table(id uuid,protocol text,status text,occurrence_count integer)
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  owner_id uuid:=public.current_ifms_server_id();
  owner_email text;
  first_r public.reservations;
  r public.reservations;
  occurrence timestamptz:=p_start;
  finish timestamptz;
  requested_duration interval:=p_end-p_start;
  final_date date:=coalesce(p_until,(p_start at time zone 'America/Cuiaba')::date);
  group_id uuid:=gen_random_uuid();
  item_count integer:=0;
begin
  perform public.cleanup_expired_reservations();
  if not exists(
    select 1 from public.labs l join public.sectors s on s.id=l.sector_id
    where l.id=p_lab and l.active and l.reservation_enabled
      and s.active and s.reservation_mode='internal'
  ) then raise exception 'Laboratorio indisponivel para reservas no SIGLAB.'; end if;
  if p_start<=now() then raise exception 'Nao e possivel reservar uma data ou horario passado.'; end if;
  if length(btrim(coalesce(p_subject,''))) not between 2 and 160 then
    raise exception 'Informe a disciplina ou atividade.';
  end if;
  if p_recurrence not in ('none','weekly') then raise exception 'Repeticao invalida.'; end if;
  if final_date<(p_start at time zone 'America/Cuiaba')::date
     or final_date>(p_start at time zone 'America/Cuiaba')::date+interval '180 days' then
    raise exception 'A data final deve estar dentro dos proximos 180 dias.';
  end if;
  perform public.validate_reservation_slot(p_start,p_end);

  -- Primeira passagem: uma serie nunca e parcialmente cadastrada.
  loop
    finish:=occurrence+requested_duration;
    perform public.assert_reservation_available(p_lab,occurrence,finish,null);
    exit when p_recurrence='none'
      or (occurrence at time zone 'America/Cuiaba')::date>=final_date;
    occurrence:=occurrence+interval '7 days';
    exit when (occurrence at time zone 'America/Cuiaba')::date>final_date;
  end loop;

  occurrence:=p_start;
  loop
    finish:=occurrence+requested_duration;
    insert into public.reservations(
      protocol,server_id,lab_id,subject,notes,starts_at,ends_at,status,source,
      confirmed_at,authorized_at,recurrence_group,recurrence
    ) values (
      public.next_reservation_protocol(),owner_id,p_lab,btrim(p_subject),
      nullif(btrim(coalesce(p_notes,'')),''),occurrence,finish,'Autorizada','Publico',
      now(),now(),group_id,p_recurrence
    ) returning * into r;
    item_count:=item_count+1;
    if first_r.id is null then first_r:=r; end if;
    exit when p_recurrence='none'
      or (occurrence at time zone 'America/Cuiaba')::date>=final_date;
    occurrence:=occurrence+interval '7 days';
    exit when (occurrence at time zone 'America/Cuiaba')::date>final_date;
  end loop;

  select lower(s.email) into owner_email from public.servers as s where s.id=owner_id;
  insert into public.email_outbox(reservation_id,recipient,event_type,payload)
  values(
    first_r.id,owner_email,'reserva_autorizada',
    public.reservation_payload(first_r)||jsonb_build_object('series_count',item_count,'series_until',final_date)
  );
  return query select first_r.id,first_r.protocol,'Autorizada'::text,item_count;
exception when exclusion_violation then
  raise exception 'Conflito em %. Nenhuma reserva da serie foi criada.',
    to_char(occurrence at time zone 'America/Cuiaba','DD/MM/YYYY');
end $$;

commit;
notify pgrst,'reload schema';

