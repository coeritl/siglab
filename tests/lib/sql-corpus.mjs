// Utilitário compartilhado pelos testes de segurança em tests/sql-security-invariants.test.mjs.
// Lê schema.sql seguido de todos os arquivos de supabase/migrations/ em ordem
// alfabética pelo nome do arquivo — a mesma ordem em que supabase/README.md
// instrui a aplicá-los — e concatena tudo em um único texto, na ordem em que
// as instruções realmente seriam executadas em um banco novo.

import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const rootDir = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

export function loadSqlCorpus() {
  const schemaPath = join(rootDir, 'supabase', 'schema.sql');
  const migrationsDir = join(rootDir, 'supabase', 'migrations');
  const migrationFiles = readdirSync(migrationsDir)
    .filter((name) => name.endsWith('.sql'))
    .sort();

  const parts = [readFileSync(schemaPath, 'utf8')];
  for (const file of migrationFiles) {
    parts.push(readFileSync(join(migrationsDir, file), 'utf8'));
  }
  return parts.join('\n');
}

// Resolve, a partir de um corpo de SQL concatenado, qual conjunto de roles
// tem permissão de EXECUTE em uma função ao final de todas as instruções,
// simulando grant/revoke/drop na ordem em que aparecem no texto.
//
// Modelo simplificado do comportamento real do Postgres:
// - Uma função nova (primeira aparição, ou depois de "drop function") nasce
//   executável por PUBLIC por padrão (comportamento padrão do Postgres para
//   funções), até que algo revogue isso explicitamente.
// - "create or replace function" sobre uma função já rastreada NÃO reseta
//   os grants (só um "drop function" de fato os reseta).
// - "grant ... to X" adiciona X (ou os roles de X, se for uma lista) ao
//   conjunto; "revoke ... from X" remove.
// - PUBLIC concede a todo mundo, inclusive anon/authenticated, até ser
//   revogado especificamente.
export function resolveFunctionGrants(corpus, functionName) {
  const escaped = functionName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const granted = new Set();
  let seen = false;

  const statementPattern = new RegExp(
    `(drop\\s+function[^;]*\\b${escaped}\\s*\\([^;]*?\\)\\s*;)` +
    `|((?:create\\s+function|create\\s+or\\s+replace\\s+function)\\s+(?:public\\.)?\\b${escaped}\\s*\\()` +
    `|((?:grant|revoke)\\s+(?:all|execute)\\s+(?:on\\s+function\\s+)?(?:public\\.)?\\b${escaped}\\s*\\([^)]*\\)\\s*(?:from|to)\\s+([^;]+);)`,
    'gis'
  );

  let match;
  while ((match = statementPattern.exec(corpus)) !== null) {
    const [, isDrop, isCreate, grantOrRevoke, roleList] = match;
    if (isDrop) {
      granted.clear();
      seen = true;
    } else if (isCreate) {
      if (!seen) granted.add('PUBLIC');
      seen = true;
    } else if (grantOrRevoke) {
      const isRevoke = /^revoke/i.test(grantOrRevoke);
      const roles = roleList.split(',').map((r) => r.trim().toLowerCase()).filter(Boolean);
      for (const role of roles) {
        const normalized = role === 'public' ? 'PUBLIC' : role;
        if (isRevoke) granted.delete(normalized);
        else granted.add(normalized);
      }
    }
  }

  return {
    seen,
    grantedRoles: granted,
    canExecute(role) {
      return granted.has('PUBLIC') || granted.has(role.toLowerCase());
    },
  };
}

// Resolve o estado final (ativa ou não) de cada policy criada/derrubada no
// corpo de SQL concatenado, simulando "create policy" / "drop policy" na
// ordem em que aparecem.
export function resolvePolicies(corpus) {
  const policies = new Map(); // name -> { table, forClause, toRoles, usingClause, withCheckClause }

  const dropPattern = /drop\s+policy\s+(?:if\s+exists\s+)?"?([\w]+)"?\s+on\s+public\.(\w+)/gis;
  const createPattern = /create\s+policy\s+"?([\w]+)"?\s+on\s+public\.(\w+)\s*((?:for|to|using|with\s+check)[\s\S]*?);/gis;

  const events = [];
  let match;
  while ((match = dropPattern.exec(corpus)) !== null) {
    events.push({ index: match.index, type: 'drop', name: match[1], table: match[2] });
  }
  while ((match = createPattern.exec(corpus)) !== null) {
    const [, name, table, body] = match;
    const forMatch = /for\s+(select|insert|update|delete|all)/i.exec(body);
    const toMatch = /\bto\s+([\w,\s]+?)(?:\s+using|\s+with\s+check|$)/i.exec(body);
    const usingMatch = /using\s*\(([\s\S]*?)\)\s*(?:with\s+check|$)/i.exec(body);
    events.push({
      index: match.index,
      type: 'create',
      name,
      table,
      forClause: forMatch ? forMatch[1].toLowerCase() : 'all',
      toRoles: toMatch ? toMatch[1].split(',').map((r) => r.trim().toLowerCase()) : ['public'],
      usingClause: usingMatch ? usingMatch[1].trim() : null,
    });
  }

  events.sort((a, b) => a.index - b.index);
  for (const event of events) {
    if (event.type === 'drop') {
      policies.delete(event.name);
    } else {
      policies.set(event.name, event);
    }
  }

  return [...policies.values()];
}
