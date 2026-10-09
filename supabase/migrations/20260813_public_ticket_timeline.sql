drop function if exists public.my_tickets(text);
create function public.my_tickets(p_siape text)
returns table(protocol text,title text,category text,lab text,status public.ticket_status,technician text,resolution text,created_at timestamptz,updated_at timestamptz,timeline jsonb)
language sql security definer set search_path=public as $$
 select t.protocol,t.title,c.name,l.name,t.status,
   case when t.status<>'Recebido' then coalesce(
     (select string_agg(p.full_name, ', ' order by p.full_name) from public.ticket_assignees ta join public.profiles p on p.id=ta.profile_id where ta.ticket_id=t.id),
     'Toda a equipe') end,
   t.resolution,t.created_at,t.updated_at,
   jsonb_build_array(jsonb_build_object('type','abertura','label','Chamado aberto','at',t.created_at))
   || coalesce((select jsonb_agg(jsonb_build_object(
       'type',u.kind,
       'label',case u.kind when 'status' then 'Atendimento iniciado' when 'atualizacao' then 'Atualização enviada pela equipe' when 'resposta_servidor' then 'Resposta recebida pela equipe' when 'fechamento' then 'Atendimento concluído' else 'Andamento registrado' end,
       'at',u.created_at) order by u.created_at)
     from public.ticket_updates u where u.ticket_id=t.id),'[]'::jsonb)
 from public.tickets t left join public.servers s on s.id=t.server_id
 left join public.categories c on c.id=t.category_id left join public.labs l on l.id=t.lab_id
 where coalesce(s.siape,t.guest_siape)=p_siape order by t.created_at desc limit 100
$$;
grant execute on function public.my_tickets(text) to anon,authenticated;
