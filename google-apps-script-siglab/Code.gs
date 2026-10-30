const SIGLAB_MAIL = {
  account: 'siglab.tl@ifms.edu.br',
  url: 'https://laboratorios.tl.ifms.edu.br/',
  database: 'https://keesciertyonbfqlrqwt.supabase.co',
  key: 'sb_publishable_m5L9IkzHlYIuwsbcwJ80Hg_B_4QGGXz'
};

// Execute primeiro. O segredo nunca é exibido; apenas seu hash para o SQL Editor.
function prepararIntegracaoSiglab() {
  validarContaSiglab_();
  const props = PropertiesService.getScriptProperties();
  if (!props.getProperty('SIGLAB_INTEGRATION_SECRET')) {
    props.setProperty('SIGLAB_INTEGRATION_SECRET', Utilities.getUuid() + Utilities.getUuid());
  }
  const hash = Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256,
    props.getProperty('SIGLAB_INTEGRATION_SECRET'), Utilities.Charset.UTF_8)
    .map(b => ('0' + ((b + 256) % 256).toString(16)).slice(-2)).join('');
  console.log("-- Execute SOMENTE no Supabase keesciertyonbfqlrqwt\n" +
    "insert into public.integration_credentials(name,secret_hash) values ('google_apps_script','" + hash +
    "') on conflict(name) do update set secret_hash=excluded.secret_hash,updated_at=now();");
}

// Execute após cadastrar o hash no banco. Não envia mensagens nesta etapa.
function ativarDisparadorSiglab() {
  validarContaSiglab_();
  segredoSiglab_();
  ScriptApp.getProjectTriggers().filter(t => t.getHandlerFunction() === 'enviarEmailsSiglab')
    .forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('enviarEmailsSiglab').timeBased().everyMinutes(5).create();
  console.log('Disparador SIGLAB ativado: consulta a cada 5 minutos.');
}

function validarContaSiglab_() {
  if (Session.getEffectiveUser().getEmail().toLowerCase() !== SIGLAB_MAIL.account) {
    throw new Error('Execute este projeto com a conta ' + SIGLAB_MAIL.account);
  }
}

function segredoSiglab_() {
  const value = PropertiesService.getScriptProperties().getProperty('SIGLAB_INTEGRATION_SECRET');
  if (!value) throw new Error('Execute prepararIntegracaoSiglab primeiro.');
  return value;
}

function enviarEmailsSiglab() {
  validarContaSiglab_();
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(1000)) return;
  try {
    const remaining = MailApp.getRemainingDailyQuota();
    if (remaining < 1) { console.warn('Cota diária de e-mail esgotada.'); return; }
    const items = siglabRpc_('apps_script_pull_outbox', {
      p_secret: segredoSiglab_(), p_limit: Math.min(10, remaining)
    }) || [];
    for (const item of items) {
      const props = PropertiesService.getScriptProperties();
      const ledgerKey = 'SENT_' + item.id;
      try {
        if (!props.getProperty(ledgerKey)) {
          const mail = emailReservaSiglab_(item.event_type, item.payload || {});
          if (!/^[^\s@]+@ifms\.edu\.br$/i.test(item.recipient)) throw new Error('Destinatário institucional inválido.');
          MailApp.sendEmail({to: item.recipient, subject: mail.subject,
            body: mail.body, htmlBody: mail.html, name: 'Laboratórios TL', replyTo: SIGLAB_MAIL.account});
          // Mantido até o banco confirmar: reduz duplicações em falhas de rede.
          props.setProperty(ledgerKey, String(Date.now()));
        }
        siglabRpc_('apps_script_finish_outbox', {p_secret: segredoSiglab_(), p_id: item.id, p_success: true, p_error: null});
        props.deleteProperty(ledgerKey);
      } catch (error) {
        console.error('Falha no e-mail da fila ' + item.id);
        // Se o envio ocorreu, não o marca como falha: aguarda recuperação da fila.
        if (!props.getProperty(ledgerKey)) {
          siglabRpc_('apps_script_finish_outbox', {p_secret: segredoSiglab_(), p_id: item.id,
            p_success: false, p_error: String(error.message).slice(0, 500)});
        }
      }
    }
  } finally { lock.releaseLock(); }
}

