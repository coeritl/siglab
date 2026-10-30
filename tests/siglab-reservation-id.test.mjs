import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
test('reserva autenticada qualifica servers.id sem remover checagens ou notificação',async()=>{
  const sql=await readFile(new URL('../supabase/migrations/20261030_siglab_reservation_id_ambiguity.sql',import.meta.url),'utf8');
  assert.match(sql,/from public\.servers as s where s\.id=owner_id/);
  assert.doesNotMatch(sql,/from public\.servers where id=/);
  assert.match(sql,/current_ifms_server_id\(\)/);
  assert.match(sql,/assert_reservation_available/);
  assert.match(sql,/reserva_autorizada/);
  assert.match(sql,/exception when exclusion_violation/);
});
