import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
test('cancelamento próprio exige identidade, vínculo, horário futuro e escopo válido',async()=>{
  const sql=await readFile(new URL('../supabase/migrations/20261030_siglab_direct_owner_cancellation.sql',import.meta.url),'utf8');
  assert.match(sql,/current_ifms_server_id\(\)/);
  assert.match(sql,/r\.id=p_reservation and r\.server_id=owner_id for update/);
  assert.match(sql,/r\.server_id=owner_id and r\.status='Autorizada' and r\.starts_at>now\(\)/);
  assert.match(sql,/p_scope is null or p_scope not in/);
  assert.match(sql,/r\.recurrence_group=base\.recurrence_group/);
  assert.match(sql,/revoke all on function public\.cancel_my_reservation\(uuid,text,text\) from public,anon/);
  assert.match(sql,/'reserva_cancelada'/);
  assert.doesNotMatch(sql,/insert into public\.reservation_cancellation_requests/);
});
test('interface autenticada usa cancelamento direto e atualiza agenda',async()=>{
  const js=await readFile(new URL('../reservations.js',import.meta.url),'utf8');
  assert.match(js,/sb\.rpc\('cancel_my_reservation',common\)/);
  assert.match(js,/button\.textContent='Cancelar reserva'/);
  assert.match(js,/await loadSecureReservations\(null\);\s*await loadPublicSchedule\(\)/);
});
