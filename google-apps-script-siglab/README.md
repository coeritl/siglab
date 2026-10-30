# Disparador exclusivo do SIGLAB

Não substituir o projeto Apps Script do LabInfo. Este pacote usa somente o banco
`keesciertyonbfqlrqwt`, envia notificações de reservas e não lê a caixa de entrada.
Não é necessário publicar como aplicativo web nem configurar outro cliente OAuth.

## Ativação

1. Entre em https://script.google.com/ com **siglab.tl@ifms.edu.br** e crie um
   projeto novo chamado **SIGLAB — E-mails de reservas**.
2. Cole este `Code.gs`. Nas configurações, habilite a exibição do manifesto e
   substitua `appsscript.json` pelo arquivo desta pasta.
3. Execute `prepararIntegracaoSiglab` e autorize as permissões. Copie o SQL
   exibido no registro de execução. Ele contém somente o hash do segredo;
   o segredo original fica nas propriedades privadas do novo projeto.
4. Execute esse SQL **somente no projeto Supabase do SIGLAB**. Requer que
   `integration_credentials`, `email_outbox`, `apps_script_pull_outbox` e
   `apps_script_finish_outbox` já existam. Se houver erro de objeto ausente,
   interrompa a ativação: não rode as migrações antigas do LabInfo em lote.
5. Execute `ativarDisparadorSiglab`. O gatilho roda a cada cinco minutos com
   a conta que o criou. A instalação não confirma por si só a entrega.
6. Faça uma reserva de teste com uma conta institucional cadastrada. Execute
   `enviarEmailsSiglab` e confira a execução, a caixa de entrada e a fila:

```sql
select id, event_type, status, attempts, sent_at, last_error
from public.email_outbox order by id desc limit 20;
```

O status `sent` confirma a aceitação pelo serviço de envio, não a entrega na
caixa de entrada. Verifique também Spam. Há uma janela pequena de duplicação
caso a execução seja interrompida entre o envio e a gravação do recibo local.
Os recibos locais só são removidos depois da confirmação do banco.

## Eventos

Reserva registrada/autorizada, alterada, cancelada e decisão sobre pedidos de
cancelamento. Nenhum e-mail exige clicar para confirmar uma nova reserva:
a identidade já foi validada pelo login Google. Alterações e cancelamentos
respeitam a opção de notificar registrada pelo backend. Eventos antigos de
confirmação por link e chamados não são enviados por este pacote.

Usa MailApp (sem acesso de leitura ao Gmail), consulta a cota antes de buscar
mensagens e limita cada execução a dez destinatários. Não configure um segundo
projeto para consumir a mesma fila. A rotação do segredo exige atualizar seu
hash no banco novamente; nunca publique o segredo em arquivos ou no GitHub.

Para pausar, exclua somente o gatilho `enviarEmailsSiglab` neste projeto.
Isso não altera o disparador do LabInfo e mantém as mensagens pendentes.
