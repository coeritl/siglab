-- Permite reservas em qualquer horário do dia, inclusive atravessando os
-- antigos intervalos entre os períodos matutino, vespertino e noturno.
-- Mantém as validações de dia, duração, precisão e conflito de agenda.
create or replace function public.validate_reservation_slot(
  p_start timestamptz,
  p_end timestamptz
)
returns void
language plpgsql
stable
set search_path=public
as $$
declare
  s timestamp:=p_start at time zone 'America/Cuiaba';
  e timestamp:=p_end at time zone 'America/Cuiaba';
  duration_seconds integer:=extract(epoch from (p_end-p_start))::integer;
begin
  if extract(isodow from s) not between 1 and 6 or s::date<>e::date then
    raise exception 'Reservas são permitidas de segunda a sábado e devem começar e terminar na mesma data.';
  end if;
  if duration_seconds<2400 or duration_seconds>21600 then
    raise exception 'A reserva deve ter entre 40 minutos e 6 horas.';
  end if;
  if extract(minute from s)::integer%5<>0 or extract(minute from e)::integer%5<>0 then
    raise exception 'Informe início e fim em intervalos de 5 minutos.';
  end if;
end;
$$;
