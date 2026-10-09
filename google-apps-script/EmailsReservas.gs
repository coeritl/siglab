// Complemento carregado pelo projeto ativo para diferenciar reservas de chamados.
var montarEmailChamado_ = montarEmail_;
montarEmail_ = function(eventType, data) {
  if (String(eventType).indexOf('reserva_') === 0) return montarEmailReservaAtual_(eventType, data || {});
  return montarEmailChamado_(eventType, data || {});
};

function montarEmailReservaAtual_(eventType, data) {
  var types = {
    reserva_confirmar: ['Confirme sua solicitação de reserva','Recebemos sua solicitação. Confirme pelo botão abaixo para encaminhá-la à equipe.','#2167a8','&#9993;','Confirmar solicitação'],
    reserva_confirmada: ['Solicitação de reserva confirmada','Sua confirmação foi registrada. A reserva aguarda autorização da equipe.','#d58a00','&#10003;','Aguardando autorização'],
    reserva_autorizada: ['Reserva autorizada','A equipe autorizou a utilização do laboratório no horário solicitado.','#08783e','&#10003;','Reserva autorizada'],
    reserva_cancelada: ['Reserva de laboratório cancelada','A reserva da sua aula foi cancelada no sistema. Consulte abaixo o laboratório, o horário e o motivo informado pela equipe.','#b5262c','&#10005;','Reserva cancelada'],
    reserva_alterada: ['Horário ou dados da reserva ajustados','O horário ou os dados da sua aula foram ajustados no sistema. Confira abaixo as informações atualizadas.','#d66a00','&#8635;','Reserva alterada']
  };
  var content = types[eventType] || ['Atualização da reserva','Há uma nova informação sobre sua reserva.','#07852a','i','Reserva'];
  var start = data.starts_at ? Utilities.formatDate(new Date(data.starts_at),'America/Cuiaba',"dd/MM/yyyy ' às ' HH:mm") : 'Não informado';
  var end = data.ends_at ? Utilities.formatDate(new Date(data.ends_at),'America/Cuiaba','HH:mm') : '';
  var url = eventType === 'reserva_confirmar' && data.confirmation_url ? data.confirmation_url : 'https://labinfo.tl.ifms.edu.br/reservas/';
  var button = eventType === 'reserva_confirmar' ? 'Confirmar reserva' : 'Consultar reservas';
  var actions = '<a href="'+escapar_(url)+'" style="display:block;background:'+content[2]+';color:#fff;text-align:center;text-decoration:none;font-weight:bold;padding:13px 22px;border-radius:10px">'+button+'</a>';
  if (eventType === 'reserva_confirmar' && data.cancellation_url) actions += '<a href="'+escapar_(data.cancellation_url)+'" style="display:block;margin-top:10px;background:#fff;color:#a52127;text-align:center;text-decoration:none;font-weight:bold;padding:12px 21px;border:1px solid #cf555a;border-radius:10px">Cancelar solicitação</a>';
  var details = '<b>Atividade:</b> '+escapar_(data.title||'')+'<br><b>Laboratório:</b> '+escapar_(data.lab||'')+'<br><b>Data e horário:</b> '+escapar_(start)+(end?' às '+escapar_(end):'')+(data.reason?'<br><b>Motivo:</b> '+escapar_(data.reason):'');
  var html = '<!doctype html><html><body style="margin:0;background:#f2f6f3;font-family:Arial,sans-serif;color:#10231a"><table role="presentation" width="100%"><tr><td align="center" style="padding:28px 12px"><table role="presentation" width="600" style="max-width:600px;background:#fff;border-radius:18px;overflow:hidden;border:1px solid #dce7df"><tr><td style="padding:25px 30px;border-top:7px solid '+content[2]+'"><img src="'+LABINFO.logoUrl+'" alt="LabInfo TL" width="235" style="display:block;max-width:100%;height:auto"></td></tr><tr><td style="padding:2px 30px 30px"><table role="presentation"><tr><td width="46" height="46" align="center" style="border-radius:50%;background:'+content[2]+';color:#fff;font-size:25px;font-weight:bold">'+content[3]+'</td><td style="padding-left:13px"><b style="color:'+content[2]+'">'+escapar_(content[4])+'</b><div style="color:#65736b;font-size:12px">'+escapar_(data.protocol||'')+'</div></td></tr></table><h1 style="font-size:25px;margin:18px 0 12px">'+escapar_(content[0])+'</h1><p style="font-size:16px;line-height:1.6">'+escapar_(content[1])+'</p><table role="presentation" width="100%" style="background:#f5f8f6;border-left:4px solid '+content[2]+';border-radius:12px"><tr><td style="padding:16px;font-size:14px;line-height:1.8">'+details+'</td></tr></table><p style="margin:24px 0 0">'+actions+'</p></td></tr><tr><td style="background:#073d25;color:#dcebe2;padding:18px 30px;font-size:12px">LabInfo TL · Reservas dos Laboratórios de Informática · IFMS Campus Três Lagoas</td></tr></table></td></tr></table></body></html>';
  return {subject:(data.protocol||'LabInfo TL')+' — '+content[0],html:html};
}
