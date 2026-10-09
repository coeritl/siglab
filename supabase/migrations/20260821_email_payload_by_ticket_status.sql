-- Dados de conclusão só devem existir no payload quando o chamado estiver concluído.
create or replace function public.ticket_email_payload(t public.tickets)
returns jsonb
language sql
stable
security definer
set search_path=public
as $$
  select jsonb_build_object(
    'protocol',t.protocol,
    'title',t.title,
    'description',t.description,
    'status',t.status,
    'resolution',case when t.status='Concluído' then coalesce(t.resolution,'Atendimento concluído.') else null end,
    'server_name',coalesce(s.full_name,t.guest_email,'Remetente por e-mail'),
    'lab',coalesce(l.name,'Não informado'),
    'category',coalesce(c.name,'Não informada'),
    'created_at',t.created_at,
    'closed_at',t.closed_at,
    'portal_url','https://labinfo.tl.ifms.edu.br/suporte/',
    'feedback_url',case when t.status='Concluído' then 'https://labinfo.tl.ifms.edu.br/suporte/?feedback='||t.feedback_token::text else null end
  )
  from (select 1) x
  left join public.servers s on s.id=t.server_id
  left join public.labs l on l.id=t.lab_id
  left join public.categories c on c.id=t.category_id
$$;
