import { readdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const migrationDir = join(root, 'supabase', 'migrations');
const migrationOrderOverrides = new Map([
  // pending_servers cria guest_siape/guest_email; multiple_assignees já usa
  // essas colunas ao substituir my_tickets().
  ['20260812_pending_servers.sql', 1],
  ['20260812_multiple_assignees.sql', 2],
]);
const migrationNames = (await readdir(migrationDir))
  .filter((name) => name.endsWith('.sql'))
  .sort((a, b) => {
    const aPrefix = a.slice(0, 8);
    const bPrefix = b.slice(0, 8);
    if (aPrefix !== bPrefix) return a.localeCompare(b);
    const aOverride = migrationOrderOverrides.get(a) ?? 100;
    const bOverride = migrationOrderOverrides.get(b) ?? 100;
    return aOverride - bOverride || a.localeCompare(b);
  });

const sources = [
  ['schema.sql', await readFile(join(root, 'supabase', 'schema.sql'), 'utf8')],
  ...(await Promise.all(
    migrationNames.map(async (name) => [
      `migrations/${name}`,
      await readFile(join(migrationDir, name), 'utf8'),
    ]),
  )),
];

const prelude = `-- SIGLAB — instalação inicial consolidada\n-- Gerado automaticamente; execute somente em um projeto Supabase novo.\n-- Projeto esperado: keesciertyonbfqlrqwt\n\n`;
const body = sources
  .map(([name, source]) => `-- -----------------------------------------------------------------------------\n-- ${name}\n-- -----------------------------------------------------------------------------\n${source.trim()}\n`)
  .join('\n');

await writeFile(join(root, 'supabase', 'bootstrap.generated.sql'), prelude + body, 'utf8');
console.log(`Bootstrap gerado com ${sources.length} etapas.`);
