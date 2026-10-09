create or replace function public.public_reservation_schedule(p_lab uuid,p_from date,p_to date)
returns table(id uuid,subject text,server_name text,starts_at timestamptz,ends_at timestamptz,status text)
language plpgsql stable security definer set search_path=public as $$
begin
  if p_to<p_from or p_to>p_from+42 then raise exception 'Período de consulta inválido.'; end if;
  return query
  select r.id,
    case when r.status='Autorizada' then r.subject else 'Horário em análise' end,
    case when r.status='Autorizada' then s.full_name else null end,
    r.starts_at,r.ends_at,r.status
  from public.reservations r
  join public.servers s on s.id=r.server_id
  where r.lab_id=p_lab
    and r.status<>'Cancelada'
    and (r.starts_at at time zone 'America/Cuiaba')::date between p_from and p_to
  order by r.starts_at;
end $$;

grant execute on function public.public_reservation_schedule(uuid,date,date) to anon,authenticated;
