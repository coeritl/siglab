-- Evita ambiguidade entre a variavel local e profile_sectors.profile_id.
create or replace function public.get_my_staff_profile()
returns table(
  id uuid,siape text,full_name text,email text,role public.app_role,
  is_admin boolean,sectors jsonb
)
language plpgsql
stable
security definer
set search_path=public
as $$
declare v_profile_id uuid:=public.current_staff_profile_id();
begin
  if v_profile_id is null then
    raise exception 'Esta conta nao possui acesso a area interna do SIGLAB.';
  end if;
  return query
  select p.id,p.siape,p.full_name,p.email,p.role,public.is_siglab_admin(),
    coalesce(jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'slug',s.slug)
      order by s.sort_order,s.name) filter(where s.id is not null),'[]'::jsonb)
  from public.profiles p
  left join public.profile_sectors ps on ps.profile_id=p.id
  left join public.sectors s on s.id=ps.sector_id and s.active
  where p.id=v_profile_id and p.active
  group by p.id;
end $$;

revoke all on function public.get_my_staff_profile() from public,anon;
grant execute on function public.get_my_staff_profile() to authenticated;
