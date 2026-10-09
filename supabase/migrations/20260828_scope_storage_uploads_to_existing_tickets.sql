-- Achado adicional (verificação ao vivo do painel do Supabase em 26/08/2026,
-- fora do escopo da auditoria estática original — políticas de Storage não
-- tinham sido inspecionadas antes):
--
-- A política `storage_public_upload` (definida em supabase/schema.sql) só
-- exigia que o caminho do arquivo começasse com "tickets/", sem checar se o
-- segundo segmento do caminho corresponde a um chamado (ticket) que
-- realmente existe:
--
--   with check(bucket_id='ticket-attachments' and (storage.foldername(name))[1]='tickets')
--
-- O bucket é privado (public=false) e já tem, na configuração do próprio
-- bucket, limite de 5 MB por arquivo e tipos MIME restritos a
-- image/jpeg, image/png e image/webp — isso já limitava bastante o dano
-- possível (não dá para subir executável, HTML, arquivo gigante, etc.).
-- Mas como a "anon key" é pública (fica embutida em supabase-config.js,
-- então qualquer visitante do site consegue vê-la), ainda era possível a
-- qualquer pessoa, sem nunca passar pelo formulário do site, enviar um
-- número ilimitado de imagens (até 5 MB cada) direto para a API de
-- Storage, para caminhos "tickets/<qualquer-string>/<nome>" arbitrários.
-- Esses arquivos nunca ficam vinculados à tabela `attachments` (isso só
-- acontece via `register_public_attachment`, que já valida SIAPE + chamado
-- + status), então nunca aparecem na interface — mas continuam ocupando a
-- cota de armazenamento do plano gratuito do Supabase, sem nenhum rate
-- limit, e só ficam visíveis para a equipe técnica se ela for olhar
-- diretamente dentro do bucket.
--
-- Esta migração fecha essa brecha exigindo que o segundo segmento do
-- caminho corresponda ao id de um chamado que já existe — exatamente o
-- formato que o próprio app já usa para montar o caminho
-- (`tickets/${ticketId}/${uuid}-${nomeSeguro}`, ver uploadFiles() em
-- supabase-integration.js). Como o id do chamado é um uuid gerado
-- aleatoriamente (não sequencial, não exposto na interface pública — o
-- app só mostra o número de protocolo, nunca o uuid, exceto para quem
-- acabou de criar o próprio chamado) e não é praticável de adivinhar, só
-- quem já tem um chamado real consegue montar um caminho aceito pela
-- política, o que elimina o vetor de abuso de cota descrito acima.
--
-- Não muda nada para o fluxo legítimo do site (uploadFiles() já usa
-- exatamente esse formato de caminho, com o id do chamado já criado antes
-- do upload).

drop policy if exists storage_public_upload on storage.objects;

create policy storage_public_upload on storage.objects for insert to anon,authenticated
with check(
  bucket_id = 'ticket-attachments'
  and (storage.foldername(name))[1] = 'tickets'
  and exists(
    select 1 from public.tickets t where t.id::text = (storage.foldername(name))[2]
  )
);
