// Proteção idempotente da fila: evita duplicidade quando o Gmail envia,
// mas a confirmação ao Supabase sofre falha temporária.
enviarNotificacoesPendentes_ = function() {
  var items = rpc_('apps_script_pull_outbox', {p_secret: segredo_(), p_limit: 25}) || [];
  var sent = 0;
  items.forEach(function(item) {
    try {
      if (!outboxJaEnviado_(item.id)) {
        var mail = montarEmail_(item.event_type, item.payload || {});
        enviarHtml_(item.recipient, mail.subject, mail.html);
        marcarOutboxEnviado_(item.id);
      }
      rpc_('apps_script_finish_outbox', {p_secret: segredo_(), p_id: item.id, p_success: true, p_error: null});
      sent++;
    } catch (error) {
      console.error('Falha no item ' + item.id + ': ' + error.message);
      rpc_('apps_script_finish_outbox', {p_secret: segredo_(), p_id: item.id, p_success: false, p_error: error.message});
    }
  });
  return sent;
};

function outboxLedger_() {
  var props = PropertiesService.getScriptProperties();
  var ledger = {};
  try { ledger = JSON.parse(props.getProperty('OUTBOX_SENT_LEDGER') || '{}'); } catch (_) {}
  var cutoff = Date.now() - 7 * 24 * 60 * 60 * 1000;
  Object.keys(ledger).forEach(function(id) { if (Number(ledger[id]) < cutoff) delete ledger[id]; });
  return ledger;
}

function outboxJaEnviado_(id) { return Boolean(outboxLedger_()[String(id)]); }

function marcarOutboxEnviado_(id) {
  var ledger = outboxLedger_();
  ledger[String(id)] = Date.now();
  PropertiesService.getScriptProperties().setProperty('OUTBOX_SENT_LEDGER', JSON.stringify(ledger));
}
