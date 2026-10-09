// Testes estáticos de segurança sobre o schema/migrations do Supabase.
// Não há banco de dados disponível para testes de integração reais (nenhuma
// credencial é mantida neste repositório), então estes testes simulam, a
// partir do texto das migrations, o estado final de RLS/grants — o
// suficiente para funcionar como um "regression test" dos 3 achados
// críticos corrigidos em 26/08/2026 e do rate limiting adicionado no achado
// P1 2.1. Ver tests/lib/sql-corpus.mjs para o simulador.
//
// Isto é um complemento, não um substituto: sempre confira o comportamento
// real após aplicar as migrations em um projeto Supabase de homologação.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { loadSqlCorpus, resolveFunctionGrants, resolvePolicies } from './lib/sql-corpus.mjs';

const corpus = loadSqlCorpus();

test('create_ticket_from_chat NÃO é executável por anon (achado P0.2)', () => {
  const grants = resolveFunctionGrants(corpus, 'create_ticket_from_chat');
  assert.ok(grants.seen, 'A função create_ticket_from_chat não foi encontrada nas migrations.');
  assert.equal(
    grants.canExecute('anon'), false,
    'create_ticket_from_chat está acessível para o role anon — isto reabriria o achado crítico P0.2 ' +
    '(qualquer visitante poderia gerar chamados oficiais em nome da equipe técnica).'
  );
  assert.equal(grants.canExecute('authenticated'), true, 'Técnicos autenticados devem continuar podendo chamar create_ticket_from_chat.');
});

test('create_ticket_from_chat exige técnico/supervisor autenticado no corpo da função', () => {
  // Pega a ÚLTIMA definição da função no corpus (create or replace mais recente).
  const matches = [...corpus.matchAll(/create or replace function public\.create_ticket_from_chat\([\s\S]*?\nend \$\$;/gi)];
  assert.ok(matches.length > 0, 'Nenhuma definição de create_ticket_from_chat encontrada.');
  const latest = matches[matches.length - 1][0];
  assert.match(
    latest, /current_role\(\)\s*not in\s*\('tecnico','supervisor'\)|current_role\(\)\s*not in\s*\('supervisor','tecnico'\)/i,
    'A definição mais recente de create_ticket_from_chat não contém a checagem de role técnico/supervisor.'
  );
  assert.match(latest, /raise exception/i, 'A definição mais recente de create_ticket_from_chat não interrompe a execução para chamadores não autorizados.');
});

test('RPCs públicas esperadas continuam acessíveis por anon', () => {
  // Funções que o site público (visitante não autenticado) precisa poder
  // chamar. Se um destes falhar, o site quebra para o público mesmo que a
  // função exista — normalmente sinal de um "revoke" sem o "grant" correspondente.
  const publicFunctions = [
    'create_public_ticket',
    'identify_server',
    'request_chat_session',
    'send_chat_message',
    'get_public_chat_messages',
    'create_public_reservation_range',
    'confirm_ticket_feedback',
    'my_tickets',
  ];
  for (const fn of publicFunctions) {
    const grants = resolveFunctionGrants(corpus, fn);
    assert.ok(grants.seen, `Função pública esperada não encontrada: ${fn}`);
    assert.equal(grants.canExecute('anon'), true, `A função pública ${fn} não está (mais) acessível para o role anon.`);
  }
});

test('enforce_rate_limit não é chamável diretamente por anon/authenticated (achado P1 2.1)', () => {
  const grants = resolveFunctionGrants(corpus, 'enforce_rate_limit');
  assert.ok(grants.seen, 'enforce_rate_limit não encontrada — migration de rate limiting ausente?');
  assert.equal(grants.canExecute('anon'), false, 'enforce_rate_limit não deveria ser chamável diretamente pelo público.');
  assert.equal(grants.canExecute('authenticated'), false, 'enforce_rate_limit não deveria ser chamável diretamente por usuários autenticados comuns.');
});

test('nenhuma policy pública de leitura/escrita irrestrita ("using (true)" para anon/public) sobrevive em chat_sessions/chat_messages (achado P0.1)', () => {
  const policies = resolvePolicies(corpus);
  const openPolicies = policies.filter((policy) =>
    ['chat_sessions', 'chat_messages'].includes(policy.table) &&
    policy.usingClause !== null &&
    /^\s*true\s*$/i.test(policy.usingClause) &&
    (policy.toRoles.includes('public') || policy.toRoles.includes('anon'))
  );
  assert.deepEqual(
    openPolicies.map((policy) => policy.name), [],
    'Existe(m) policy(ies) com using(true) aberta(s) para o público em chat_sessions/chat_messages — isto reabriria o achado crítico P0.1.'
  );
});

test('upload público em ticket-attachments exige um chamado existente (achado adicional, verificação ao vivo em 26/08/2026)', () => {
  // A policy original só checava bucket_id + prefixo "tickets/" — qualquer
  // pessoa com a anon key pública conseguia subir imagens para caminhos
  // arbitrários, sem nenhum chamado real por trás, consumindo a cota de
  // armazenamento do plano gratuito sem rate limit. Pega a ÚLTIMA
  // "create policy storage_public_upload" do corpus (a mais recente vence,
  // já que a migration faz "drop policy if exists" antes de recriar).
  const matches = [...corpus.matchAll(/create policy storage_public_upload on storage\.objects[\s\S]*?;/gi)];
  assert.ok(matches.length > 0, 'Nenhuma definição de storage_public_upload encontrada.');
  const latest = matches[matches.length - 1][0];
  assert.match(
    latest, /exists\s*\(\s*select[\s\S]*?public\.tickets[\s\S]*?\(storage\.foldername\(name\)\)\[2\]/i,
    'A policy storage_public_upload mais recente não exige mais que o segundo segmento do caminho corresponda a um chamado existente — ' +
    'isto reabriria o vetor de abuso de cota de armazenamento (uploads não vinculados a nenhum chamado real).'
  );
});

test('policies de leitura restantes em chat_sessions/chat_messages exigem authenticated + role técnico/supervisor', () => {
  const policies = resolvePolicies(corpus);
  const readPolicies = policies.filter((policy) =>
    ['chat_sessions', 'chat_messages'].includes(policy.table) &&
    ['select', 'all'].includes(policy.forClause)
  );
  assert.ok(readPolicies.length > 0, 'Nenhuma policy de leitura restou em chat_sessions/chat_messages — tabela ficaria inacessível até para a equipe.');
  for (const policy of readPolicies) {
    assert.ok(
      policy.toRoles.includes('authenticated') && !policy.toRoles.includes('public') && !policy.toRoles.includes('anon'),
      `Policy ${policy.name} (${policy.table}) deveria valer apenas para "authenticated", não para public/anon.`
    );
  }
});
