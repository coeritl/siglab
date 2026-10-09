-- A duração real pode incluir intervalos entre aulas; a validação ocorre em
-- validate_reservation_slot, com mínimo de 45 minutos e máximo de 6 horas.
do $$
declare constraint_name text;
begin
  for constraint_name in
    select con.conname
    from pg_constraint con
    join pg_class rel on rel.oid=con.conrelid
    join pg_namespace ns on ns.oid=rel.relnamespace
    where ns.nspname='public'
      and rel.relname='reservations'
      and con.contype='c'
      and pg_get_constraintdef(con.oid) like '%2700%'
  loop
    execute format('alter table public.reservations drop constraint %I',constraint_name);
  end loop;
end $$;