function emailReservaSiglab_(event, data) {
  const types = {
    reserva_autorizada: ['Reserva registrada', 'Sua reserva está autorizada. Não é necessária confirmação por e-mail.'],
    reserva_alterada: ['Reserva alterada', 'Confira os dados atualizados da sua reserva.'],
    reserva_cancelada: ['Reserva cancelada', 'Sua reserva foi cancelada.'],
    reserva_cancelamento_aprovado: ['Cancelamento aprovado', 'O cancelamento foi aprovado pela equipe responsável.'],
    reserva_cancelamento_rejeitado: ['Cancelamento não aprovado', 'A reserva permanece ativa. Confira a observação da equipe.']
  };
  if (!types[event]) throw new Error('Evento não habilitado no SIGLAB: ' + event);
  const content = types[event];
  const date = value => value ? Utilities.formatDate(new Date(value), 'America/Cuiaba', 'dd/MM/yyyy HH:mm') : 'Não informado';
  const lines = [content[1], 'Protocolo: ' + (data.protocol || ''),
    'Atividade: ' + (data.title || ''), 'Laboratório: ' + (data.lab || ''),
    'Início: ' + date(data.starts_at), 'Fim: ' + date(data.ends_at)];
  if (data.series_count > 1) lines.push('Reserva recorrente: ' + data.series_count + ' ocorrências. Consulte todas na agenda.');
  if (data.reason) lines.push('Observação: ' + data.reason);
  const url = SIGLAB_MAIL.url + 'reservas/';
  const color = event === 'reserva_cancelada' ? '#b42332' : event === 'reserva_alterada' || event === 'reserva_cancelamento_rejeitado' ? '#946000' : '#08783e';
  const label = event === 'reserva_autorizada' ? 'RESERVA AUTORIZADA' : 'ATUALIZAÇÃO DA RESERVA';
  const details = [['Atividade',data.title],['Laboratório',data.lab],['Início',date(data.starts_at)],['Término',date(data.ends_at)]];
  const detailRows = details.map(([name,value]) => `<tr><td style="padding:6px 0;color:#62736a;font-size:12px;vertical-align:top;width:90px">${name}</td><td style="padding:6px 0;color:#183b2a;font-size:14px;font-weight:bold;line-height:1.5;word-break:break-word">${escaparSiglab_(value || 'Não informado')}</td></tr>`).join('');
  const extra = (data.series_count > 1 ? `<p style="margin:18px 0 0;font-size:13px;line-height:1.6;color:#53685c">Reserva recorrente com <b>${escaparSiglab_(data.series_count)} ocorrências</b>. Consulte todas as datas na sua agenda.</p>` : '') +
    (data.reason ? `<div style="margin-top:18px;padding:16px;background:#fff7e8;border-radius:10px;font-size:14px;line-height:1.6;color:#664b18"><b>Observação da equipe</b><br>${escaparSiglab_(data.reason)}</div>` : '');
  return {subject: 'Laboratórios TL — ' + content[0] + (data.protocol ? ' — ' + data.protocol : ''),
    body: lines.join('\n') + '\nMinhas reservas: ' + url,
    html: `<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head><body style="margin:0;background:#f0f5f2;font-family:Arial,Helvetica,sans-serif;color:#183b2a">
      <div style="display:none;max-height:0;overflow:hidden">${escaparSiglab_(content[0])} · ${escaparSiglab_(data.protocol || '')} · Consulte os dados da sua reserva.</div>
      <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:#f0f5f2"><tr><td align="center" style="padding:28px 12px">
      <table role="presentation" width="600" cellspacing="0" cellpadding="0" style="width:100%;max-width:600px;background:#fff;border:1px solid #dce7df;border-radius:18px;border-top:6px solid ${color}">
      <tr><td style="padding:30px 28px 22px;border-bottom:1px solid #edf2ee"><img src="${SIGLAB_MAIL.url}assets/laboratorios-logo.png" alt="Laboratórios TL" width="260" style="display:block;width:260px;max-width:100%;height:auto"><p style="margin:12px 0 0;font-size:11px;letter-spacing:1px;color:#718378">RESERVAS DE ESPAÇOS · IFMS TRÊS LAGOAS</p></td></tr>
      <tr><td style="padding:28px"><span style="display:inline-block;background:#edf5f0;border-radius:20px;padding:8px 12px;font-size:11px;font-weight:bold;letter-spacing:1px;color:${color}">${label}</span>
      <h1 style="margin:18px 0 12px;font-size:27px;line-height:1.25;color:#163627">${escaparSiglab_(content[0])}</h1>
      <p style="margin:0 0 22px;font-size:15px;line-height:1.7;color:#53685c">${escaparSiglab_(content[1])}</p>
      <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:#f5f9f6;border:1px solid #e0eae3;border-radius:12px"><tr><td style="padding:18px">
      <p style="margin:0 0 12px;padding-bottom:12px;border-bottom:1px solid #dce7df;font-size:12px;color:#61756a">PROTOCOLO <b style="color:#08783e;margin-left:8px">${escaparSiglab_(data.protocol || 'Não informado')}</b></p>
      <table role="presentation" width="100%" cellspacing="0" cellpadding="0">${detailRows}</table></td></tr></table>${extra}
      <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="margin-top:26px"><tr><td align="center" bgcolor="#08783e" style="border-radius:10px"><a href="${url}" style="display:block;padding:16px 18px;color:#fff;font-size:14px;font-weight:bold;text-decoration:none">Consultar minhas reservas →</a></td></tr></table>
      <p style="margin:16px 0 0;text-align:center;font-size:12px;line-height:1.6;color:#7a8980">Acesse com sua conta institucional @ifms.edu.br.</p></td></tr>
      <tr><td style="padding:20px 28px;background:#eaf2ed;border-radius:0 0 18px 18px;text-align:center;color:#597263;font-size:12px;line-height:1.6"><b>Instituto Federal de Mato Grosso do Sul</b><br>Campus Três Lagoas · Laboratórios TL</td></tr></table></td></tr></table></body></html>`};
}

function escaparSiglab_(text) {
  return String(text).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}

function siglabRpc_(name, body) {
  const response = UrlFetchApp.fetch(SIGLAB_MAIL.database + '/rest/v1/rpc/' + name, {
    method: 'post', contentType: 'application/json', muteHttpExceptions: true,
    headers: {apikey: SIGLAB_MAIL.key}, payload: JSON.stringify(body)
  });
  if (response.getResponseCode() < 200 || response.getResponseCode() >= 300) {
    throw new Error('Falha na integração SIGLAB (HTTP ' + response.getResponseCode() + '). Verifique o segredo e as funções do banco.');
  }
  return response.getContentText() ? JSON.parse(response.getContentText()) : null;
}
