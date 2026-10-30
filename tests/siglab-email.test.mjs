import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const context={Utilities:{formatDate:()=> '02/11/2026 14:00'}};
vm.runInNewContext(fs.readFileSync(new URL('../google-apps-script-siglab/Code.gs',import.meta.url),'utf8'),context);
test('e-mail usa identidade SIGLAB, dados escapados e link institucional',()=>{
  const mail=context.emailReservaSiglab_('reserva_autorizada',{title:'<script>teste</script>',lab:'LAB 1',protocol:'RES-1',starts_at:'2026-11-02T18:00:00Z',ends_at:'2026-11-02T19:00:00Z'});
  assert.match(mail.html,/RESERVA AUTORIZADA/);
  assert.match(mail.html,/laboratorios\.tl\.ifms\.edu\.br\/reservas\//);
  assert.match(mail.html,/laboratorios-logo\.png/);
  assert.ok(!mail.html.includes('<script>'));
  assert.match(mail.body,/Não é necessária confirmação/);
});
test('todos os eventos habilitados possuem versão HTML e texto',()=>{
  for(const event of ['reserva_autorizada','reserva_alterada','reserva_cancelada','reserva_cancelamento_aprovado','reserva_cancelamento_rejeitado']){
    const mail=context.emailReservaSiglab_(event,{reason:'<motivo>',series_count:4});
    assert.match(mail.html,/&lt;motivo&gt;/);
    assert.match(mail.html,/4 ocorrências/);
    assert.ok(mail.body.length>0);
  }
});
