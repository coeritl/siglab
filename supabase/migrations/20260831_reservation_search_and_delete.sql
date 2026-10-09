-- Busca tolerante a espaços e exclusão administrativa protegida de reservas.
create or replace function public.staff_delete_reservation(
  p_id uuid,
  p_scope text default 'occurrence'
)
returns integer
language plpgsql
security definer
set search_path=public
as $$
declare
  v_group uuid;
  v_deleted integer := 0;
begin
  if public.current_role() not in ('tecnico','supervisor') then
    raise exception 'Acesso negado.';
  end if;

  select r.recurrence_group into v_group
  from public.reservations r
  where r.id=p_id;

  if not found then return 0; end if;

  if lower(coalesce(p_scope,'occurrence'))='series' and v_group is not null then
    delete from public.reservations r where r.recurrence_group=v_group;
  else
    delete from public.reservations r where r.id=p_id;
  end if;

  get diagnostics v_deleted=row_count;
  return v_deleted;
end;
$$;

revoke all on function public.staff_delete_reservation(uuid,text) from public,anon;
grant execute on function public.staff_delete_reservation(uuid,text) to authenticated;

create or replace function public.staff_reservation_history_page(
  p_search text default null,p_offset integer default 0,p_limit integer default 20
)
returns table(
  id uuid,protocol text,recurrence_group uuid,server_id uuid,server_name text,
  lab_id uuid,lab_name text,subject text,notes text,starts_at timestamptz,
  ends_at timestamptz,last_at timestamptz,status text,source text,
  confirmed_at timestamptz,cancellation_reason text,occurrence_count bigint,total_count bigint
)
language plpgsql stable security definer set search_path=public as $$
begin
  if public.current_role() not in ('tecnico','supervisor') then raise exception 'Acesso negado.';end if;
  return query
  with grouped as (
    select
      (array_agg(r.id order by r.starts_at))[1] id,
      (array_agg(r.protocol order by r.starts_at))[1] protocol,
      r.recurrence_group,
      (array_agg(r.server_id order by r.starts_at))[1] server_id,
      (array_agg(s.full_name order by r.starts_at))[1] server_name,
      (array_agg(r.lab_id order by r.starts_at))[1] lab_id,
      (array_agg(l.name order by r.starts_at))[1] lab_name,
      (array_agg(r.subject order by r.starts_at))[1] subject,
      (array_agg(r.notes order by r.starts_at))[1] notes,
      min(r.starts_at) starts_at,
      (array_agg(r.ends_at order by r.starts_at))[1] ends_at,
      max(r.starts_at) last_at,
      (array_agg(r.status order by r.starts_at))[1] status,
      (array_agg(r.source order by r.starts_at))[1] source,
      (array_agg(r.confirmed_at order by r.starts_at))[1] confirmed_at,
      (array_agg(r.cancellation_reason order by r.starts_at))[1] cancellation_reason,
      count(*) occurrence_count,
      lower(string_agg(concat_ws(' ',r.protocol,r.subject,s.full_name,l.name,r.status),' ')) search_text
    from public.reservations r
    join public.servers s on s.id=r.server_id
    join public.labs l on l.id=r.lab_id
    where r.status not in ('Aguardando confirmação','Aguardando autorização')
    group by r.recurrence_group
  ),filtered as (
    select * from grouped
    where nullif(btrim(coalesce(p_search,'')),'') is null
       or regexp_replace(search_text,'[^[:alnum:]]','','g') like
          '%'||regexp_replace(lower(btrim(p_search)),'[^[:alnum:]]','','g')||'%'
  )
  select f.id,f.protocol,f.recurrence_group,f.server_id,f.server_name,
    f.lab_id,f.lab_name,f.subject,f.notes,f.starts_at,f.ends_at,f.last_at,
    f.status,f.source,f.confirmed_at,f.cancellation_reason,f.occurrence_count,
    count(*) over() total_count
  from filtered f order by f.starts_at desc
  offset greatest(coalesce(p_offset,0),0)
  limit least(greatest(coalesce(p_limit,20),1),50);
end $$;

grant execute on function public.staff_reservation_history_page(text,integer,integer) to authenticated;
