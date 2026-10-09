-- Respostas a notificações são incorporadas ao histórico do chamado correspondente.
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
  if v_protocol is not null then select * into v_existing from public.tickets where protocol=v_protocol and server_id=v_server.id and status<>'Concluído' limit 1; end if;
  if v_existing.id is not null then
    insert into public.ticket_updates(ticket_id,author_id,message,kind,visible_to_server) values(v_existing.id,null,left(btrim(p_body),2000),'resposta_servidor',true);
    update public.tickets set updated_at=now() where id=v_existing.id;
    insert into public.email_inbox_log values(p_message_id,lower(p_sender),left(p_subject,300),v_existing.id,'resposta_adicionada',now());
    return jsonb_build_object('accepted',true,'reply',true,'ticket_id',v_existing.id,'protocol',v_existing.protocol,'siape',v_server.siape);
  end if;
  select id into v_lab from public.labs where active and upper(p_subject) like '%'||upper(code)||'%' and code is not null order by length(code) desc limit 1;
  v_title:=btrim(regexp_replace(p_subject,'^\s*CHAMADO\s*:\s*','', 'i')); if v_title='' then v_title:='Chamado recebido por e-mail'; end if;
  v_protocol:=public.next_protocol(v_lab);
  insert into public.tickets(protocol,server_id,lab_id,title,description,source) values(v_protocol,v_server.id,v_lab,left(v_title,100),left(btrim(p_body),2000),'Email') returning id into v_ticket;
  insert into public.email_inbox_log values(p_message_id,lower(p_sender),left(p_subject,300),v_ticket,'criado',now());
  return jsonb_build_object('accepted',true,'reply',false,'ticket_id',v_ticket,'protocol',v_protocol,'siape',v_server.siape);
end $$;
