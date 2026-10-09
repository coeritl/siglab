-- Estabilização para entrada em produção.
alter table public.tickets add column if not exists feedback_token uuid not null default gen_random_uuid();
alter table public.tickets add column if not exists feedback_confirmed_at timestamptz;
alter table public.tickets add column if not exists deleted_by_name text;
create unique index if not exists tickets_feedback_token_key on public.tickets(feedback_token);

create or replace function public.soft_delete_ticket(p_ticket uuid,p_reason text)
returns void language plpgsql security definer set search_path=public as $$
declare v_name text;
begin
  if public.current_role()<>'tecnico' then raise exception 'Sem permissão'; end if;
  if length(btrim(coalesce(p_reason,'')))<5 then raise exception 'Informe uma justificativa para a exclusão'; end if;
  select full_name into v_name from public.profiles where id=auth.uid();
  update public.tickets set deleted_at=now(),deleted_by=auth.uid(),deleted_by_name=v_name,
    deletion_reason=left(btrim(p_reason),500),updated_at=now()
  where id=p_ticket and deleted_at is null;
  if not found then raise exception 'Chamado não localizado ou já excluído'; end if;
end $$;

create or replace function public.confirm_ticket_feedback(p_token uuid)
returns table(protocol text,confirmed_at timestamptz)
language plpgsql security definer set search_path=public as $$
begin
  update public.tickets set feedback_confirmed_at=coalesce(feedback_confirmed_at,now()),updated_at=now()
  where feedback_token=p_token and status='Concluído' and deleted_at is null;
  if not found then raise exception 'Confirmação inválida ou chamado ainda não concluído'; end if;
  return query select t.protocol,t.feedback_confirmed_at from public.tickets t where t.feedback_token=p_token;
end $$;
grant execute on function public.confirm_ticket_feedback(uuid) to anon,authenticated;

create or replace function public.create_public_ticket(
  p_siape text,p_email text,p_lab uuid,p_category uuid,p_title text,p_description text
)
returns table(id uuid,protocol text) language plpgsql security definer set search_path=public as $$
declare v_server uuid; v_id uuid; v_protocol text; v_email text; v_identity text;
begin
  select s.id into v_server from public.servers s where s.siape=btrim(p_siape) and s.active;
  v_email:=lower(btrim(coalesce(p_email,'')));
  if v_server is null and v_email !~ '^[^[:space:]@]+@ifms[.]edu[.]br$' then raise exception 'Informe um e-mail institucional @ifms.edu.br'; end if;
  if btrim(p_siape) !~ '^[0-9]{5,12}$' then raise exception 'SIAPE inválido'; end if;
  if length(btrim(p_description))<5 then raise exception 'Descrição muito curta'; end if;
  v_identity:=coalesce(v_server::text,btrim(p_siape)||':'||v_email);
  if (select count(*) from public.tickets where coalesce(server_id::text,guest_siape||':'||guest_email)=v_identity and created_at>now()-interval '1 hour')>=10 then
    raise exception 'Limite temporário de solicitações atingido. Aguarde antes de tentar novamente';
  end if;
  if (select count(*) from public.tickets where coalesce(server_id::text,guest_siape||':'||guest_email)=v_identity and created_at>now()-interval '1 day')>=30 then
    raise exception 'Limite diário de solicitações atingido';
  end if;
  v_protocol:=public.next_protocol(p_lab);
  insert into public.tickets(protocol,server_id,guest_siape,guest_email,lab_id,category_id,title,description)
  values(v_protocol,v_server,case when v_server is null then btrim(p_siape) end,case when v_server is null then v_email end,
    p_lab,p_category,left(btrim(p_title),100),left(btrim(p_description),2000)) returning tickets.id into v_id;
  return query select v_id,v_protocol;
end $$;

create or replace function public.ticket_email_payload(t public.tickets)
returns jsonb language sql stable security definer set search_path=public as $$
  select jsonb_build_object(
    'protocol',t.protocol,'title',t.title,'description',t.description,'status',t.status,
    'server_name',coalesce(s.full_name,'Servidor'),'lab',coalesce(l.name,'Não informado'),
    'category',coalesce(c.name,'Não informada'),'created_at',t.created_at,
    'portal_url','https://coeritl.github.io/labinfo/',
    'feedback_url','https://coeritl.github.io/labinfo/?feedback='||t.feedback_token::text
  )
  from (select 1) x left join public.servers s on s.id=t.server_id
  left join public.labs l on l.id=t.lab_id left join public.categories c on c.id=t.category_id
$$;

alter table public.email_outbox drop constraint if exists email_outbox_event_type_check;
alter table public.email_outbox add constraint email_outbox_event_type_check check (
  event_type in ('recebido','aberto_pelo_tecnico','em_atendimento','atualizacao','concluido','novo_chamado_tecnico','resposta_servidor_tecnico')
);

create or replace function public.queue_staff_new_ticket_email() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  insert into public.email_outbox(ticket_id,recipient,event_type,payload)
  select new.id,lower(p.email),'novo_chamado_tecnico',public.ticket_email_payload(new)
  from public.profiles p where p.active and p.role='tecnico';
  return new;
end $$;
drop trigger if exists queue_staff_new_ticket_email on public.tickets;
create trigger queue_staff_new_ticket_email after insert on public.tickets
for each row execute function public.queue_staff_new_ticket_email();

