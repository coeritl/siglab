// Testa os helpers de escape usados antes de inserir texto vindo de
// chamados/reservas (título, descrição, nome, etc.) em innerHTML.
// Achado P0 corrigido em 26/08/2026 (XSS persistente) e achado P2 3.4 desta
// mesma auditoria (suíte de testes básica). Este teste lê o código-fonte real
// de app.js e supabase-integration.js (não uma reimplementação), para pegar
// uma futura edição que enfraqueça o escape.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const rootDir = join(dirname(fileURLToPath(import.meta.url)), '..');

function extractArrowFunction(sourceFile, constName) {
  const source = readFileSync(join(rootDir, sourceFile), 'utf8');
  // Ex.: "const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({...}[c]));"
  // A declaração ocupa a linha inteira; usamos isso em vez de parar no
  // primeiro ";" porque entidades como "&amp;" já contêm um ";" no meio do
  // valor, então "[^;]+;" corta a expressão pela metade.
  const lines = source.split('\n');
  const line = lines.find((candidate) => candidate.trim().startsWith(`const ${constName}=`) || candidate.trim().startsWith(`const ${constName} =`));
  assert.ok(line, `Não encontrei "const ${constName}=..." em ${sourceFile}. O helper de escape foi renomeado ou removido?`);
  const statement = line.trim();
  assert.ok(statement.endsWith(';'), `A declaração de ${constName} em ${sourceFile} não termina com ";" na mesma linha, ajuste o extrator do teste.`);
  // eslint-disable-next-line no-new-func
  const factory = new Function(`${statement}\nreturn ${constName};`);
  return factory();
}

const XSS_PAYLOADS = [
  '<script>alert(1)</script>',
  '"><img src=x onerror=alert(1)>',
  "'; alert(1); //",
  '<svg/onload=alert(1)>',
  'Título normal com acentuação e emoji 🎉',
];

for (const [file, constName] of [
  ['app.js', 'esc'],
  ['supabase-integration.js', 'safe'],
]) {
  test(`${file}: ${constName}() neutraliza caracteres perigosos de HTML`, () => {
    const fn = extractArrowFunction(file, constName);
    for (const payload of XSS_PAYLOADS) {
      const escaped = fn(payload);
      assert.ok(!escaped.includes('<'), `"<" não escapado em: ${escaped}`);
      assert.ok(!escaped.includes('>'), `">" não escapado em: ${escaped}`);
      assert.ok(!escaped.includes('"'), `'"' não escapado em: ${escaped}`);
      assert.ok(!escaped.includes("'"), `"'" não escapado em: ${escaped}`);
    }
  });

  test(`${file}: ${constName}() trata null/undefined como string vazia, sem lançar exceção`, () => {
    const fn = extractArrowFunction(file, constName);
    assert.equal(fn(null), '');
    assert.equal(fn(undefined), '');
  });

  test(`${file}: ${constName}() preserva texto legítimo sem caracteres especiais`, () => {
    const fn = extractArrowFunction(file, constName);
    assert.equal(fn('Projetor sem imagem'), 'Projetor sem imagem');
  });
}
