# SIGLAB — Sistema Integrado de Gestão de Laboratórios

Portal independente para consulta e gestão das reservas de laboratórios do IFMS Campus Três Lagoas.

## Endereços

- homologação no GitHub Pages: `https://coeritl.github.io/siglab/`
- domínio planejado: `https://laboratorios.tl.ifms.edu.br/`

O domínio personalizado ainda não está ativado.

## Estado atual

A interface pública e a área interna já foram separadas do sistema LabInfo. O site publicado carrega apenas:

- página inicial e identidade SIGLAB;
- seleção pública de laboratórios;
- calendário semanal de ocupação;
- solicitação de reserva e recorrência semanal;
- consulta segura e solicitação de cancelamento;
- painel interno de reservas;
- importação de grade por CSV;
- cadastros básicos de laboratórios e servidores.

Os scripts de chamados e chat não são carregados pela aplicação.

## Banco de dados

O `supabase-config.js` permanece deliberadamente vazio. Nunca reutilize neste repositório a URL, a chave pública ou os segredos do LabInfo em produção.

A próxima etapa é criar um projeto Supabase exclusivo do SIGLAB e consolidar somente as tabelas, políticas e funções relacionadas a:

- `profiles`;
- `servers`;
- `labs`;
- `reservations`;
- `reservation_cancellation_requests`;
- `system_settings`;
- fila de notificações de reserva.

Enquanto o banco exclusivo não for configurado, o Pages funciona em modo de demonstração e exibe espaços ilustrativos sem permitir gravações.

## Desenvolvimento

```bash
npm install
npm test
```

Arquivos ativos da aplicação:

- `index.html`
- `siglab-app.js`
- `reservations.js`
- `styles.css`
- `siglab.css`
- `supabase-config.js`

## Isolamento

O SIGLAB possui repositório, publicação e futuro banco próprios. Alterações neste projeto não devem ser publicadas no repositório `coeritl/labinfo`.
