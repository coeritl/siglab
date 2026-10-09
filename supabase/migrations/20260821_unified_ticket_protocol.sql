-- Unifica todos os novos chamados no formato LAB-XXXXX, independentemente do laboratório.
-- Os protocolos históricos permanecem inalterados e continuam válidos para consultas e respostas.
do $$
declare
  v_max bigint;
begin
  select coalesce(max((substring(protocol from '([0-9]+)$'))::bigint),0)
    into v_max
    from public.tickets
   where protocol ~ '^LAB[0-9]*-[0-9]+$';

  insert into public.protocol_sequences(prefix,last_value)
  values('LAB',v_max)
  on conflict(prefix) do update
    set last_value=greatest(public.protocol_sequences.last_value,excluded.last_value);
end $$;

create or replace function public.next_protocol(p_lab uuid)
returns text
language plpgsql
security definer
set search_path=public
as $$
declare
  v_next bigint;
begin
  insert into public.protocol_sequences(prefix,last_value)
  values('LAB',1)
  on conflict(prefix) do update
    set last_value=public.protocol_sequences.last_value+1
  returning last_value into v_next;

  return 'LAB-'||lpad(v_next::text,5,'0');
end $$;

revoke all on function public.next_protocol(uuid) from public;
grant execute on function public.next_protocol(uuid) to authenticated;
