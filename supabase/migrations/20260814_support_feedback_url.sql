-- Mantém os links de acompanhamento na rota pública exclusiva de suporte.
create or replace function public.ticket_email_payload(t public.tickets)
returns jsonb language sql stable security definer set search_path=public as $$
  select jsonb_build_object(
    'protocol',t.protocol,'title',t.title,'description',t.description,'status',t.status,
    'server_name',coalesce(s.full_name,'Servidor'),'lab',coalesce(l.name,'Não informado'),
    'category',coalesce(c.name,'Não informada'),'created_at',t.created_at,
    'portal_url','https://coeritl.github.io/labinfo/suporte/',
    'feedback_url','https://coeritl.github.io/labinfo/suporte/?feedback='||t.feedback_token::text
  )
  from (select 1) x
  left join public.servers s on s.id=t.server_id
  left join public.labs l on l.id=t.lab_id
  left join public.categories c on c.id=t.category_id
$$;