create or replace function public.notify_server_reply() returns trigger
language plpgsql security definer set search_path=public as $$
declare v_ticket public.tickets;
begin
  if new.kind='resposta_servidor' then
    update public.tickets set server_reply_pending=true,last_server_reply_at=now(),updated_at=now(),
      status=case when status='Concluído' then 'Em atendimento'::public.ticket_status else status end,
      closed_at=case when status='Concluído' then null else closed_at end,
      resolution=case when status='Concluído' then null else resolution end
    where id=new.ticket_id returning * into v_ticket;
    insert into public.email_outbox(ticket_id,recipient,event_type,payload)
    select v_ticket.id,lower(p.email),'resposta_servidor_tecnico',
      public.ticket_email_payload(v_ticket)||jsonb_build_object('message',new.message)
    from public.profiles p where p.active and p.role='tecnico';
  end if;
  return new;
end $$;

create or replace function public.apps_script_register_inbound(
  p_secret text,p_message_id text,p_sender text,p_subject text,p_body text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_server public.servers; v_lab uuid; v_title text; v_protocol text; v_ticket uuid; v_existing public.tickets;
begin
  if not public.integration_secret_valid(p_secret) then raise exception 'Credencial inválida'; end if;
  if exists(select 1 from public.email_inbox_log where gmail_message_id=p_message_id) then return jsonb_build_object('duplicate',true); end if;
  select * into v_server from public.servers where lower(email)=lower(btrim(p_sender)) and active limit 1;
  if v_server.id is null then
    insert into public.email_inbox_log values(p_message_id,lower(p_sender),left(p_subject,300),null,'remetente_nao_cadastrado',now());
    return jsonb_build_object('accepted',false,'reason','remetente_nao_cadastrado');
  end if;
  v_protocol:=(regexp_match(upper(p_subject),'(LAB[0-9]*-[0-9]+)'))[1];
  if v_protocol is not null then select * into v_existing from public.tickets where protocol=v_protocol and server_id=v_server.id and deleted_at is null limit 1; end if;
  if v_existing.id is not null then
    insert into public.ticket_updates(ticket_id,author_id,message,kind,visible_to_server)
    values(v_existing.id,null,left(btrim(p_body),2000),'resposta_servidor',true);
    insert into public.email_inbox_log values(p_message_id,lower(p_sender),left(p_subject,300),v_existing.id,'resposta_adicionada',now());
    return jsonb_build_object('accepted',true,'reply',true,'ticket_id',v_existing.id,'protocol',v_existing.protocol,'siape',v_server.siape);
  end if;
  select id into v_lab from public.labs where active and upper(p_subject) like '%'||upper(code)||'%' and code is not null order by length(code) desc limit 1;
  v_title:=btrim(regexp_replace(p_subject,'^\s*CHAMADO\s*:\s*','', 'i')); if v_title='' then v_title:='Chamado recebido por e-mail'; end if;
  v_protocol:=public.next_protocol(v_lab);
  insert into public.tickets(protocol,server_id,lab_id,title,description,source)
  values(v_protocol,v_server.id,v_lab,left(v_title,100),left(btrim(p_body),2000),'Email') returning id into v_ticket;
  insert into public.email_inbox_log values(p_message_id,lower(p_sender),left(p_subject,300),v_ticket,'criado',now());
  return jsonb_build_object('accepted',true,'reply',false,'ticket_id',v_ticket,'protocol',v_protocol,'siape',v_server.siape);
end $$;

drop function if exists public.my_tickets(text);
create function public.my_tickets(p_siape text)
returns table(protocol text,title text,category text,lab text,status public.ticket_status,technician text,resolution text,created_at timestamptz,updated_at timestamptz,timeline jsonb)
language sql security definer set search_path=public as $$
 select t.protocol,t.title,c.name,l.name,t.status,
   case when t.status<>'Recebido' then coalesce((select string_agg(p.full_name, ', ' order by p.full_name) from public.ticket_assignees ta join public.profiles p on p.id=ta.profile_id where ta.ticket_id=t.id),'Toda a equipe') end,
   t.resolution,t.created_at,t.updated_at,
   jsonb_build_array(jsonb_build_object('type','abertura','label','Solicitação registrada','at',t.created_at))
   || coalesce((select jsonb_agg(jsonb_build_object('type',u.kind,'label',case u.kind when 'status' then 'Atendimento iniciado' when 'atualizacao' then 'Atualização enviada pela equipe' when 'resposta_servidor' then 'Resposta recebida pela equipe' when 'fechamento' then 'Atendimento concluído' else 'Andamento registrado' end,'at',u.created_at) order by u.created_at) from public.ticket_updates u where u.ticket_id=t.id),'[]'::jsonb)
   || case when t.feedback_confirmed_at is not null then jsonb_build_array(jsonb_build_object('type','feedback','label','Atendimento confirmado pelo servidor','at',t.feedback_confirmed_at)) else '[]'::jsonb end
 from public.tickets t left join public.servers s on s.id=t.server_id
 left join public.categories c on c.id=t.category_id left join public.labs l on l.id=t.lab_id
 where coalesce(s.siape,t.guest_siape)=p_siape and t.deleted_at is null order by t.created_at desc limit 100
$$;
grant execute on function public.my_tickets(text) to anon,authenticated;
