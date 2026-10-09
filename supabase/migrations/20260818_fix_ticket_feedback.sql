-- Correção e robustez na confirmação de atendimento pelo servidor (feedback via e-mail)
drop function if exists public.confirm_ticket_feedback(uuid);
drop function if exists public.confirm_ticket_feedback(text);

create or replace function public.confirm_ticket_feedback(p_token text)
returns table(protocol text, confirmed_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare
  v_uuid uuid;
  v_ticket public.tickets;
begin
  if p_token is null or btrim(p_token) = '' then
    raise exception 'Token de confirmação não fornecido.';
  end if;

  begin
    v_uuid := btrim(p_token)::uuid;
  exception when others then
    raise exception 'Link de confirmação inválido.';
  end;

  select * into v_ticket
  from public.tickets
  where feedback_token = v_uuid and deleted_at is null
  limit 1;

  if v_ticket.id is null then
    raise exception 'Chamado não localizado ou link expirado.';
  end if;

  update public.tickets
  set feedback_confirmed_at = coalesce(feedback_confirmed_at, now()),
      updated_at = now()
  where id = v_ticket.id;

  return query
  select v_ticket.protocol, coalesce(v_ticket.feedback_confirmed_at, now());
end $$;

grant execute on function public.confirm_ticket_feedback(text) to anon, authenticated;

-- Garante que o link gerado no e-mail de conclusão aponte corretamente para /labinfo/suporte/?feedback=
create or replace function public.ticket_email_payload(t public.tickets)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'protocol', t.protocol,
    'title', t.title,
    'description', t.description,
    'status', t.status,
    'resolution', coalesce(t.resolution, 'Atendimento concluído.'),
    'server_name', coalesce(s.full_name, 'Servidor'),
    'lab', coalesce(l.name, 'Não informado'),
    'category', coalesce(c.name, 'Não informada'),
    'created_at', t.created_at,
    'closed_at', t.closed_at,
    'portal_url', 'https://coeritl.github.io/labinfo/suporte/',
    'feedback_url', 'https://coeritl.github.io/labinfo/suporte/?feedback=' || t.feedback_token::text
  )
  from (select 1) x
  left join public.servers s on s.id = t.server_id
  left join public.labs l on l.id = t.lab_id
  left join public.categories c on c.id = t.category_id
$$;
