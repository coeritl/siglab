import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const read = file => readFile(new URL(`../${file}`, import.meta.url), 'utf8');

test('a página publicada carrega apenas a aplicação SIGLAB e o módulo de reservas', async () => {
  const html = await read('index.html');
  assert.match(html, /src="siglab-app\.js(?:\?v=[^"]+)?"/);
  assert.match(html, /src="reservations\.js(?:\?v=[^"]+)?"/);
  assert.doesNotMatch(html, /src="app\.js"/);
  assert.doesNotMatch(html, /src="supabase-integration\.js"/);
  assert.doesNotMatch(html, /id="chatPublicView"|id="ticketForm"|Fila de atendimento/);
});

test('as rotas do GitHub Pages usam a base independente /siglab', async () => {
  const [app, reservations, notFound] = await Promise.all([
    read('siglab-app.js'),
    read('reservations.js'),
    read('404.html')
  ]);
  assert.match(app, /\?\s*'\/siglab'\s*:\s*''/);
  assert.match(reservations, /\?\s*'\/siglab'\s*:\s*''/);
  assert.match(notFound, /\?\s*'\/siglab'\s*:\s*''/);
  assert.doesNotMatch(`${app}\n${reservations}\n${notFound}`, /\?\s*'\/labinfo'\s*:\s*''/);
});

test('a configuração publicada aponta somente para o Supabase exclusivo do SIGLAB', async () => {
  const config = await read('supabase-config.js');
  assert.match(config, /window\.SIGLAB_SUPABASE/);
  assert.match(config, /keesciertyonbfqlrqwt\.supabase\.co/);
  assert.match(config, /sb_publishable_m5L9IkzHlYIuwsbcwJ80Hg_B_4QGGXz/);
  assert.doesNotMatch(config, /jvoeaqiusjivyofbyzvi/);
});
