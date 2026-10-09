(function(){
  const cfg=window.LABINFO_SUPABASE||{};
  if(!cfg.url||!cfg.anonKey||!window.supabase){
    document.body.insertAdjacentHTML('afterbegin','<div class="db-banner">Modo demonstração — preencha <code>supabase-config.js</code> para ativar o banco.</div>');
    return;
  }
  const sb=window.supabase.createClient(cfg.url,cfg.anonKey), state={profile:null,session:null};tickets.splice(0,tickets.length);selected=null;
  const siteBase=location.hostname.endsWith('.github.io')?'/labinfo':'';
  const sitePath=route=>`${siteBase}/${route?String(route).replace(/^\/+|\/+$/g,'')+'/':''}`;
  const routeParam=new URLSearchParams(location.search).get('route'),
        feedbackParam=new URLSearchParams(location.search).get('feedback'),
        requestedRoute=routeParam||location.pathname.slice(siteBase.length).replace(/^\/+|\/+$/g,'');
  const adminRouteSlug=requestedRoute==='admin'?'chamados':requestedRoute.startsWith('admin/')?requestedRoute.slice(6):'';
  const validAdminRouteSlugs=new Set(['chamados','relatorios','reservas','chat','cadastros','supervisor','horarios','manutencao']);
  const isAdminRoute=validAdminRouteSlugs.has(adminRouteSlug);
  const isSupportRoute=requestedRoute==='suporte'||Boolean(feedbackParam);
  if(routeParam&&!feedbackParam)window.addEventListener('load',()=>history.replaceState({},'',sitePath(requestedRoute)),{once:true});
  if(isAdminRoute){document.body.classList.add('admin-route');$('#homeView').hidden=true;$('#teacherView').hidden=true;$('#reservationsPublicView').hidden=true;const cp=$('#chatPublicView');if(cp)cp.hidden=true}
  if(isSupportRoute){$('#homeView').hidden=true;$('#teacherView').hidden=false;$('#reservationsPublicView').hidden=true;const cp=$('#chatPublicView');if(cp)cp.hidden=true}
  window.labinfoDb=sb;
  const replace=(target,rows)=>{target.splice(0,target.length,...rows)};
  const fmt=d=>new Intl.DateTimeFormat('pt-BR',{dateStyle:'short',timeStyle:'short'}).format(new Date(d));
  const safe=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const sortCategories=()=>data.categories.sort((a,b)=>{const aOther=a.name.trim().toLocaleLowerCase('pt-BR')==='outro',bOther=b.name.trim().toLocaleLowerCase('pt-BR')==='outro';return aOther!==bOther?(aOther?1:-1):a.name.localeCompare(b.name,'pt-BR')});
  const fail=(e,msg='Não foi possível concluir a operação.')=>{console.error(e);toast(e?.message||msg)};
  document.body.insertAdjacentHTML('beforeend','<div id="adminProcessing" class="admin-processing" hidden role="status" aria-live="assertive"><div><i></i><strong>Processando…</strong><span>Aguarde a atualização dos dados.</span></div></div>');
  const processing=$('#adminProcessing'),setProcessing=(active,message='Processando…')=>{processing.hidden=!active;processing.querySelector('strong').textContent=message;document.body.classList.toggle('is-processing',active)};
  const baseToast=toast;toast=function(message){setProcessing(false);baseToast(message)};
  const dayMeta=[['mon','Segunda-feira'],['tue','Terça-feira'],['wed','Quarta-feira'],['thu','Quinta-feira'],['fri','Sexta-feira'],['sat','Sábado'],['sun','Domingo']];
  let serviceHours={days:Object.fromEntries(dayMeta.map(([k])=>[k,{enabled:!['sat','sun'].includes(k),start:'07:00',end:'22:00'}])),note:''};
  const hourLabel=v=>(v||'').replace(/^0/,'').replace(':00','h').replace(':','h');
  function serviceHoursSummary(value=serviceHours){const d=value.days||{},week=dayMeta.slice(0,5).every(([k])=>d[k]?.enabled&&d[k].start===d.mon?.start&&d[k].end===d.mon?.end),weekend=!d.sat?.enabled&&!d.sun?.enabled;if(week&&weekend)return `Segunda a sexta, das ${hourLabel(d.mon.start)} às ${hourLabel(d.mon.end)}`;const enabled=dayMeta.filter(([k])=>d[k]?.enabled);return enabled.length?enabled.map(([k,n])=>`${n.replace('-feira','')}: ${hourLabel(d[k].start)}–${hourLabel(d[k].end)}`).join(' • '):'Atendimento temporariamente indisponível'}
  async function loadServiceHours(){const {data:row,error}=await sb.from('system_settings').select('value').eq('key','service_hours').maybeSingle();if(error){console.warn(error);return}if(row?.value)serviceHours=row.value;const text=$('#serviceHoursText');if(text)text.textContent=serviceHours.note||serviceHoursSummary()}
  async function confirmFeedbackFromLink(){
    const token=new URLSearchParams(location.search).get('feedback');
    if(!token)return;
    $('#homeView').hidden=true;
    $('#teacherView').hidden=false;
    $('#reservationsPublicView').hidden=true;
    const cp=$('#chatPublicView');if(cp)cp.hidden=true;

    try {
      const {data,error}=await sb.rpc('confirm_ticket_feedback',{p_token:token.trim()});
      const ok=!error;
      const protocol=data?.[0]?.protocol||'';
      const message=ok?`Atendimento ${protocol?protocol+' ':''}confirmado com sucesso. Obrigado pelo retorno!`:(error?.message||'Não foi possível confirmar este atendimento. O link pode ser inválido ou o chamado ainda não foi concluído.');
      const anchor=document.querySelector('#teacherView .hero')||document.querySelector('.hero');
      document.querySelectorAll('.feedback-confirmation').forEach(el=>el.remove());
      anchor?.insertAdjacentHTML('afterend',`
        <section class="card feedback-confirmation ${ok?'success':'error-text'}" role="status" style="margin:20px auto;max-width:760px;">
          <span style="font-size:24px;font-weight:900;">${ok?'✓':'!'}</span>
          <div>
            <strong>${safe(message)}</strong>
            <p>${ok?'A equipe técnica já recebeu sua confirmação de atendimento. Obrigado pelo retorno!':'Verifique o chamado ou solicite apoio à equipe técnica.'}</p>
          </div>
        </section>
      `);
      if(protocol){
        const protoInput=$('#protocolInput');
        if(protoInput)protoInput.value=protocol;
      }
      history.replaceState({},'',sitePath('suporte'));
      setTimeout(()=>document.querySelector('.feedback-confirmation')?.scrollIntoView({behavior:'smooth',block:'center'}),150);
    } catch(err){
      console.error('Erro na confirmação de feedback:',err);
    }
  }

  document.body.insertAdjacentHTML('beforeend',`<div id="loginModal" class="modal-backdrop" hidden><div class="card login-card"><div class="modal-heading"><div><span class="eyebrow">ACESSO RESTRITO</span><h2>Entrar no painel</h2><p>Use as credenciais cadastradas no Supabase.</p></div><button id="closeLogin" class="modal-close">×</button></div><form id="loginForm"><label>E-mail do usuário<input id="loginEmail" type="email" autocomplete="username" required></label><label>Senha<input id="loginPassword" type="password" autocomplete="current-password" required></label><p id="loginError" class="login-error"></p><button class="primary" type="submit">Entrar</button></form></div></div>`);
  const loginModal=$('#loginModal');
  const loginIsRequired=()=>location.pathname.includes('/admin')||new URLSearchParams(location.search).get('route')==='admin';
  const openLogin=()=>{loginModal.hidden=false;document.body.classList.add('modal-open')};
  const closeLogin=(force=false)=>{
    loginModal.hidden=true;
    document.body.classList.remove('modal-open');
    if(!state.profile){
      document.body.classList.remove('admin-route');
      $('#homeView').hidden=false;
      $('#teacherView').hidden=true;
      $('#reservationsPublicView').hidden=true;
      const cp=$('#chatPublicView');if(cp)cp.hidden=true;
      $('#adminToggle').textContent='Área técnica';
      history.pushState({},'',sitePath(''));
    }
  };
  $('#closeLogin').onclick=()=>closeLogin();
  $('#loginForm').onsubmit=async e=>{e.preventDefault();$('#loginError').textContent='';const button=e.submitter||e.target.querySelector('[type="submit"]');button.disabled=true;button.textContent='Entrando…';const {data:auth,error}=await sb.auth.signInWithPassword({email:$('#loginEmail').value.trim(),password:$('#loginPassword').value});if(error){button.disabled=false;button.textContent='Entrar';$('#loginError').textContent='Usuário ou senha inválidos.';return}state.session=auth.session;closeLogin(true);await enterAdmin();button.disabled=false;button.textContent='Entrar'};

  async function performLogout(){
    try {
      if(state.profile?.role==='tecnico'){
        staffChatDesiredOnline=false;
        localStorage.setItem(staffChatPreferenceKey(state.profile.id),'false');
        await sb.rpc('set_staff_chat_status',{p_online:false});
      }
      stopStaffHeartbeat();
      stopIncomingCallRingtone();
      await sb.auth.signOut();
    } catch(err) {
      console.warn('Erro ao encerrar sessão:', err);
    }
    state.profile=null;
    state.session=null;
    if(accountDropdown)accountDropdown.hidden=true;
    accountActions.hidden=true;
    $('#adminView').hidden=true;
    document.body.classList.remove('admin-route');
    document.body.classList.remove('modal-open');
    if(loginModal)loginModal.hidden=true;

    $('#homeView').hidden=false;
    $('#teacherView').hidden=true;
    $('#reservationsPublicView').hidden=true;
    const cp=$('#chatPublicView');if(cp)cp.hidden=true;

    $('#adminToggle').textContent='Área técnica';
    $('#adminToggle').hidden=false;
    history.pushState({},'',sitePath(''));
    window.scrollTo({top:0,behavior:'smooth'});
    toast('Você saiu do sistema.');
  }

  const accountActions=document.createElement('div');accountActions.className='admin-heading-actions topbar-admin-actions';accountActions.hidden=true;const adminMenu=$('.admin-menu');adminMenu.before(accountActions);accountActions.append(adminMenu);
  accountActions.insertAdjacentHTML('beforeend',`
    <div class="staff-chat-toggle-wrap" id="staffChatToggleWrap" title="Disponibilidade para atendimento via chat">
      <label class="switch-toggle" title="Alternar disponibilidade do chat ao vivo">
        <input type="checkbox" id="staffChatToggle" />
        <span class="toggle-slider"></span>
      </label>
      <span id="staffChatToggleLabel" class="chat-toggle-label">Chat: <strong>Offline</strong></span>
      <span id="topbarOnlineStaffPill" class="chat-status-badge offline" style="font-size:10px;padding:2px 7px;cursor:pointer;" title="Técnicos online agora"><span class="status-dot offline"></span> 0 online</span>
    </div>
    <div class="account-menu">
      <button id="accountButton" class="account-button" type="button" aria-expanded="false"><span id="accountAvatar">U</span><span><strong id="accountName">Usuário</strong><small id="accountRole">Perfil</small></span><b>▾</b></button>
      <div id="accountDropdown" class="account-dropdown" hidden>
        <div><strong id="accountMenuName"></strong><small id="accountEmail"></small></div>
        <button id="changePasswordButton" type="button">Alterar senha</button>
        <button id="accountLogout" type="button">Sair do sistema</button>
      </div>
    </div>
  `);
  $('.topbar').insertBefore(accountActions,$('#adminToggle'));
  document.body.insertAdjacentHTML('beforeend','<div id="passwordModal" class="modal-backdrop" hidden><div class="card login-card"><div class="modal-heading"><div><span class="eyebrow">SEGURANÇA DA CONTA</span><h2>Alterar senha</h2><p>Confirme sua senha atual antes de definir uma nova.</p></div><button id="closePasswordModal" class="modal-close" type="button" aria-label="Fechar">×</button></div><form id="passwordForm"><label>Senha atual<input id="currentPassword" type="password" autocomplete="current-password" required></label><label>Nova senha<input id="newPassword" type="password" autocomplete="new-password" minlength="8" required></label><label>Confirmar nova senha<input id="confirmPassword" type="password" autocomplete="new-password" minlength="8" required></label><p id="passwordError" class="login-error"></p><button class="primary" type="submit">Atualizar senha</button></form></div></div>');
  new MutationObserver(()=>{accountActions.hidden=$('#adminView').hidden}).observe($('#adminView'),{attributes:true,attributeFilter:['hidden']});
  const accountDropdown=$('#accountDropdown'),passwordModal=$('#passwordModal');
  const closePasswordModal=()=>{passwordModal.hidden=true;document.body.classList.remove('modal-open');$('#passwordForm').reset();$('#passwordError').textContent=''};
  $('#accountButton').onclick=()=>{accountDropdown.hidden=!accountDropdown.hidden;$('#accountButton').setAttribute('aria-expanded',String(!accountDropdown.hidden))};
  $('#changePasswordButton').onclick=()=>{accountDropdown.hidden=true;passwordModal.hidden=false;document.body.classList.add('modal-open');$('#currentPassword').focus()};
  $('#closePasswordModal').onclick=closePasswordModal;passwordModal.onclick=e=>{if(e.target===passwordModal)closePasswordModal()};
  $('#accountLogout').onclick=performLogout;
  $('#passwordForm').onsubmit=async e=>{e.preventDefault();const current=$('#currentPassword').value,next=$('#newPassword').value,confirm=$('#confirmPassword').value,errorBox=$('#passwordError');errorBox.textContent='';if(next!==confirm){errorBox.textContent='A confirmação não corresponde à nova senha.';return}if(next===current){errorBox.textContent='A nova senha deve ser diferente da senha atual.';return}const email=state.session?.user?.email;const {error:authError}=await sb.auth.signInWithPassword({email,password:current});if(authError){errorBox.textContent='A senha atual está incorreta.';return}const {error:updateError}=await sb.auth.updateUser({password:next});if(updateError){errorBox.textContent=updateError.message;return}closePasswordModal();toast('Senha atualizada com sucesso.')};

  $('#adminMenuDropdown').querySelector('[data-section="tickets"]')?.remove();$('#adminMenuDropdown').querySelector('[data-section="analytics"]').textContent='Relatórios';$('#adminMenuDropdown').querySelector('[data-section="supervisor"]').textContent='Supervisor';$('#adminMenuDropdown').insertAdjacentHTML('beforeend','<button id="chatMenuButton" type="button"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" style="vertical-align:middle;margin-right:4px;"><path d="M7.9 20A9 9 0 1 0 4 16.1L2 22Z"/></svg> Chat ao vivo <span id="chatMenuBadge" class="chat-menu-badge" hidden>0</span></button><button id="hoursMenuButton">Horários</button><button id="maintenanceMenuButton">Manutenção</button><button id="reservationsMenuButton" type="button">Reservas</button>');
  const adminMenuDropdown=$('#adminMenuDropdown'),analyticsMenuButton=adminMenuDropdown.querySelector('[data-section="analytics"]'),registrationsMenuButton=adminMenuDropdown.querySelector('[data-section="registrations"]'),supervisorMenuButton=adminMenuDropdown.querySelector('[data-section="supervisor"]'),reservationsMenuButton=$('#reservationsMenuButton'),chatMenuButton=$('#chatMenuButton');
  const primaryAdminNav=document.createElement('nav');primaryAdminNav.className='primary-admin-nav';primaryAdminNav.setAttribute('aria-label','Navegação principal do painel');
  [analyticsMenuButton,reservationsMenuButton,chatMenuButton].forEach(button=>{button.dataset.adminNav='primary';primaryAdminNav.append(button)});
  [registrationsMenuButton,supervisorMenuButton,$('#hoursMenuButton'),$('#maintenanceMenuButton')].forEach(button=>button.dataset.adminNav='management');
  $('#adminMenuButton').textContent='Administração ▾';
  const mobileAdminMenuButton=document.createElement('button');mobileAdminMenuButton.id='mobileAdminMenuButton';mobileAdminMenuButton.className='mobile-admin-menu-button';mobileAdminMenuButton.type='button';mobileAdminMenuButton.setAttribute('aria-label','Abrir menu do painel');mobileAdminMenuButton.setAttribute('aria-expanded','false');mobileAdminMenuButton.innerHTML='<span></span><span></span><span></span>';
  const mobileAdminBackdrop=document.createElement('button');mobileAdminBackdrop.id='mobileAdminBackdrop';mobileAdminBackdrop.className='mobile-admin-backdrop';mobileAdminBackdrop.type='button';mobileAdminBackdrop.setAttribute('aria-label','Fechar menu do painel');
  const adminNavShell=document.createElement('div');adminNavShell.className='admin-nav-shell';
  accountActions.prepend(mobileAdminBackdrop,mobileAdminMenuButton);
  accountActions.insertBefore(primaryAdminNav,adminMenu);
  [primaryAdminNav,adminMenu,$('#staffChatToggleWrap'),$('.account-menu')].forEach(element=>adminNavShell.append(element));
  accountActions.append(adminNavShell);
  chatMenuButton.append($('#topbarOnlineStaffPill'));
  const closeMobileAdminMenu=()=>{accountActions.classList.remove('mobile-open');mobileAdminMenuButton.setAttribute('aria-expanded','false');document.body.classList.remove('admin-nav-open')};
  mobileAdminMenuButton.onclick=()=>{const open=!accountActions.classList.contains('mobile-open');accountActions.classList.toggle('mobile-open',open);mobileAdminMenuButton.setAttribute('aria-expanded',String(open));document.body.classList.toggle('admin-nav-open',open)};
  mobileAdminBackdrop.onclick=closeMobileAdminMenu;
  document.addEventListener('keydown',event=>{if(event.key==='Escape'&&accountActions.classList.contains('mobile-open'))closeMobileAdminMenu()});
  accountActions.querySelectorAll('[data-admin-nav], #accountLogout').forEach(button=>button.addEventListener('click',()=>{accountActions.querySelectorAll('[data-admin-nav]').forEach(item=>item.classList.remove('active'));button.classList.add('active');closeMobileAdminMenu()}));
  $('.brand').addEventListener('click',e=>{if(!$('#adminView').hidden){e.preventDefault();closeMobileAdminMenu();history.pushState({},'',sitePath('admin/chamados'));showSection('tickets');window.scrollTo(0,0)}});
  $('#supervisorSection').insertAdjacentHTML('afterend','<section id="hoursSection" class="admin-section" hidden><form id="hoursForm" class="card hours-card"><span class="eyebrow">CONFIGURAÇÃO PÚBLICA</span><h2>Horários de atendimento</h2><p>Defina os dias e horários exibidos na página de abertura de chamados.</p><div id="hoursGrid" class="hours-grid"></div><label>Observação pública (opcional)<input id="hoursNote" maxlength="140" placeholder="Ex.: Atendimento reduzido durante o recesso"></label><button class="primary" type="submit">Salvar horários</button></form></section>');
  $('#hoursSection').insertAdjacentHTML('afterend','<section id="maintenanceSection" class="admin-section" hidden><div class="card maintenance-card"><div class="maintenance-head"><div><span class="eyebrow">SAÚDE DAS INTEGRAÇÕES</span><h2>Uso dos serviços gratuitos</h2><p>Métricas reais do banco, armazenamento e processamento de e-mails.</p></div><button id="refreshMaintenance" class="secondary" type="button">Atualizar métricas</button></div><div id="maintenanceAlerts" class="maintenance-alerts" aria-live="polite"></div><div id="maintenanceMetrics" class="maintenance-grid"><p>Carregando métricas…</p></div><section class="email-operations"><div class="email-operations-head"><div><h3>Fila de notificações</h3><p>Itens com falha ou atraso podem ser reenviados com segurança.</p></div></div><div id="emailOutboxProblems"><p class="empty">Carregando fila…</p></div></section><div class="maintenance-note"><strong>Tráfego mensal do Supabase</strong><p>O tráfego consolidado não é exposto com segurança pela API SQL. Consulte o painel Usage do Supabase para esse indicador.</p></div></div></section>');
  $('#maintenanceSection').insertAdjacentHTML('afterend',`
    <section id="chatAdminSection" class="admin-section" hidden>
      <div class="card chat-admin-card">
        <div class="chat-admin-head">
          <div>
            <span class="eyebrow">CENTRAL DE ATENDIMENTO REALTIME</span>
            <h2>Atendimento ao Vivo via Chat</h2>
            <p>Acompanhe chamados solicitados em tempo real e converse diretamente com os docentes e servidores.</p>
          </div>
          <div class="chat-admin-head-status">
            <span id="chatAdminStatusIndicator" class="chat-status-badge offline"><span class="status-dot offline"></span> Offline</span>
            <button id="chatAdminToggleStatusBtn" class="secondary" type="button">Ficar Online</button>
          </div>
        </div>
        <div class="chat-online-staff-card" id="chatOnlineStaffCard" style="background:#fff;border:1px solid var(--line);border-radius:12px;padding:14px 18px;margin-bottom:20px;display:flex;align-items:center;justify-content:space-between;gap:14px;flex-wrap:wrap;box-shadow:0 2px 6px rgba(0,0,0,0.02);">
          <div style="display:flex;align-items:center;gap:10px;">
            <span style="display:inline-grid;place-items:center;width:34px;height:34px;border-radius:8px;background:var(--green-soft);color:var(--green);font-size:16px;font-weight:900;">
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/></svg>
            </span>
            <div>
              <strong style="font-size:13px;display:block;">Técnicos Online Agora (<span id="onlineStaffCount">0</span>)</strong>
              <small style="color:var(--muted);font-size:11px;">Membros da equipe disponíveis para atendimento via chat</small>
            </div>
          </div>
          <div id="onlineStaffBadges" style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;">
            <span class="chat-status-badge offline">Nenhum técnico online</span>
          </div>
        </div>
        <div class="chat-admin-grid">
          <div class="chat-admin-queue-card">
            <div class="chat-queue-heading">
              <div style="display:flex;justify-content:space-between;align-items:center;">
                <h3>Fila de Espera <span id="chatWaitingCount" class="count-pill">0</span></h3>
                <button id="clearChatQueueBtn" class="secondary" type="button" style="padding:4px 10px;font-size:11px;" title="Limpar chamadas pendentes ou testes da fila">Limpar fila</button>
              </div>
              <p>Servidores aguardando conexão com um técnico de plantão</p>
            </div>
            <div id="chatWaitingList" class="chat-sessions-list">
              <p class="empty">Nenhum servidor aguardando no momento.</p>
            </div>
          </div>
          <div class="chat-admin-active-card">
            <div class="chat-queue-heading">
              <h3>Em Atendimento Agora <span id="chatActiveCount" class="count-pill active">0</span></h3>
              <p>Sessões ativas com técnicos</p>
            </div>
            <div id="chatActiveList" class="chat-sessions-list">
              <p class="empty">Nenhum chat ativo no momento.</p>
            </div>
          </div>
        </div>
        <div class="chat-admin-history">
          <div class="chat-history-heading">
            <h3>Histórico Recente de Atendimentos por Chat</h3>
            <div class="chat-history-actions"><button id="refreshChatDashboard" class="secondary" type="button">Atualizar lista</button><button id="clearChatHistory" class="danger-button" type="button">Limpar histórico</button></div>
          </div>
          <div id="chatHistoryList" class="chat-history-table">
            <p class="empty">Carregando histórico...</p>
          </div>
        </div>
      </div>
    </section>
  `);
  function renderHoursForm(){const grid=$('#hoursGrid');grid.innerHTML=dayMeta.map(([key,name])=>{const d=serviceHours.days?.[key]||{enabled:false,start:'07:00',end:'18:00'};return `<div class="hours-row"><label class="hours-day"><input type="checkbox" name="${key}-enabled" ${d.enabled?'checked':''}>${name}</label><label>Início<input type="time" name="${key}-start" value="${d.start||'07:00'}" ${d.enabled?'':'disabled'}></label><label>Fim<input type="time" name="${key}-end" value="${d.end||'18:00'}" ${d.enabled?'':'disabled'}></label></div>`}).join('');$('#hoursNote').value=serviceHours.note||'';grid.querySelectorAll('input[type=checkbox]').forEach(c=>c.onchange=()=>c.closest('.hours-row').querySelectorAll('input[type=time]').forEach(i=>i.disabled=!c.checked))}
  $('#hoursMenuButton').onclick=()=>{document.querySelectorAll('.admin-section').forEach(x=>x.hidden=true);$('#hoursSection').hidden=false;$('#adminTitle').textContent='Horários de atendimento';$('#adminSubtitle').textContent='Configure a disponibilidade exibida aos servidores.';$('#adminMenuDropdown').hidden=true;renderHoursForm()};
  const bytes=(n)=>n<1048576?(n/1024).toFixed(1)+' KB':(n/1048576).toFixed(1)+' MB';const usageCard=(label,value,detail,pct)=>`<article class="usage-card ${pct>=90?'danger':pct>=70?'warning':''}"><span>${label}</span><strong>${value}</strong><small>${detail}</small>${pct==null?'':`<div class="usage-bar"><i style="width:${Math.min(100,pct)}%"></i></div><em>${pct.toFixed(1)}% utilizado</em>`}</article>`;
  let maintenanceTimer=null;
  async function renderMaintenance(){
    const box=$('#maintenanceMetrics'),alerts=$('#maintenanceAlerts'),problems=$('#emailOutboxProblems');
    if(box)box.innerHTML='<p>Atualizando métricas…</p>';
    const {data:m,error}=await sb.rpc('maintenance_metrics');
    if(error){if(box)box.innerHTML='<p class="error-text">Não foi possível carregar as métricas.</p>';return fail(error)}
    if(!box)return;
    const dbPct=m.database_bytes/524288000*100,storagePct=m.attachment_bytes/1073741824*100,emailRemaining=m.email_quota_remaining,emailPct=emailRemaining==null?null:(1500-emailRemaining)/1500*100;
    const lastOutbox=m.last_outbox_run?new Date(m.last_outbox_run):null,heartbeatMinutes=lastOutbox?Math.floor((Date.now()-lastOutbox.getTime())/60000):null;
    const health=[];
    if(!lastOutbox||heartbeatMinutes>5)health.push(`<div class="maintenance-alert danger"><strong>Processamento de e-mails sem atividade</strong><span>${lastOutbox?'Última execução há '+heartbeatMinutes+' min.':'Nenhuma execução registrada.'} Verifique o gatilho de saída do Apps Script.</span></div>`);
    if(Number(m.outbox_failed)>0)health.push(`<div class="maintenance-alert danger"><strong>${m.outbox_failed} notificação(ões) com falha definitiva</strong><span>Revise o erro e use Reenviar.</span></div>`);
    if(Number(m.outbox_overdue)>0)health.push(`<div class="maintenance-alert warning"><strong>${m.outbox_overdue} notificação(ões) atrasada(s)</strong><span>Aguardam processamento há mais de cinco minutos.</span></div>`);
    if(!health.length)health.push('<div class="maintenance-alert healthy"><strong>Integrações operando normalmente</strong><span>A fila e o processamento de e-mails estão dentro do esperado.</span></div>');
    alerts.innerHTML=health.join('');
    box.innerHTML=usageCard('Banco de dados',bytes(m.database_bytes),'Limite gratuito: 500 MB',dbPct)+usageCard('Imagens armazenadas',bytes(m.attachment_bytes),`${m.attachment_count} arquivo(s) · limite: 1 GB`,storagePct)+usageCard('Enviados hoje',m.outbox_sent_today,emailRemaining==null?'Cota real ainda não informada pelo Apps Script':`${emailRemaining} destinatário(s) restantes hoje`,emailPct)+usageCard('E-mails no mês',m.sent_month,'Contagem registrada pelo LabInfo',null)+usageCard('Pendentes',m.outbox_pending,`${m.outbox_processing} em processamento`,null)+usageCard('Falhas',m.outbox_failed,m.outbox_last_error?'Último erro: '+m.outbox_last_error:'Nenhuma falha registrada',null)+usageCard('Consulta da caixa hoje',m.inbox_runs_today,m.last_inbox_run?'Última: '+fmt(m.last_inbox_run):'Ainda não executada',null)+usageCard('Fila de saída hoje',m.outbox_runs_today,lastOutbox?'Última: '+fmt(m.last_outbox_run):'Ainda não executada',null);
    const rows=Array.isArray(m.outbox_problems)?m.outbox_problems:[];
    problems.innerHTML=rows.length?rows.map(item=>`<article class="outbox-problem"><div><strong>${safe(item.protocol||'Notificação')} · ${safe(item.event_type)}</strong><span>${safe(item.recipient)} · ${item.attempts} tentativa(s)</span><small>${safe(item.last_error||'Aguardando processamento')} · ${fmt(item.available_at)}</small></div>${state.profile?.role==='tecnico'?`<button class="secondary retry-outbox" data-id="${item.id}" type="button">Reenviar</button>`:''}</article>`).join(''):'<p class="empty">Nenhuma notificação atrasada ou com falha.</p>';
    problems.querySelectorAll('.retry-outbox').forEach(button=>button.onclick=async()=>{button.disabled=true;button.textContent='Agendando…';const {error}=await sb.rpc('retry_email_outbox',{p_id:Number(button.dataset.id)});if(error){button.disabled=false;button.textContent='Reenviar';return fail(error)}toast('Notificação reagendada. O envio ocorrerá em até um minuto.');await renderMaintenance()});
  }
  $('#maintenanceMenuButton').onclick=()=>{document.querySelectorAll('.admin-section').forEach(x=>x.hidden=true);$('#maintenanceSection').hidden=false;$('#adminTitle').textContent='Manutenção';$('#adminSubtitle').textContent='Acompanhe limites, integrações e filas do sistema.';$('#adminMenuDropdown').hidden=true;clearInterval(maintenanceTimer);renderMaintenance();maintenanceTimer=setInterval(()=>{if(!$('#maintenanceSection').hidden)renderMaintenance()},60000)};$('#refreshMaintenance').onclick=renderMaintenance;
  $('#chatMenuButton').onclick=()=>{document.querySelectorAll('.admin-section').forEach(x=>x.hidden=true);$('#chatAdminSection').hidden=false;$('#adminTitle').textContent='Chat ao vivo';$('#adminSubtitle').textContent='Gerencie atendimentos em tempo real e conversas com os servidores.';$('#adminMenuDropdown').hidden=true;renderChatAdminDashboard()};
  async function openReservationsWhenReady(attempt=0){
    const ready=window.labinfoReservationsReady;
    if(ready?.then)await ready;
    if(window.labinfoOpenReservations)return window.labinfoOpenReservations();
    // Em uma restauração de sessão muito rápida, o arquivo pode ainda não ter
    // começado a avaliar. Aguarde brevemente em vez de manipular um DOM ausente.
    if(attempt<20)return new Promise(resolve=>setTimeout(resolve,25)).then(()=>openReservationsWhenReady(attempt+1));
    toast('A agenda ainda está sendo preparada. Tente abrir Reservas novamente.');
  }
  $('#reservationsMenuButton').onclick=()=>{void openReservationsWhenReady()};
  const adminRouteByTarget={
    analytics:'relatorios',registrations:'cadastros',supervisor:'supervisor',
    reservationsMenuButton:'reservas',chatMenuButton:'chat',hoursMenuButton:'horarios',maintenanceMenuButton:'manutencao'
  };
  function openAdminRoute(slug,{push=false}={}){
    const route=validAdminRouteSlugs.has(slug)?slug:'chamados';
    if(push&&location.pathname!==sitePath('admin/'+route))history.pushState({},'',sitePath('admin/'+route));
    if(route==='chamados')showSection('tickets');
    else if(route==='relatorios')showSection('analytics');
    else if(route==='cadastros')showSection('registrations');
    else if(route==='supervisor')showSection('supervisor');
    else if(route==='reservas')void openReservationsWhenReady();
    else if(route==='chat')$('#chatMenuButton').onclick();
    else if(route==='horarios')$('#hoursMenuButton').onclick();
    else if(route==='manutencao')$('#maintenanceMenuButton').onclick();
    accountActions.querySelectorAll('[data-admin-nav]').forEach(item=>item.classList.toggle('active',(item.dataset.section&&adminRouteByTarget[item.dataset.section]===route)||adminRouteByTarget[item.id]===route));
    closeMobileAdminMenu();
    window.scrollTo(0,0);
  }
  window.labinfoOpenAdminRoute=openAdminRoute;
  accountActions.addEventListener('click',event=>{
    const target=event.target.closest('[data-section], #reservationsMenuButton, #chatMenuButton, #hoursMenuButton, #maintenanceMenuButton');
    if(!target)return;
    const slug=target.dataset.section?adminRouteByTarget[target.dataset.section]:adminRouteByTarget[target.id];
    if(slug&&location.pathname!==sitePath('admin/'+slug))history.pushState({},'',sitePath('admin/'+slug));
  });
  window.addEventListener('popstate',()=>{
    const route=location.pathname.slice(siteBase.length).replace(/^\/+|\/+$/g,'');
    const slug=route==='admin'?'chamados':route.startsWith('admin/')?route.slice(6):'';
    if(state.profile&&validAdminRouteSlugs.has(slug))openAdminRoute(slug);
  });
  $('#refreshChatDashboard')?.addEventListener('click', renderChatAdminDashboard);
  $('#clearChatHistory')?.addEventListener('click',async()=>{if(!confirm('Excluir permanentemente todo o histórico de chats encerrados? Chats ativos e aguardando atendimento serão preservados.'))return;const button=$('#clearChatHistory');button.disabled=true;button.textContent='Limpando…';const {data,error}=await sb.rpc('clear_closed_chat_history');button.disabled=false;button.textContent='Limpar histórico';if(error)return fail(error,'Não foi possível limpar o histórico.');toast(`${Number(data||0)} atendimento(s) removido(s) do histórico.`);await renderChatAdminDashboard()});
  $('#chatAdminToggleStatusBtn')?.addEventListener('click', ()=>{const toggle=$('#staffChatToggle');if(toggle){toggle.checked=!toggle.checked;toggle.dispatchEvent(new Event('change'))}});
  $('#clearChatQueueBtn')?.addEventListener('click', async () => {
    if (!confirm('Deseja limpar e encerrar todas as solicitações pendentes da fila de espera?')) return;
    try {
      const { error } = await sb.rpc('clear_stale_chat_sessions');
      if (error) throw error;
      toast('Fila de espera limpa.');
      renderChatAdminDashboard();
    } catch (e) {
      await sb.from('chat_sessions').update({ status: 'closed', closed_at: new Date().toISOString(), notes: 'Fila limpa pelo técnico' }).eq('status', 'waiting');
      toast('Fila de espera limpa.');
      renderChatAdminDashboard();
    }
  });
  $('#hoursForm').onsubmit=async e=>{e.preventDefault();const form=new FormData(e.target),days={};for(const [key] of dayMeta){const enabled=form.has(`${key}-enabled`),start=form.get(`${key}-start`)||'07:00',end=form.get(`${key}-end`)||'18:00';if(enabled&&start>=end)return toast('O horário final deve ser posterior ao inicial.');days[key]={enabled,start,end}}const value={days,note:$('#hoursNote').value.trim()};const {error}=await sb.from('system_settings').upsert({key:'service_hours',value,updated_by:state.profile.id,updated_at:new Date().toISOString()});if(error)return fail(error);serviceHours=value;$('#serviceHoursText').textContent=value.note||serviceHoursSummary(value);toast('Horários atualizados com sucesso.')};

  async function catalogs(){
    $('#category').disabled=true;$('#lab').disabled=true;
    const [{data:cats,error:ce},{data:labs,error:le}]=await Promise.all([sb.from('categories').select('*').eq('active',true).order('name'),sb.from('labs').select('*').eq('active',true).order('name')]);
    if(ce||le){$('#category').innerHTML='<option value="">Não foi possível carregar</option>';$('#lab').innerHTML='<option value="">Não foi possível carregar</option>';return fail(ce||le,'Erro ao carregar cadastros.');}
    replace(data.categories,cats.map(x=>({id:x.id,name:x.name})));sortCategories();
    replace(data.labs,labs.map(x=>({id:x.id,name:x.name,location:x.location,code:x.code,computerCount:x.computer_count||0,operatingSystem:x.operating_system||'',active:true})));options();$('#category').disabled=false;$('#lab').disabled=false;
  }
  identify=async function(){const siape=$('#siape').value.trim(),hint=$('#siapeHint'),email=$('#email');email.value='';email.readOnly=true;email.required=true;$('#teacherIdentity').textContent='';if(siape.length<5){hint.textContent='Digite seu SIAPE para identificação automática';hint.className='field-hint';return}const {data:rows,error}=await sb.rpc('identify_server',{p_siape:siape});const server=rows?.[0];if(error||!server){email.readOnly=false;email.placeholder='seu.email@ifms.edu.br';hint.textContent='SIAPE não localizado. Informe seu e-mail institucional para abrir o chamado.';hint.className='field-hint pending';$('#teacherIdentity').textContent='O cadastro será regularizado posteriormente pela equipe técnica.';return}replace(data.teachers,[...data.teachers.filter(x=>x.siape!==siape),{id:server.id,siape,name:server.full_name,email:server.email}]);email.value=server.email;email.placeholder='';$('#teacherIdentity').textContent=server.full_name;$('#teacherIdentity').className='field-hint found';hint.textContent='Cadastro localizado';hint.className='field-hint found'};
  $('#siape').oninput=()=>{clearTimeout(window.siapeTimer);window.siapeTimer=setTimeout(identify,350)};

  async function uploadFiles(ticketId,siape,prefix){
    for(const item of attachmentState[prefix]){const safe=item.name.replace(/[^a-zA-Z0-9._-]/g,'_'),path=`tickets/${ticketId}/${crypto.randomUUID()}-${safe}`;const {error}=await sb.storage.from('ticket-attachments').upload(path,item.file,{contentType:item.file.type,upsert:false});if(error)throw error;const {error:reg}=await sb.rpc('register_public_attachment',{p_ticket:ticketId,p_siape:siape,p_path:path,p_name:item.name,p_type:item.file.type,p_size:item.size});if(reg){await sb.storage.from('ticket-attachments').remove([path]);throw reg}}clearPendingAttachments(prefix)
  }
  $('#ticketForm').onsubmit=async e=>{
    e.preventDefault();
    const siape=$('#siape').value.trim(),email=$('#email').value.trim().toLowerCase(),lab=data.labs.find(x=>x.name===$('#lab').value),cat=data.categories.find(x=>x.name===$('#category').value);
    if(!$('#email').readOnly&&!/^[^\s@]+@ifms\.edu\.br$/i.test(email))return toast('Informe um e-mail institucional @ifms.edu.br.');
    const {data:created,error}=await sb.rpc('create_public_ticket',{p_siape:siape,p_email:email,p_lab:lab?.id||null,p_category:cat?.id||null,p_title:cat?.name||'Chamado',p_description:$('#description').value.trim()});
    if(error)return fail(error);
    const row=created?.[0];
    try{await uploadFiles(row.id,siape,'public')}catch(err){fail(err,'Chamado criado, mas houve erro nos anexos.')}
    
    // Disparo imediato via broadcast para todos os técnicos online
    try {
      const alertChannel = sb.channel('labinfo-global-ticket-alerts');
      await alertChannel.send({
        type: 'broadcast',
        event: 'new_ticket',
        payload: {
          id: row.protocol,
          dbId: row.id,
          title: cat?.name || 'Chamado',
          category: cat?.name || 'Geral',
          teacher: $('#teacherIdentity').textContent || `SIAPE ${siape}`,
          teacherSiape: siape,
          lab: lab?.name || 'Não informado',
          description: $('#description').value.trim(),
          time: 'Agora'
        }
      });
    } catch(err) {
      console.warn('Broadcast de alerta de chamado:', err);
    }

    toast('Chamado '+row.protocol+' aberto com sucesso!');
    e.target.reset();
    identify();
  };
  $('#protocolButton').onclick=async()=>{const siape=$('#protocolInput').value.trim(),result=$('#protocolResult');result.innerHTML='<p class="my-tickets-empty">Buscando chamados…</p>';const [{data:who},{data:rows,error}]=await Promise.all([sb.rpc('identify_server',{p_siape:siape}),sb.rpc('my_tickets',{p_siape:siape})]);if(error||(!who?.length&&!rows?.length)){result.innerHTML='<p class="my-tickets-empty error-text">Nenhum chamado encontrado para este SIAPE.</p>';return}const owner=who?.[0]?.full_name||`SIAPE ${safe(siape)} — cadastro pendente`;result.innerHTML=`<div class="my-tickets-owner"><div class="owner-avatar">${safe(owner.charAt(0))}</div><div><span>CHAMADOS DE</span><strong>${safe(owner)}</strong></div><em>${rows.length} chamado(s)</em></div>`+(rows.length?`<div class="my-tickets-list">${rows.map(t=>{const events=t.timeline||[],last=events[events.length-1];return `<article class="my-ticket-card"><header><strong>${safe(t.protocol)}</strong>${badge(t.status)}</header><h3>${safe(t.title)}</h3><div class="my-ticket-meta"><span><i>Local</i>${safe(t.lab||'Não informado')}</span><span><i>Categoria</i>${safe(t.category||'Sem categoria')}</span><span><i>Abertura</i>${fmt(t.created_at)}</span></div><div class="ticket-latest-event"><span>Último andamento</span><strong>${last?.label||'Chamado aberto'}</strong><time>${fmt(last?.at||t.updated_at)}</time></div><button class="ticket-details-toggle" type="button" aria-expanded="false">Ver detalhes</button><div class="public-ticket-timeline" hidden>${events.map(e=>`<div><i></i><span><strong>${safe(e.label)}</strong><time>${fmt(e.at)}</time></span></div>`).join('')}</div></article>`}).join('')}</div>`:'<div class="my-tickets-empty"><strong>Nenhum chamado encontrado</strong></div>');result.querySelectorAll('.ticket-details-toggle').forEach(button=>button.onclick=()=>{const timeline=button.nextElementSibling,open=timeline.hidden;timeline.hidden=!open;button.textContent=open?'Ocultar detalhes':'Ver detalhes';button.setAttribute('aria-expanded',open)})};

  async function getProfile(){const {data:{session}}=await sb.auth.getSession();if(!session)return null;state.session=session;const {data:p,error}=await sb.from('profiles').select('*').eq('id',session.user.id).single();if(error||!p?.active)return null;state.profile=p;return p}
  async function loadAdmin(){
    const [sv,pr,ca,la,ti,at,ta,up]=await Promise.all([sb.from('servers').select('*').order('full_name'),sb.from('profiles').select('*').eq('active',true).order('full_name'),sb.from('categories').select('*').order('name'),sb.from('labs').select('*').order('name'),sb.from('tickets').select('*,servers(*),categories(*),labs(*),primary_assignee:profiles!tickets_assigned_to_fkey(*)').order('created_at',{ascending:false}),sb.from('attachments').select('*'),sb.from('ticket_assignees').select('ticket_id,profile_id,assignee_profile:profiles!ticket_assignees_profile_id_fkey(full_name)'),sb.from('ticket_updates').select('*,profiles(full_name)').order('created_at')]);
    const err=[sv,pr,ca,la,ti,at,ta,up].find(x=>x.error)?.error;if(err)return fail(err);
    replace(data.teachers,sv.data.map(x=>({id:x.id,siape:x.siape,name:x.full_name,email:x.email,active:x.active})));
    replace(data.technicians,pr.data.map(x=>({id:x.id,siape:x.siape,name:x.full_name,email:x.email,role:x.role,active:x.active})));
    replace(data.categories,ca.data.map(x=>({id:x.id,name:x.name,active:x.active})));sortCategories();
    replace(data.labs,la.data.map(x=>({id:x.id,name:x.name,location:x.location,code:x.code,computerCount:x.computer_count||0,operatingSystem:x.operating_system||'',reservationEnabled:x.reservation_enabled===true,active:x.active})));
    const paths=at.data||[],signed={};await Promise.all(paths.map(async a=>{const {data:s}=await sb.storage.from('ticket-attachments').createSignedUrl(a.storage_path,3600);signed[a.id]=s?.signedUrl}));
    replace(tickets,ti.data.map(x=>{const assigned=(ta.data||[]).filter(a=>a.ticket_id===x.id);return {dbId:x.id,id:x.protocol,title:x.title,category:x.categories?.name||'Sem categoria',categoryId:x.category_id,status:x.status,teacher:x.servers?.full_name||`SIAPE ${x.guest_siape} (cadastro pendente)`,teacherSiape:x.servers?.siape||x.guest_siape,teacherEmail:x.servers?.email||x.guest_email,serverId:x.server_id,registrationPending:!x.server_id,lab:x.labs?.name||'Não informado',labId:x.lab_id,time:fmt(x.created_at),createdAt:x.created_at,archivedAt:x.archived_at,technician:assigned.length?assigned.map(a=>a.assignee_profile?.full_name).filter(Boolean).join(', '):(x.status==='Recebido'?'Não atribuído':'Toda a equipe'),technicianIds:assigned.map(a=>a.profile_id),technicianId:x.assigned_to,description:x.description,resolution:x.resolution,closedAt:x.closed_at?fmt(x.closed_at):null,closedAtRaw:x.closed_at,attachments:paths.filter(a=>a.ticket_id===x.id).map(a=>({id:a.id,path:a.storage_path,name:a.file_name,url:signed[a.id]}))}}));
    replace(data.teachers,data.teachers.filter(x=>x.active!==false));
    tickets.forEach(t=>{const raw=ti.data.find(x=>x.id===t.dbId);t.deletedAt=raw?.deleted_at;t.deletedBy=raw?.deleted_by_name||(pr.data||[]).find(profile=>profile.id===raw?.deleted_by)?.full_name||null;t.deletionReason=raw?.deletion_reason;t.serverReplyPending=raw?.server_reply_pending===true;t.lastServerReplyAt=raw?.last_server_reply_at;t.feedbackConfirmedAt=raw?.feedback_confirmed_at||null;t.updates=(up.data||[]).filter(u=>u.ticket_id===t.dbId).map(u=>({message:u.message,kind:u.kind,author:u.kind==='resposta_servidor'?'Servidor':(u.profiles?.full_name||'Equipe técnica'),createdAt:u.created_at}));const closing=[...t.updates].reverse().find(update=>update.kind==='fechamento');t.closedBy=closing?.author||null});
    selected=tickets.find(x=>!x.archivedAt&&!x.deletedAt)||null;options();renderTickets();renderArchivedTickets();renderDetail();refreshMetrics();
  }
  const selectedForArchive=new Set();
  const queueCreate=$('#adminOpenTicket'),queueActions=document.createElement('div');queueActions.className='queue-actions';queueCreate.before(queueActions);queueActions.append(queueCreate);queueActions.insertAdjacentHTML('beforeend','<button id="archiveTickets" class="primary archive-tickets" type="button" disabled>Arquivar selecionados</button>');
  function updateArchiveButton(){const button=$('#archiveTickets');if(!button)return;button.disabled=!selectedForArchive.size;button.textContent=selectedForArchive.size?`Arquivar selecionados (${selectedForArchive.size})`:'Arquivar selecionados'}
  $('#archiveTickets').onclick=async()=>{const ids=[...selectedForArchive];if(!ids.length)return;const files=tickets.filter(t=>ids.includes(t.dbId)).flatMap(t=>t.attachments||[]);if(files.length){const {error:storageError}=await sb.storage.from('ticket-attachments').remove(files.map(x=>x.path));if(storageError)return fail(storageError);const {error:attachmentError}=await sb.from('attachments').delete().in('ticket_id',ids);if(attachmentError)return fail(attachmentError)}const {error}=await sb.from('tickets').update({archived_at:new Date().toISOString(),updated_at:new Date().toISOString()}).in('id',ids);if(error)return fail(error);selectedForArchive.clear();if(selected&&ids.includes(selected.dbId)){selected=null;$('#ticketDetail').classList.remove('detail-expanded');document.body.classList.remove('detail-open')}await loadAdmin();toast(ids.length+' chamado(s) arquivado(s) e anexos removidos.')};
  function refreshMetrics(){const visible=tickets.filter(x=>!x.deletedAt),queue=visible.filter(x=>!x.archivedAt),waiting=queue.filter(x=>x.status==='Recebido').length,active=queue.filter(x=>x.status==='Em atendimento').length,done=visible.filter(x=>x.status==='Concluído').length,closed=visible.filter(x=>x.createdAt&&x.closedAtRaw),avg=closed.length?Math.round(closed.reduce((s,x)=>s+(new Date(x.closedAtRaw)-new Date(x.createdAt))/60000,0)/closed.length):0,articles=document.querySelectorAll('#ticketsSection .metrics article');const values=[[waiting,waiting+' aguardando atribuição na fila'],[active,active+' chamado(s) ativo(s) na fila'],[done,'Em todo o período do sistema'],[closed.length?avg+' min':'—',closed.length?'Média de '+closed.length+' concluído(s)':'Sem chamados concluídos']];articles.forEach((a,i)=>{a.querySelector('strong').textContent=values[i][0];a.querySelector('em').textContent=values[i][1]})}
  function filteredTickets(){const period=$('#analyticsSection .analytics-filters select')?.value||'Últimos 30 dias',days=period==='Hoje'?0:period==='Últimos 7 dias'?7:30,cut=new Date();cut.setHours(0,0,0,0);if(days)cut.setDate(cut.getDate()-days+1);const lab=$('#analyticsLab').value,cat=$('#analyticsCategory').value;return tickets.filter(t=>(!t.createdAt||new Date(t.createdAt)>=cut)&&(lab==='Todos'||t.lab===lab)&&(cat==='Todas'||t.category===cat))}
  const grouped=(rows,key)=>Object.entries(rows.reduce((a,x)=>(a[x[key]||'Não informado']=(a[x[key]||'Não informado']||0)+1,a),{})).sort((a,b)=>b[1]-a[1]);
  function renderRank(id,rows){$(id).innerHTML=rows.length?rows.map(([label,value])=>`<div class="rank-row"><div class="rank-label"><span>${label}</span><strong>${value}</strong></div><div class="rank-track"><i style="width:${value/rows[0][1]*100}%"></i></div></div>`).join(''):'<p class="empty">Sem dados no período.</p>'}
  analytics=function(){const rows=filteredTickets(),hours=Array.from({length:16},(_,i)=>[`${i+7}h`,rows.filter(t=>t.createdAt&&new Date(t.createdAt).getHours()===i+7).length]),max=Math.max(1,...hours.map(x=>x[1])),categories=grouped(rows,'category'),labs=grouped(rows,'lab'),done=rows.filter(x=>x.status==='Concluído').length,peak=hours.reduce((a,b)=>b[1]>a[1]?b:a,['—',0]),serverRows=grouped(rows,'teacher').map(([name,count])=>{const mine=rows.filter(x=>x.teacher===name),top=grouped(mine,'category')[0]?.[0]||'—';return [name,top,count]}),cards=document.querySelectorAll('#analyticsSection .analytics-metrics article');const vals=[[rows.length,'Registros reais'],[rows.length?Math.round(done/rows.length*100)+'%':'0%','Chamados concluídos'],[peak[1]?peak[0]:'—',peak[1]+' abertura(s)'],[labs[0]?.[0]||'—',(labs[0]?.[1]||0)+' ocorrência(s)']];cards.forEach((c,i)=>{c.querySelector('strong').textContent=vals[i][0];c.querySelector('em').textContent=vals[i][1]});$('#hourChart').innerHTML=hours.map(([l,v])=>`<div class="bar-column"><small>${v}</small><i style="height:${v/max*85}%"></i><strong>${l}</strong></div>`).join('');renderRank('#categoryChart',categories);renderRank('#labChart',labs);$('#teacherChart').innerHTML='<div><span>Servidor</span><span>Principal categoria</span><span>Chamados</span></div>'+serverRows.map(x=>`<div><strong>${x[0]}</strong><span>${x[1]}</span><strong>${x[2]}</strong></div>`).join('')+(serverRows.length?'':'<p class="empty">Sem dados no período.</p>')};
  $('#applyAnalytics').onclick=analytics;
  async function enterAdmin(){
    const p=await getProfile();
    if(!p){openLogin();return}
    await loadAdmin();
    $('#adminView').hidden=false;
    $('#teacherView').hidden=true;
    $('#homeView').hidden=true;
    $('#reservationsPublicView').hidden=true;
    const cp=$('#chatPublicView');if(cp)cp.hidden=true;
    $('#adminToggle').textContent='Sair';
    $('#adminToggle').hidden=true;
    $('#accountName').textContent=p.full_name;
    $('#accountMenuName').textContent=p.full_name;
    $('#accountEmail').textContent=p.email;
    $('#accountRole').textContent=p.role==='supervisor'?'Supervisor':'Técnico';
    $('#accountAvatar').textContent=p.full_name.trim().split(/\s+/).slice(0,2).map(x=>x[0]).join('').toUpperCase();
    const menuButtons=document.querySelectorAll('.topbar-admin-actions [data-admin-nav]');
    menuButtons.forEach(b=>b.hidden=false);
    if(p.role==='supervisor'){
      menuButtons.forEach(b=>b.hidden=b.dataset.section!=='supervisor'&&b.id!=='reservationsMenuButton');
      openAdminRoute(adminRouteSlug==='reservas'?'reservas':'supervisor');
    }else{
      openAdminRoute(adminRouteSlug||'chamados');
    }
    await initStaffChatStatus();
    listenIncomingChats();
    startAdminSynchronization();
    window.scrollTo(0,0);
  }
  $('#adminToggle').onclick=async()=>{if(state.profile&&!$('#adminView').hidden){await performLogout();return}document.body.classList.add('admin-route');$('#homeView').hidden=true;$('#teacherView').hidden=true;$('#reservationsPublicView').hidden=true;const cp=$('#chatPublicView');if(cp)cp.hidden=true;history.pushState({},'',sitePath('admin'));await enterAdmin()};

  // ------------------------------------------------------------------------
  // PADRAO: cadeia de decoradores de renderDetail (achado P2 3.1 da auditoria
  // de 26/08/2026).
  //
  // A partir daqui, `renderDetail` e redefinida varias vezes neste arquivo,
  // cada vez capturando a versao anterior (`const anterior = renderDetail`) e
  // chamando-a no inicio do novo corpo antes de acrescentar comportamento.
  // Isso e intencional (cada camada foi adicionada quando uma funcionalidade
  // nova precisou complementar a tela de detalhe do chamado) e todas as
  // camadas abaixo estao ativas -- ao contrario de `renderTickets`/
  // `supervisor` (ver comentario correspondente mais abaixo), aqui nao ha
  // nenhuma reatribuicao "plana" que descarte as anteriores.
  //
  // Ordem de execucao (a base do app.js roda primeiro, sempre):
  //   1. app.js `renderDetail`  -- versao demo/fallback (ver banner no topo de app.js)
  //   2. aqui                   -- estado vazio + atribuicao de tecnico(s) responsavel(is)
  //   3. mais abaixo (~150 linhas) -- botao de voltar (mobile) + reply/fechamento simplificados
  //   4. em seguida             -- historico de mensagens e alerta de resposta do servidor
  //   5. em seguida             -- fechamento definitivo do chamado (fluxo real usado em producao)
  //   6. em seguida             -- autor e data de quem fechou o chamado
  //   7. mais abaixo (~250 linhas) -- atribuicao confiavel de tecnico com atualizacao otimista de estado
  //   8. em seguida             -- aviso de "atendimento confirmado pelo servidor"
  //   9. em seguida             -- recolhimento (clamp) confiavel de mensagens longas do historico
  //  10. bem mais abaixo (~1500 linhas) -- editor de categoria/laboratorio para chamados vindos por e-mail
  //
  // Ao alterar o comportamento da tela de detalhe, edite a camada
  // correspondente ao que voce quer mudar; para adicionar algo novo, prefira
  // criar mais uma camada seguindo o mesmo padrao a reescrever as anteriores.
  // Uma reescrita completa em uma funcao unica foi avaliada nesta auditoria e
  // adiada deliberadamente: o risco de regressao em producao (sem ambiente de
  // teste/homologacao disponivel) superou o ganho de legibilidade.
  // ------------------------------------------------------------------------
  const originalDetail=renderDetail;
  renderDetail=function(){if(!selected){$('#ticketDetail').innerHTML='<div class="empty-state-detail"><strong>Nenhum chamado selecionado</strong><p>Os chamados reais aparecerão aqui assim que forem registrados.</p></div>';return}originalDetail();if(!state.profile||state.profile.role==='supervisor')return;const technicianSelect=$('#technician');if(technicianSelect){const label=technicianSelect.closest('label');label.childNodes[0].textContent='Técnicos responsáveis';technicianSelect.hidden=true;technicianSelect.required=false;technicianSelect.insertAdjacentHTML('afterend',`<div id="assigneeChoices" class="multi-assignee"><label class="team-option"><input type="checkbox" value="__all__" ${selected.technician==='Toda a equipe'?'checked':''}>Toda a equipe</label>${data.technicians.filter(x=>x.role==='tecnico'&&x.active!==false).map(x=>`<label><input type="checkbox" value="${x.id}" ${(selected.technicianIds||[]).includes(x.id)?'checked':''}>${x.name}</label>`).join('')}</div>`);const choices=$('#assigneeChoices');choices.onchange=e=>{const all=choices.querySelector('[value="__all__"]'),individuals=[...choices.querySelectorAll('input:not([value="__all__"])')];if(e.target===all&&all.checked)individuals.forEach(x=>x.checked=false);else if(e.target!==all&&e.target.checked)all.checked=false}}const assign=$('#assign'),send=$('#sendReply'),close=$('#closeTicket');if(assign)assign.onclick=async()=>{const checked=[...$('#assigneeChoices').querySelectorAll('input:checked')].map(x=>x.value),collective=checked.includes('__all__'),ids=checked.filter(x=>x!=='__all__');if(!collective&&!ids.length)return toast('Selecione ao menos um técnico ou toda a equipe.');const primary=ids[0]||null,{error}=await sb.from('tickets').update({assigned_to:primary,status:'Em atendimento',started_at:new Date().toISOString(),updated_at:new Date().toISOString()}).eq('id',selected.dbId);if(error)return fail(error);const removed=await sb.from('ticket_assignees').delete().eq('ticket_id',selected.dbId);if(removed.error)return fail(removed.error);if(ids.length){const inserted=await sb.from('ticket_assignees').insert(ids.map(id=>({ticket_id:selected.dbId,profile_id:id,assigned_by:state.profile.id})));if(inserted.error)return fail(inserted.error)}const names=collective?'Toda a equipe':data.technicians.filter(x=>ids.includes(x.id)).map(x=>x.name).join(', ');await sb.from('ticket_updates').insert({ticket_id:selected.dbId,author_id:state.profile.id,message:'Atendimento atribuído a '+names,kind:'status'});await loadAdmin();toast('Responsáveis atualizados: '+names)};if(send)send.onclick=async()=>{const msg=$('#reply').value.trim();if(!msg)return toast('Digite uma atualização.');const {error}=await sb.from('ticket_updates').insert({ticket_id:selected.dbId,author_id:state.profile.id,message:msg});if(error)return fail(error);toast('Atualização registrada.')};if(close)close.onclick=async()=>{const msg=$('#reply').value.trim();if(!msg)return toast('Descreva a solução.');if(selected.attachments?.length){const {error:se}=await sb.storage.from('ticket-attachments').remove(selected.attachments.map(x=>x.path));if(se)return fail(se);await sb.from('attachments').delete().eq('ticket_id',selected.dbId)}const {error}=await sb.from('tickets').update({status:'Concluído',resolution:msg,closed_at:new Date().toISOString(),updated_at:new Date().toISOString()}).eq('id',selected.dbId);if(error)return fail(error);await sb.from('ticket_updates').insert({ticket_id:selected.dbId,author_id:state.profile.id,message:msg,kind:'fechamento'});await loadAdmin();toast('Chamado concluído e anexos removidos.')}};

  const adminForm=$('#adminTicketForm');adminForm.onsubmit=async e=>{e.preventDefault();const server=data.teachers.find(x=>x.siape===$('#adminTeacher').value),lab=data.labs.find(x=>x.name===$('#adminLab').value),cat=data.categories.find(x=>x.name===$('#adminCategory').value);const protocol=await sb.rpc('next_protocol',{p_lab:lab?.id||null});if(protocol.error)return fail(protocol.error);const {data:row,error}=await sb.from('tickets').insert({protocol:protocol.data,server_id:server.id,lab_id:lab?.id,category_id:cat?.id,title:$('#adminTicketSubject').value.trim(),description:$('#adminTicketDescription').value.trim(),source:'Tecnico'}).select().single();if(error)return fail(error);try{await uploadFiles(row.id,server.siape,'admin')}catch(err){fail(err)}adminForm.reset();$('#adminTicketModal').hidden=true;document.body.classList.remove('modal-open');await loadAdmin();toast('Chamado '+row.protocol+' criado.')};

  $('.registration-tabs').insertAdjacentHTML('afterend','<section id="serverCsvImport" class="card csv-import"><div><span class="eyebrow">CADASTRO EM LOTE</span><h2>Importar servidores por CSV</h2><p>Envie um arquivo com as colunas SIAPE, NOME COMPLETO e E-MAIL.</p></div><div class="csv-actions"><button id="downloadServerCsv" class="secondary" type="button">Baixar modelo</button><label class="secondary csv-file-button">Selecionar CSV<input id="serverCsvFile" type="file" accept=".csv,text/csv" hidden></label></div><div id="serverCsvPreview" class="csv-preview" hidden></div></section>');
  let csvServerRows=[];
  const csvEsc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const headerKey=v=>String(v||'').replace(/^\uFEFF/,'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase().replace(/[^a-z0-9]/g,'');
  function parseCsv(text){const first=(text.split(/\r?\n/,1)[0]||''),delimiter=(first.match(/;/g)||[]).length>(first.match(/,/g)||[]).length?';':',';let rows=[],row=[],value='',quoted=false;for(let i=0;i<text.length;i++){const c=text[i];if(c==='"'){if(quoted&&text[i+1]==='"'){value+='"';i++}else quoted=!quoted}else if(c===delimiter&&!quoted){row.push(value.trim());value=''}else if((c==='\n'||c==='\r')&&!quoted){if(c==='\r'&&text[i+1]==='\n')i++;row.push(value.trim());if(row.some(Boolean))rows.push(row);row=[];value=''}else value+=c}row.push(value.trim());if(row.some(Boolean))rows.push(row);return rows}
  function prepareServerCsv(text){const parsed=parseCsv(text);if(parsed.length<2)throw new Error('O CSV não contém registros para importar.');const headers=parsed[0].map(headerKey),indexes={siape:headers.indexOf('siape'),name:headers.findIndex(x=>['nome','nomecompleto'].includes(x)),email:headers.findIndex(x=>['email','emailinstitucional'].includes(x))};if(Object.values(indexes).some(x=>x<0))throw new Error('Use os cabeçalhos SIAPE, NOME COMPLETO e E-MAIL.');const seenSiape=new Set(),seenEmail=new Set(),existingEmail=new Map(data.teachers.map(x=>[x.email.toLowerCase(),x.siape]));return parsed.slice(1).map((cols,i)=>{const siape=(cols[indexes.siape]||'').replace(/\D/g,''),name=(cols[indexes.name]||'').replace(/\s+/g,' ').trim(),email=(cols[indexes.email]||'').trim().toLowerCase(),errors=[];if(!/^\d{5,12}$/.test(siape))errors.push('SIAPE inválido');if(name.length<3)errors.push('nome incompleto');if(!/^[^\s@]+@ifms\.edu\.br$/i.test(email))errors.push('e-mail institucional inválido');if(seenSiape.has(siape))errors.push('SIAPE repetido no arquivo');if(seenEmail.has(email))errors.push('e-mail repetido no arquivo');const owner=existingEmail.get(email);if(owner&&owner!==siape)errors.push('e-mail já pertence a outro SIAPE');seenSiape.add(siape);seenEmail.add(email);return {line:i+2,siape,name,email,errors,update:data.teachers.some(x=>x.siape===siape)}})}
  function renderServerCsv(){const box=$('#serverCsvPreview'),valid=csvServerRows.filter(x=>!x.errors.length),invalid=csvServerRows.filter(x=>x.errors.length),updates=valid.filter(x=>x.update).length;box.hidden=false;box.innerHTML=`<div class="csv-summary"><span>${valid.length} válido(s)</span><span>${valid.length-updates} novo(s)</span><span>${updates} atualização(ões)</span>${invalid.length?`<span class="csv-error-count">${invalid.length} com erro</span>`:''}</div><div class="csv-table-wrap"><table class="csv-table"><thead><tr><th>Linha</th><th>SIAPE</th><th>Nome completo</th><th>E-mail</th><th>Situação</th></tr></thead><tbody>${csvServerRows.map(x=>`<tr class="${x.errors.length?'csv-row-error':''}"><td>${x.line}</td><td>${csvEsc(x.siape)}</td><td>${csvEsc(x.name)}</td><td>${csvEsc(x.email)}</td><td>${x.errors.length?csvEsc(x.errors.join('; ')):(x.update?'Atualizar':'Cadastrar')}</td></tr>`).join('')}</tbody></table></div><p class="csv-help">Linhas com erro não serão importadas. Cadastros com o mesmo SIAPE serão atualizados.</p><button id="importServerCsv" class="primary csv-import-button" type="button" ${valid.length?'':'disabled'}>Importar ${valid.length} servidor(es)</button>`;$('#importServerCsv').onclick=importServerCsv}
  async function importServerCsv(){const valid=csvServerRows.filter(x=>!x.errors.length),button=$('#importServerCsv');if(!valid.length)return;button.disabled=true;button.textContent='Importando…';const payload=valid.map(x=>({siape:x.siape,full_name:x.name,email:x.email,active:true})),{error}=await sb.from('servers').upsert(payload,{onConflict:'siape'});if(error){button.disabled=false;button.textContent='Tentar novamente';return fail(error,'Não foi possível importar os servidores.')}const count=valid.length;csvServerRows=[];$('#serverCsvFile').value='';$('#serverCsvPreview').hidden=true;await loadAdmin();registration();toast(count+' servidor(es) importado(s) com sucesso.')}
  $('#downloadServerCsv').onclick=()=>{const blob=new Blob(['SIAPE;NOME COMPLETO;E-MAIL\r\n1234567;Nome do Servidor;nome.sobrenome@ifms.edu.br\r\n'],{type:'text/csv;charset=utf-8'}),url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download='modelo-importacao-servidores.csv';a.click();URL.revokeObjectURL(url)};
  $('#serverCsvFile').onchange=async e=>{const file=e.target.files[0];if(!file)return;if(file.size>2*1024*1024){e.target.value='';return toast('O CSV deve ter no máximo 2 MB.')}try{csvServerRows=prepareServerCsv(await file.text());renderServerCsv()}catch(error){csvServerRows=[];$('#serverCsvPreview').hidden=true;toast(error.message)}};
  document.querySelectorAll('[data-reg]').forEach(button=>button.addEventListener('click',()=>{$('#serverCsvImport').hidden=button.dataset.reg!=='teachers'}));

  async function saveRegistration(e){e.preventDefault();const entry=Object.fromEntries(new FormData(e.target));let error,reactivatedEmail='';if(regType==='teachers')({error}=await sb.from('servers').insert({siape:entry.siape,full_name:entry.name,email:entry.email}));else if(regType==='categories')({error}=await sb.from('categories').insert({name:entry.name}));else if(regType==='labs')({error}=await sb.from('labs').insert({name:entry.name,location:entry.location,code:entry.code||null,operating_system:entry.operating_system||null}));else {const role=entry.role||'tecnico',email=entry.email.trim().toLowerCase(),siape=entry.siape.trim(),{data:matches,error:lookupError}=await sb.from('profiles').select('id,email,siape,active').or(`email.eq.${email},siape.eq.${siape}`);if(lookupError)error=lookupError;else {const bySiape=matches?.find(x=>x.siape===siape),byEmail=matches?.find(x=>x.email.toLowerCase()===email);if(bySiape){if(bySiape.active)error=new Error('Este SIAPE já pertence a um usuário ativo.');else {({error}=await sb.from('profiles').update({full_name:entry.name,role,active:true}).eq('id',bySiape.id));if(!error)reactivatedEmail=bySiape.email}}else if(byEmail){if(byEmail.active)error=new Error('Este e-mail já pertence a um usuário ativo.');else {({error}=await sb.from('profiles').update({full_name:entry.name,role,active:true}).eq('id',byEmail.id));if(!error)reactivatedEmail=byEmail.email}}else {const response=await sb.functions.invoke('create-staff',{body:{siape,full_name:entry.name,email,password:entry.password,role}});if(response.error){let message=response.error.message;try{const body=await response.error.context?.json();message=body?.error||message}catch{}error=new Error(message)}else if(!response.data?.ok)error=new Error(response.data?.error||'Não foi possível cadastrar o usuário.')}}}if(error)return fail(error);e.target.reset();await loadAdmin();registration();toast(reactivatedEmail?'Usuário reativado. Login mantido: '+reactivatedEmail:'Cadastro salvo.')}
  $('#registrationForm').onsubmit=saveRegistration;
  document.body.insertAdjacentHTML('beforeend','<div id="staffEmailModal" class="modal-backdrop" hidden><div class="card login-card"><div class="modal-heading"><div><span class="eyebrow">LOGIN DO USUÁRIO</span><h2>Alterar e-mail</h2><p id="staffEmailIdentity"></p></div><button id="closeStaffEmail" class="modal-close" type="button">×</button></div><form id="staffEmailForm"><input id="staffEmailUserId" type="hidden"><label>Novo e-mail institucional<input id="staffNewEmail" type="email" placeholder="nome@ifms.edu.br" required></label><p id="staffEmailError" class="login-error"></p><button class="primary" type="submit">Atualizar e-mail de login</button></form></div></div>');
  const staffEmailModal=$('#staffEmailModal'),closeStaffEmail=()=>{staffEmailModal.hidden=true;document.body.classList.remove('modal-open');$('#staffEmailForm').reset();$('#staffEmailError').textContent=''};$('#closeStaffEmail').onclick=closeStaffEmail;staffEmailModal.onclick=e=>{if(e.target===staffEmailModal)closeStaffEmail()};
  $('#staffEmailForm').onsubmit=async e=>{e.preventDefault();const email=$('#staffNewEmail').value.trim().toLowerCase(),errorBox=$('#staffEmailError');errorBox.textContent='';setProcessing(true,'Atualizando usuário…');try{if(!/^[^\s@]+@ifms\.edu\.br$/i.test(email)){errorBox.textContent='Informe um e-mail institucional @ifms.edu.br.';return}const response=await sb.functions.invoke('create-staff',{body:{action:'update-email',user_id:$('#staffEmailUserId').value,email}});if(response.error||!response.data?.ok){let message=response.data?.error||response.error?.message||'Não foi possível alterar o e-mail.';try{const body=await response.error?.context?.json();message=body?.error||message}catch{}errorBox.textContent=message;return}closeStaffEmail();await loadAdmin();registration();toast('E-mail de login atualizado com sucesso.')}catch(error){errorBox.textContent=error?.message||'Não foi possível alterar o e-mail.'}finally{setProcessing(false)}};
  const originalRegistration=registration;registration=function(){originalRegistration();if(regType==='technicians')$('#registrationFields').insertAdjacentHTML('beforeend','<input name="staff_user_id" type="hidden"><label>Perfil<select name="role"><option value="tecnico">Técnico</option><option value="supervisor">Supervisor</option></select></label><label id="staffPasswordLabel">Senha inicial<input name="password" type="password" minlength="8" required></label><button id="cancelStaffEdit" class="secondary cancel-staff-edit" type="button" hidden>Cancelar edição</button>');if(regType==='labs')$('#registrationFields').insertAdjacentHTML('beforeend','<input name="lab_id" type="hidden"><label>Código do protocolo<input name="code" placeholder="Ex.: LAB05"></label><label>Quantidade de computadores<input name="computer_count" type="number" min="0" step="1" value="0" required></label><label>Sistema operacional<input name="operating_system" placeholder="Ex.: Windows 11 Pro / Ubuntu 24.04 (Dual Boot)" maxlength="80"></label><label class="lab-reservation-option"><input name="reservation_enabled" type="checkbox" value="true"><span><strong>Disponível para reservas</strong><small>Exibir este laboratório na agenda e nos formulários públicos de reserva. Desmarcado, ele continuará disponível para chamados.</small></span></label><button id="cancelLabEdit" class="secondary cancel-lab-edit" type="button" hidden>Cancelar edição</button>');$('#registrationForm').onsubmit=saveRegistration};
  const saveRegistrationBase=saveRegistration;saveRegistration=async function(event){await saveRegistrationBase(event);await new Promise(resolve=>setTimeout(resolve,400));await loadAdmin();registration();setProcessing(false)};$('#registrationForm').onsubmit=saveRegistration;
  document.addEventListener('submit',event=>{if(event.target.matches('#registrationForm'))setProcessing(true,'Salvando cadastro…')});
  document.addEventListener('click',event=>{if(event.target.closest('.delete-button'))setProcessing(true,'Desativando cadastro…');if(event.target.closest('#importServerCsv'))setProcessing(true,'Importando servidores…')});
  document.addEventListener('submit',async event=>{
    if(!event.target.matches('#registrationForm')||regType!=='labs')return;
    event.preventDefault();event.stopImmediatePropagation();setProcessing(true,'Salvando laboratório…');
    const form=event.target,entry=Object.fromEntries(new FormData(form)),code=String(entry.code||'').trim().toUpperCase();
    const payload={name:String(entry.name).trim(),location:String(entry.location||'').trim(),code:code||null,computer_count:Math.max(0,Number(entry.computer_count)||0),operating_system:String(entry.operating_system||'').trim()||null,reservation_enabled:entry.reservation_enabled==='true',active:true};
    const result=entry.lab_id?await sb.from('labs').update(payload).eq('id',entry.lab_id).select().single():await sb.from('labs').upsert(payload,{onConflict:code?'code':'name'}).select().single();
    if(result.error)return fail(result.error,'Não foi possível salvar o laboratório.');
    form.reset();await loadAdmin();registration();toast(payload.reservation_enabled?'Laboratório salvo e disponibilizado para chamados e reservas.':'Laboratório salvo e disponibilizado somente para chamados.');
  },true);
  document.addEventListener('submit',async event=>{
    if(!event.target.matches('#registrationForm')||regType!=='technicians')return;
    event.preventDefault();event.stopImmediatePropagation();setProcessing(true,'Salvando dados do usuário…');
    const form=event.target,entry=Object.fromEntries(new FormData(form)),isEdit=Boolean(entry.staff_user_id);
    try {
      if(isEdit){
        const {error:rpcErr}=await sb.rpc('update_staff_profile',{
          p_user_id:entry.staff_user_id,
          p_full_name:entry.name.trim(),
          p_siape:entry.siape.trim(),
          p_role:entry.role||'tecnico',
          p_new_password:entry.password?.trim()||null
        });
        if(rpcErr){
          const {error:dirErr}=await sb.from('profiles').update({
            full_name:entry.name.trim(),
            siape:entry.siape.trim(),
            role:entry.role||'tecnico',
            active:true
          }).eq('id',entry.staff_user_id);
          if(dirErr)throw dirErr;
        }
        form.reset();await loadAdmin();registration();toast('Cadastro de '+entry.name.trim()+' atualizado com sucesso.');
      } else {
        const role=entry.role||'tecnico',email=entry.email.trim().toLowerCase(),siape=entry.siape.trim();
        const response=await sb.functions.invoke('create-staff',{body:{siape,full_name:entry.name.trim(),email,password:entry.password,role}});
        if(response.error||!response.data?.ok){
          let message=response.data?.error||response.error?.message||'Não foi possível cadastrar o usuário.';
          try{const body=await response.error?.context?.json();if(body?.error)message=body.error}catch{}
          throw new Error(message);
        }
        form.reset();await loadAdmin();registration();toast('Técnico '+entry.name.trim()+' cadastrado com sucesso.');
      }
    } catch(err){
      fail(err,'Não foi possível salvar os dados do técnico.');
    } finally {
      setProcessing(false);
    }
  },true);
  document.addEventListener('submit',async event=>{
    if(!event.target.matches('#registrationForm')||regType!=='categories')return;
    event.preventDefault();event.stopImmediatePropagation();setProcessing(true,'Salvando categoria…');
    const form=event.target,entry=Object.fromEntries(new FormData(form)),name=String(entry.name||'').trim();
    const result=await sb.from('categories').upsert({name,active:true},{onConflict:'name'}).select().single();
    if(result.error)return fail(result.error,'Não foi possível salvar a categoria.');
    form.reset();await loadAdmin();registration();toast('Categoria salva e disponibilizada no sistema.');
  },true);
  const registryHead=$('.registry-head');registryHead.insertAdjacentHTML('beforeend','<button id="deleteAllRegistry" class="delete-all-registry" type="button">Apagar todos</button>');
  $('#deleteAllRegistry').onclick=async()=>{const labels={teachers:'servidores',technicians:'técnicos e supervisores',categories:'categorias',labs:'laboratórios'},tables={teachers:'servers',technicians:'profiles',categories:'categories',labs:'labs'},active=data[regType].filter(x=>x.active!==false);if(!active.length)return toast('Não há cadastros ativos para apagar.');const typed=prompt(`Esta ação retirará ${active.length} ${labels[regType]} das seleções do sistema. Registros ligados ao histórico serão preservados como inativos.\n\nDigite APAGAR para confirmar:`);if(typed!=='APAGAR')return;let query=sb.from(tables[regType]).update({active:false}).eq('active',true);if(regType==='technicians')query=query.neq('id',state.profile.id);const {error}=await query;if(error)return fail(error);await loadAdmin();registration();toast(regType==='technicians'?'Todos os demais usuários foram desativados. Seu acesso foi preservado.':'Todos os cadastros deste grupo foram removidos das seleções.')};

  registry=async function(){
    const q=$('#registrySearch').value.toLowerCase(),rows=data[regType].filter(x=>x.active!==false&&Object.values(x).join(' ').toLowerCase().includes(q));
    $('#registryCount').textContent=rows.length+' registro(s)';
    $('#registryList').innerHTML=rows.map(x=>`<div class="registry-row"><div><strong>${safe(x.name)}</strong><span>${x.siape?'SIAPE '+safe(x.siape)+' • '+safe(x.email)+(x.role?' • '+(x.role==='supervisor'?'Supervisor':'Técnico'):''):(safe(x.location)||'Disponível no formulário público')+(regType==='labs'?` • ${Number(x.computerCount)||0} computador(es)${x.operatingSystem?' • SO: '+safe(x.operatingSystem):''} • ${x.reservationEnabled?'Reservas públicas':'Somente chamados'}`:``)}</span></div><div class="registry-actions">${regType==='labs'?`<button class="edit-lab-button secondary" type="button" data-id="${x.id}">Editar</button>`:''}${regType==='technicians'?`<button class="edit-staff-button secondary" type="button" data-id="${x.id}">Editar</button>`:''}${regType==='technicians'?`<button class="edit-email-button secondary" type="button" data-id="${x.id}">Alterar e-mail</button>`:''}<button class="delete-button" data-id="${x.id}">Desativar</button></div></div>`).join('')||'<p class="empty">Nenhum cadastro encontrado.</p>';
    document.querySelectorAll('.edit-lab-button').forEach(button=>button.onclick=()=>{
      const lab=data.labs.find(item=>item.id===button.dataset.id),form=$('#registrationForm');
      if(!lab||!form)return;
      form.elements.lab_id.value=lab.id;
      form.elements.name.value=lab.name||'';
      form.elements.location.value=lab.location||'';
      form.elements.code.value=lab.code||'';
      form.elements.computer_count.value=Number(lab.computerCount)||0;
      form.elements.operating_system.value=lab.operatingSystem||'';
      form.elements.reservation_enabled.checked=lab.reservationEnabled===true;
      $('#registrationTitle').textContent='Editar laboratório';
      $('#registrationHelp').textContent='Atualize as informações exibidas no suporte e na agenda pública.';
      $('#cancelLabEdit').hidden=false;
      form.querySelector('[type="submit"]').textContent='Salvar alterações';
      form.scrollIntoView({behavior:'smooth',block:'start'});
      form.elements.name.focus();
    });
    const cancelLabEdit=$('#cancelLabEdit');if(cancelLabEdit)cancelLabEdit.onclick=()=>{registration();registry()};
    document.querySelectorAll('.edit-staff-button').forEach(button=>button.onclick=()=>{
      const user=data.technicians.find(item=>item.id===button.dataset.id),form=$('#registrationForm');
      if(!user||!form)return;
      form.elements.staff_user_id.value=user.id;
      form.elements.name.value=user.name||'';
      form.elements.siape.value=user.siape||'';
      form.elements.email.value=user.email||'';
      form.elements.email.readOnly=true;
      form.elements.role.value=user.role||'tecnico';
      form.elements.password.value='';
      form.elements.password.required=false;
      form.elements.password.placeholder='Deixe em branco para manter a senha atual';
      const passLabel=$('#staffPasswordLabel');
      if(passLabel)passLabel.childNodes[0].textContent='Nova senha (opcional)';
      $('#registrationTitle').textContent='Editar '+(user.role==='supervisor'?'supervisor':'técnico');
      $('#registrationHelp').textContent='Altere nome, SIAPE, perfil de acesso ou redefina a senha.';
      $('#cancelStaffEdit').hidden=false;
      form.querySelector('[type="submit"]').textContent='Salvar alterações';
      form.scrollIntoView({behavior:'smooth',block:'start'});
      form.elements.name.focus();
    });
    const cancelStaffEdit=$('#cancelStaffEdit');if(cancelStaffEdit)cancelStaffEdit.onclick=()=>{registration();registry()};
    document.querySelectorAll('.edit-email-button').forEach(b=>b.onclick=()=>{const user=data.technicians.find(x=>x.id===b.dataset.id);if(!user)return;$('#staffEmailUserId').value=user.id;$('#staffNewEmail').value=user.email;$('#staffEmailIdentity').textContent=user.name+' • SIAPE '+user.siape;staffEmailModal.hidden=false;document.body.classList.add('modal-open');$('#staffNewEmail').focus()});
    document.querySelectorAll('.delete-button').forEach(b=>b.onclick=async()=>{
      const tables={teachers:'servers',technicians:'profiles',categories:'categories',labs:'labs'},table=tables[regType];
      const {error}=await sb.from(table).update({active:false}).eq('id',b.dataset.id);
      if(error)return fail(error);
      await loadAdmin();registration();toast('Cadastro desativado.');
    });
  };

  const adminTeacherSelect=$('#adminTeacher');adminTeacherSelect.insertAdjacentHTML('beforebegin','<input id="adminTeacherSearch" type="search" autocomplete="off" placeholder="Digite o nome ou SIAPE para buscar..." aria-label="Buscar servidor">');
  const normalizeSearch=value=>String(value||'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase().trim();
  function filterAdminTeachers(){const query=normalizeSearch($('#adminTeacherSearch').value),current=adminTeacherSelect.value,rows=data.teachers.filter(x=>x.active!==false&&(!query||normalizeSearch(x.name).split(/\s+/).some(part=>part.startsWith(query))||x.siape.startsWith(query)));adminTeacherSelect.innerHTML='<option value="">'+(rows.length?'Selecione o servidor':'Nenhum servidor encontrado')+'</option>'+rows.map(x=>`<option value="${x.siape}">${x.name} — SIAPE ${x.siape}</option>`).join('');if(rows.some(x=>x.siape===current))adminTeacherSelect.value=current;else if(rows.length===1)adminTeacherSelect.value=rows[0].siape;adminTeacherSelect.dispatchEvent(new Event('change'))}
  function syncAdminTicketReferences(){
    const categories=data.categories.filter(item=>item.active!==false),labs=data.labs.filter(item=>item.active!==false);
    $('#adminCategory').innerHTML='<option value="">Selecione</option>'+categories.map(item=>`<option value="${safe(item.name)}">${safe(item.name)}</option>`).join('');
    $('#adminLab').innerHTML='<option value="">Selecione</option>'+labs.map(item=>`<option value="${safe(item.name)}">${safe(item.name)}</option>`).join('');
  }
  $('#adminTeacherSearch').oninput=filterAdminTeachers;$('#adminOpenTicket').addEventListener('click',()=>{$('#adminTeacherSearch').value='';filterAdminTeachers();syncAdminTicketReferences();setTimeout(()=>$('#adminTeacherSearch').focus(),0)});
  const expandedDetailRender=renderDetail;renderDetail=function(){expandedDetailRender();if(!selected)return;$('#ticketDetail').querySelector('.detail-close')?.remove();$('#ticketDetail').insertAdjacentHTML('afterbegin','<button class="detail-close" type="button" aria-label="Voltar para a fila">←</button>');$('.detail-close').onclick=()=>{$('#ticketDetail').classList.remove('detail-expanded');document.body.classList.remove('detail-open')};const reply=$('#reply'),send=$('#sendReply');if(reply)reply.closest('label').hidden=true;if(send){send.textContent='Enviar atualização';send.onclick=()=>{const label=reply.closest('label');if(label.hidden){label.hidden=false;send.textContent='Registrar e enviar atualização';reply.focus();return}const msg=reply.value.trim();if(!msg)return toast('Digite a atualização antes de enviar.');sb.from('ticket_updates').insert({ticket_id:selected.dbId,author_id:state.profile.id,message:msg}).then(async({error})=>{if(error)return fail(error);reply.value='';label.hidden=true;send.textContent='Enviar atualização';toast('Atualização registrada para envio ao servidor.')})}}};
  const detailWithMessages=renderDetail;renderDetail=function(){detailWithMessages();if(!selected)return;if(selected.serverReplyPending)$('#ticketDetail .detail-top')?.insertAdjacentHTML('afterend','<div class="server-reply-alert"><strong>! Nova resposta do servidor</strong><span>Verifique o histórico de mensagens abaixo.</span></div>');const history=(selected.updates||[]).filter(u=>['atualizacao','resposta_servidor'].includes(u.kind));if(!history.length)return;const anchor=$('#ticketDetail .detail-actions')||$('#ticketDetail .resolution-box');anchor?.insertAdjacentHTML('beforebegin',`<section class="ticket-history"><h3>Histórico de mensagens</h3>${history.map(u=>`<article class="${u.kind==='resposta_servidor'?'server-reply':'staff-update'}"><header><strong>${safe(u.author)}</strong><time>${fmt(u.createdAt)}</time></header><p class="history-message collapsed">${safe(u.message)}</p><button class="history-toggle" type="button" aria-expanded="false">Ver tudo</button></article>`).join('')}</section>`);$('#ticketDetail').querySelectorAll('.ticket-history article').forEach(card=>{const message=card.querySelector('.history-message'),toggle=card.querySelector('.history-toggle');if(message.scrollHeight<=message.clientHeight+2){toggle.hidden=true;message.classList.remove('collapsed');return}toggle.onclick=()=>{const expanding=message.classList.contains('collapsed');message.classList.toggle('collapsed',!expanding);toggle.textContent=expanding?'Recolher':'Ver tudo';toggle.setAttribute('aria-expanded',expanding)}})};
  const detailWithReliableClose=renderDetail;renderDetail=function(){detailWithReliableClose();const close=$('#closeTicket');if(!close||!selected||state.profile?.role!=='tecnico')return;close.onclick=async()=>{if(close.disabled)return;const reply=$('#reply'),label=reply?.closest('label');if(label?.hidden){label.hidden=false;label.childNodes[0].textContent='Solução realizada (será enviada ao servidor)';close.textContent='Confirmar conclusão e enviar';reply.placeholder='Descreva objetivamente o que foi realizado e testado...';reply.focus();return toast('Registre a solução antes de concluir o chamado.')}const resolution=reply?.value.trim()||'';if(resolution.length<5){reply?.focus();return toast('Descreva a solução realizada com pelo menos 5 caracteres.')}close.disabled=true;close.textContent='Concluindo…';const ticket=selected,closedAt=new Date().toISOString(),{error}=await sb.from('tickets').update({status:'Concluído',resolution,closed_at:closedAt,server_reply_pending:false,updated_at:closedAt}).eq('id',ticket.dbId);if(error){close.disabled=false;close.textContent='Confirmar conclusão e enviar';return fail(error,'Não foi possível concluir o chamado.')}const updateResult=await sb.from('ticket_updates').insert({ticket_id:ticket.dbId,author_id:state.profile.id,message:resolution,kind:'fechamento'});if(updateResult.error)console.error('Falha ao registrar histórico de fechamento',updateResult.error);let cleanupFailed=false;if(ticket.attachments?.length){const storageResult=await sb.storage.from('ticket-attachments').remove(ticket.attachments.map(item=>item.path));if(storageResult.error){cleanupFailed=true;console.error('Falha ao remover anexos',storageResult.error)}else{const attachmentResult=await sb.from('attachments').delete().eq('ticket_id',ticket.dbId);if(attachmentResult.error){cleanupFailed=true;console.error('Falha ao remover registros de anexos',attachmentResult.error)}}}await loadAdmin();selected=null;$('#ticketDetail').classList.remove('detail-expanded');document.body.classList.remove('detail-open');renderDetail();toast(cleanupFailed?'Chamado concluído e servidor notificado. Alguns anexos exigem limpeza manual.':'Chamado concluído. O servidor receberá a solução e o pedido de confirmação.')}};
  const detailWithClosingAuthor=renderDetail;renderDetail=function(){detailWithClosingAuthor();if(selected?.status!=='Concluído')return;const meta=$('#ticketDetail .resolution-box span');if(meta)meta.textContent=`Fechado por ${selected.closedBy||selected.technician||'Equipe técnica'} • ${selected.closedAt||'Data não informada'}`};
  // O clique das linhas é associado pela renderização definitiva abaixo.

  $('.dashboard-grid').insertAdjacentHTML('afterend',`<details id="archivedQueue" class="card archived-queue"><summary><span><strong>Chamados arquivados</strong><small id="archivedCount">0 chamado(s)</small></span><b aria-hidden="true">⌄</b></summary><div class="archived-toolbar"><input id="archivedSearch" type="search" autocomplete="off" placeholder="Buscar chamado arquivado..." aria-label="Buscar chamado arquivado"></div><div id="archivedTicketList" class="ticket-list"></div></details>`);
  function renderArchivedTickets(){const query=normalizeSearch($('#archivedSearch')?.value),rows=tickets.filter(ticket=>ticket.archivedAt&&(!query||normalizeSearch(Object.values(ticket).join(' ')).includes(query))),total=tickets.filter(ticket=>ticket.archivedAt).length;$('#archivedCount').textContent=total+(total===1?' chamado':' chamados');$('#archivedTicketList').innerHTML=rows.map(ticket=>`<article class="ticket-row archived-ticket-row ${selected?.id===ticket.id?'active':''}" data-id="${ticket.id}"><div>${ticket.feedbackConfirmedAt?'<span class="feedback-confirmed-badge"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" style="vertical-align:middle;margin-right:4px;"><polyline points="20 6 9 17 4 12"/></svg> Atendimento confirmado pelo servidor</span>':''}<span class="ticket-id">${ticket.id}</span><h3>${safe(ticket.title)}</h3><div class="ticket-meta"><span><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/></svg> ${safe(ticket.teacher)}</span><span><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect width="18" height="18" x="3" y="3" rx="2"/><path d="M3 9h18"/><path d="M9 21V9"/></svg> ${safe(ticket.lab)}</span><span><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg> ${safe(ticket.time)}</span><span><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 2H2v10l9.29 9.29c.94.94 2.48.94 3.42 0l6.58-6.58c.94-.94.94-2.48 0-3.42L12 2Z"/><circle cx="7" cy="7" r="1"/></svg> ${safe(ticket.category)}</span></div></div>${badge(ticket.status)}</article>`).join('')||'<p class="empty">Nenhum chamado arquivado encontrado.</p>';document.querySelectorAll('.archived-ticket-row').forEach(row=>row.onclick=()=>{selected=tickets.find(ticket=>ticket.id===row.dataset.id);renderArchivedTickets();renderDetail();$('#ticketDetail .detail-actions')?.remove();$('#ticketDetail #assigneeChoices')?.closest('label')?.remove();$('#ticketDetail #reply')?.closest('label')?.remove();$('#ticketDetail .detail-top')?.insertAdjacentHTML('afterend','<div class="archived-readonly"><strong>Chamado arquivado</strong><span>Disponível apenas para consulta e relatórios.</span></div>');if(innerWidth>900){$('#ticketDetail').classList.add('detail-expanded');document.body.classList.add('detail-open')}})}
  $('#archivedSearch').oninput=renderArchivedTickets;
  queueActions.insertAdjacentHTML('beforeend','<button id="deleteSelectedTickets" class="delete-ticket-action" type="button" disabled>Excluir selecionados</button>');
  const updateDeletionButton=()=>{$('#deleteSelectedTickets').disabled=!selectedForArchive.size};
  document.addEventListener('change',event=>{if(event.target.classList.contains('ticket-select'))setTimeout(updateDeletionButton,0)});
  async function deleteTicketWithAudit(ticket){const reason=prompt(`Informe o motivo da exclusão do chamado ${ticket.id}:`);if(reason===null)return false;if(reason.trim().length<5){toast('Informe uma justificativa com pelo menos 5 caracteres.');return false}setProcessing(true,'Excluindo chamado…');const {error}=await sb.rpc('soft_delete_ticket',{p_ticket:ticket.dbId,p_reason:reason.trim()});if(error){fail(error);return false}if(ticket.attachments?.length){const paths=ticket.attachments.map(item=>item.path),storage=await sb.storage.from('ticket-attachments').remove(paths);if(storage.error){fail(storage.error,'Chamado excluído, mas os anexos exigem limpeza manual.');return true}const records=await sb.from('attachments').delete().eq('ticket_id',ticket.dbId);if(records.error){fail(records.error,'Arquivos removidos, mas os registros dos anexos exigem limpeza manual.');return true}}return true}
  $('#deleteSelectedTickets').onclick=async()=>{const chosen=tickets.filter(ticket=>selectedForArchive.has(ticket.dbId)&&!ticket.deletedAt);if(!chosen.length)return;try{for(const ticket of chosen){if(!await deleteTicketWithAudit(ticket))return}selectedForArchive.clear();if(selected&&chosen.some(ticket=>ticket.dbId===selected.dbId))selected=null;$('#ticketDetail').classList.remove('detail-expanded');document.body.classList.remove('detail-open');await loadAdmin();selected=null;renderDetail();toast(chosen.length+' chamado(s) excluído(s) com registro de auditoria.')}finally{setProcessing(false)}};
  const archivedQueueRender=renderArchivedTickets;renderArchivedTickets=function(){archivedQueueRender();document.querySelectorAll('#archivedTicketList .ticket-row').forEach(row=>{const ticket=tickets.find(item=>item.id===row.dataset.id);if(ticket?.deletedAt){row.remove();return}row.insertAdjacentHTML('beforeend','<button class="delete-archived-ticket" type="button">Excluir</button>');row.querySelector('.delete-archived-ticket').onclick=async event=>{event.stopPropagation();try{if(await deleteTicketWithAudit(ticket)){selected=null;$('#ticketDetail').classList.remove('detail-expanded');document.body.classList.remove('detail-open');await loadAdmin();selected=null;renderDetail();toast('Chamado excluído com registro de auditoria.')}}finally{setProcessing(false)}}});const total=tickets.filter(ticket=>ticket.archivedAt&&!ticket.deletedAt).length;$('#archivedCount').textContent=total+(total===1?' chamado':' chamados')};

  $('#archivedSearch').oninput=renderArchivedTickets;
  const filteredTicketsWithoutDeleted=filteredTickets;filteredTickets=function(){return filteredTicketsWithoutDeleted().filter(ticket=>!ticket.deletedAt)};

  // O supervisor usa a mesma leitura analítica dos relatórios técnicos. A lista
  // operacional é derivada dos chamados carregados do Supabase e fica recolhida
  // por padrão para não competir visualmente com os indicadores.
  function ensureSupervisorReportView(){
    const section=$('#supervisorSection');
    if(!section||section.dataset.reportView==='true')return;
    section.dataset.reportView='true';
    section.innerHTML=`
      <div class="supervisor-banner card">
        <div><span class="eyebrow">ACESSO SOMENTE LEITURA</span><h2>Relatórios e acompanhamento</h2><p>Indicadores sincronizados com os mesmos chamados exibidos no painel técnico.</p></div>
        <span class="readonly-badge">Somente consulta</span>
      </div>
      <div class="analytics-filters card supervisor-report-filters">
        <label>Período<select id="supervisorPeriod"><option value="30">Últimos 30 dias</option><option value="7">Últimos 7 dias</option><option value="1">Hoje</option><option value="all">Todo o período</option></select></label>
        <label>Laboratório<select id="supervisorLab"><option value="Todos">Todos</option></select></label>
        <label>Categoria<select id="supervisorCategory"><option value="Todas">Todas</option></select></label>
        <button id="applySupervisorFilters" class="primary" type="button">Aplicar filtros</button>
      </div>
      <div class="metrics analytics-metrics supervisor-metrics">
        <article><div><small>Total no período</small><strong id="supTotal">0</strong><em>Registros reais</em></div></article>
        <article><div><small>Taxa de resolução</small><strong id="supResolution">0%</strong><em id="supDone">0 concluído(s)</em></div></article>
        <article><div><small>Pico de abertura</small><strong id="supPeak">—</strong><em id="supPeakHelp">Sem aberturas</em></div></article>
        <article><div><small>Laboratório crítico</small><strong id="supCriticalLab">—</strong><em id="supCriticalLabHelp">Sem ocorrências</em></div></article>
      </div>
      <div class="charts-grid supervisor-charts">
        <article class="card chart-card wide"><div class="chart-head"><div><h2>Chamados por horário</h2><p>Volume de aberturas ao longo do dia</p></div><span class="readonly-badge">Leitura</span></div><div id="supHourChart" class="bar-chart"></div></article>
        <article class="card chart-card"><h2>Por categoria</h2><div id="supCategoryChart"></div></article>
        <article class="card chart-card"><h2>Por laboratório</h2><div id="supLabChart"></div></article>
        <article class="card chart-card wide"><h2>Servidores com solicitações</h2><div id="supTeacherChart" class="teacher-table"></div></article>
      </div>
      <details id="supervisorTracking" class="card supervisor-tracking">
        <summary><span><strong>Acompanhamento dos chamados</strong><small id="supervisorTrackingCount">0 registro(s)</small></span><b aria-hidden="true">⌄</b></summary>
        <div class="supervisor-tracking-toolbar"><input id="supervisorTicketSearch" type="search" autocomplete="off" placeholder="Buscar protocolo, servidor, laboratório ou categoria..." aria-label="Buscar no acompanhamento"></div>
        <div id="supervisorTable" class="supervisor-table"></div>
      </details>
      <details id="deletionAudit" class="card supervisor-tracking deletion-audit">
        <summary><span><strong>Auditoria de exclusões</strong><small>Chamados removidos das filas pelos técnicos</small></span><b aria-hidden="true">⌄</b></summary>
        <div id="deletionAuditList"></div>
      </details>`;
    $('#applySupervisorFilters').onclick=()=>supervisor();
    $('#supervisorTicketSearch').oninput=()=>renderSupervisorTracking(supervisorFilteredTickets());
  }

  function supervisorFilteredTickets(){
    const period=$('#supervisorPeriod')?.value||'30',lab=$('#supervisorLab')?.value||'Todos',category=$('#supervisorCategory')?.value||'Todas',now=new Date();
    return tickets.filter(ticket=>{
      if(ticket.deletedAt)return false;
      if(lab!=='Todos'&&ticket.lab!==lab)return false;
      if(category!=='Todas'&&ticket.category!==category)return false;
      if(period==='all')return true;
      if(!ticket.createdAt)return false;
      const created=new Date(ticket.createdAt);
      if(period==='1')return created.toDateString()===now.toDateString();
      return created>=new Date(now.getTime()-Number(period)*86400000);
    });
  }

  function renderSupervisorTracking(rows){
    const query=normalizeSearch($('#supervisorTicketSearch')?.value),filtered=rows.filter(ticket=>!query||normalizeSearch(Object.values(ticket).join(' ')).includes(query));
    $('#supervisorTrackingCount').textContent=`${filtered.length} registro(s) • ${filtered.filter(ticket=>ticket.archivedAt).length} arquivado(s)`;
    $('#supervisorTable').innerHTML='<div class="supervisor-row supervisor-head"><span>Protocolo</span><span>Solicitante</span><span>Laboratório</span><span>Categoria</span><span>Situação</span><span>Técnico</span></div>'+filtered.map(ticket=>`<div class="supervisor-row ${ticket.archivedAt?'is-archived':''}"><strong>${safe(ticket.id)}</strong><span>${safe(ticket.teacher)}</span><span>${safe(ticket.lab)}</span><span>${safe(ticket.category)}</span><span class="supervisor-status-cell">${badge(ticket.status)}${ticket.archivedAt?'<small>Arquivado</small>':'<small>Na fila</small>'}</span><span>${safe(ticket.technician)}</span></div>`).join('')+(filtered.length?'':'<p class="empty">Nenhum chamado encontrado com os filtros selecionados.</p>');
  }

  // Renderizacao unica e definitiva do painel do supervisor (mesmo padrao
  // de `renderTickets` abaixo). Achado P2 3.1 da auditoria de 26/08/2026:
  // esta funcao antes era redefinida por cima varias vezes ao longo do
  // arquivo (padrao de decorador, como ainda acontece com `renderDetail`
  // mais acima), mas cada reatribuicao aqui e em `renderTickets` era uma
  // substituicao completa (nao chamava a versao anterior), o que tornava
  // as definicoes anteriores codigo morto -- nunca executavam, porque a
  // variavel global e resolvida em tempo de chamada, nao de definicao.
  // Essas definicoes anteriores (nunca executadas) foram removidas nesta
  // auditoria; o comportamento em producao nao muda.
  supervisor=function(){
    ensureSupervisorReportView();
    const labSelect=$('#supervisorLab'),categorySelect=$('#supervisorCategory'),selectedLab=labSelect.value||'Todos',selectedCategory=categorySelect.value||'Todas';
    labSelect.innerHTML='<option value="Todos">Todos</option>'+data.labs.filter(item=>item.active!==false).map(item=>`<option value="${safe(item.name)}">${safe(item.name)}</option>`).join('');
    categorySelect.innerHTML='<option value="Todas">Todas</option>'+data.categories.filter(item=>item.active!==false).map(item=>`<option value="${safe(item.name)}">${safe(item.name)}</option>`).join('');
    if([...labSelect.options].some(option=>option.value===selectedLab))labSelect.value=selectedLab;
    if([...categorySelect.options].some(option=>option.value===selectedCategory))categorySelect.value=selectedCategory;
    const rows=supervisorFilteredTickets(),hours=Array.from({length:16},(_,index)=>[`${index+7}h`,rows.filter(ticket=>ticket.createdAt&&new Date(ticket.createdAt).getHours()===index+7).length]),max=Math.max(1,...hours.map(item=>item[1])),categories=grouped(rows,'category'),labs=grouped(rows,'lab'),done=rows.filter(ticket=>ticket.status==='Concluído').length,peak=hours.reduce((current,item)=>item[1]>current[1]?item:current,['—',0]),people=grouped(rows,'teacher').map(([name,count])=>[name,grouped(rows.filter(ticket=>ticket.teacher===name),'category')[0]?.[0]||'—',count]);
    $('#supTotal').textContent=rows.length;$('#supResolution').textContent=rows.length?`${Math.round(done/rows.length*100)}%`:'0%';$('#supDone').textContent=`${done} concluído(s)`;$('#supPeak').textContent=peak[1]?peak[0]:'—';$('#supPeakHelp').textContent=`${peak[1]} abertura(s)`;$('#supCriticalLab').textContent=labs[0]?.[0]||'—';$('#supCriticalLabHelp').textContent=`${labs[0]?.[1]||0} ocorrência(s)`;
    $('#supHourChart').innerHTML=hours.map(([label,value])=>`<div class="bar-column"><small>${value}</small><i style="height:${value/max*85}%"></i><strong>${label}</strong></div>`).join('');renderRank('#supCategoryChart',categories);renderRank('#supLabChart',labs);$('#supTeacherChart').innerHTML='<div><span>Servidor</span><span>Principal categoria</span><span>Chamados</span></div>'+people.map(item=>`<div><strong>${safe(item[0])}</strong><span>${safe(item[1])}</span><strong>${item[2]}</strong></div>`).join('')+(people.length?'':'<p class="empty">Sem dados no período.</p>');
    renderSupervisorTracking(rows);
    const deleted=tickets.filter(ticket=>ticket.deletedAt);$('#deletionAuditList').innerHTML=deleted.map(ticket=>`<article><strong>${safe(ticket.id)}</strong><span>${safe(ticket.title)}</span><span>Excluído por <b>${safe(ticket.deletedBy||'Técnico não identificado')}</b></span><time>${fmt(ticket.deletedAt)}</time><p>${safe(ticket.deletionReason||'Sem justificativa registrada')}</p></article>`).join('')||'<p class="empty">Nenhuma exclusão registrada.</p>';
  };

  // Renderização única e definitiva da fila. Evita que referências antigas removam
  // cores, alertas ou façam chamados excluídos reaparecerem após interações.
  renderTickets=function(){
    const query=normalizeSearch($('#ticketSearch')?.value),status=$('#statusFilter')?.value||'Todos os status';
    const priority={'Recebido':0,'Em atendimento':1,'Concluído':2};
    const rows=tickets.filter(ticket=>!ticket.archivedAt&&!ticket.deletedAt&&(status==='Todos os status'||ticket.status===status)&&(!query||normalizeSearch(Object.values(ticket).join(' ')).includes(query))).sort((a,b)=>(priority[a.status]??9)-(priority[b.status]??9)||new Date(b.created_at||0)-new Date(a.created_at||0));
    $('.queue-head>div:first-child span').textContent=rows.length+' chamado(s) encontrado(s)';
    $('#ticketList').innerHTML=rows.map(ticket=>{
      const replyAttention=ticket.status!=='Concluído'&&ticket.serverReplyPending;
      const openedAt=new Date(ticket.createdAt||0),today=new Date();openedAt.setHours(0,0,0,0);today.setHours(0,0,0,0);const staleUnassigned=ticket.status==='Recebido'&&openedAt.getTime()>0&&(today-openedAt>=7*24*60*60*1000);
      const stateClass=ticket.status==='Concluído'?'ticket-completed':ticket.status==='Em atendimento'?'ticket-progress':'ticket-received';
      const replyLabel=ticket.serverReplyPending?'! Nova resposta do servidor':(staleUnassigned?'⚠ Mais de 7 dias sem atribuição':'');
      return `<article class="ticket-row ${stateClass} ${replyAttention?'ticket-waiting-reply has-server-reply':''} ${selected?.id===ticket.id?'active':''}" data-id="${safe(ticket.id)}"><input class="ticket-select" type="checkbox" aria-label="Selecionar ${safe(ticket.id)}" ${selectedForArchive.has(ticket.dbId)?'checked':''}><div>${replyLabel?`<span class="server-reply-badge">${replyLabel}</span>`:''}${ticket.feedbackConfirmedAt?'<span class="feedback-confirmed-badge"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" style="vertical-align:middle;margin-right:4px;"><polyline points="20 6 9 17 4 12"/></svg> Atendimento confirmado pelo servidor</span>':''}<span class="ticket-id">${safe(ticket.id)}</span><h3>${safe(ticket.title)}</h3><div class="ticket-meta"><span><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/></svg> ${safe(ticket.teacher)}</span><span><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect width="18" height="18" x="3" y="3" rx="2"/><path d="M3 9h18"/><path d="M9 21V9"/></svg> ${safe(ticket.lab)}</span><span><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg> ${safe(ticket.time)}</span><span><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 2H2v10l9.29 9.29c.94.94 2.48.94 3.42 0l6.58-6.58c.94-.94.94-2.48 0-3.42L12 2Z"/><circle cx="7" cy="7" r="1"/></svg> ${safe(ticket.category)}</span></div></div>${badge(ticket.status)}</article>`;
    }).join('')||'<p class="empty">Nenhum chamado na fila.</p>';
    document.querySelectorAll('#ticketList .ticket-row').forEach(row=>{
      const ticket=tickets.find(item=>item.id===row.dataset.id),checkbox=row.querySelector('.ticket-select');
      checkbox.onchange=event=>{event.target.checked?selectedForArchive.add(ticket.dbId):selectedForArchive.delete(ticket.dbId);updateArchiveButton();updateDeletionButton()};
      row.onclick=async event=>{if(event.target===checkbox)return;const unread=ticket.serverReplyPending&&state.profile?.role==='tecnico';if(unread)ticket.serverReplyPending=false;selected=ticket;renderTickets();renderDetail();if(innerWidth>900){$('#ticketDetail').classList.add('detail-expanded');document.body.classList.add('detail-open')}if(unread){const result=await sb.rpc('mark_server_reply_read',{p_ticket:ticket.dbId});if(result.error){ticket.serverReplyPending=true;renderTickets();console.error('Falha ao marcar resposta como lida',result.error)}}};
    });
    updateArchiveButton();updateDeletionButton();
  };
  $('#ticketSearch').oninput=renderTickets;
  $('#statusFilter').onchange=renderTickets;

  // A atribuição atualiza o estado local após a confirmação do banco, sem depender
  // de uma recarga completa da página para exibir "Em atendimento".
  const renderDetailBeforeReliableAssignment=renderDetail;
  renderDetail=function(){
    renderDetailBeforeReliableAssignment();
    const assign=$('#assign');
    if(!assign||!selected||state.profile?.role!=='tecnico')return;
    assign.onclick=async()=>{
      if(assign.disabled)return;
      const choices=$('#assigneeChoices'),checked=[...(choices?.querySelectorAll('input:checked')||[])].map(input=>input.value),collective=checked.includes('__all__'),ids=checked.filter(id=>id!=='__all__');
      if(!collective&&!ids.length)return toast('Selecione ao menos um técnico ou toda a equipe.');
      const ticket=selected,names=collective?'Toda a equipe':data.technicians.filter(technician=>ids.includes(technician.id)).map(technician=>technician.name).join(', '),startedAt=new Date().toISOString();
      assign.disabled=true;assign.textContent='Iniciando atendimento…';
      try{
        const updated=await sb.from('tickets').update({assigned_to:ids[0]||null,status:'Em atendimento',started_at:startedAt,updated_at:startedAt}).eq('id',ticket.dbId);
        if(updated.error)throw updated.error;
        const removed=await sb.from('ticket_assignees').delete().eq('ticket_id',ticket.dbId);
        if(removed.error)throw removed.error;
        if(ids.length){const inserted=await sb.from('ticket_assignees').insert(ids.map(id=>({ticket_id:ticket.dbId,profile_id:id,assigned_by:state.profile.id})));if(inserted.error)throw inserted.error}
        const history=await sb.from('ticket_updates').insert({ticket_id:ticket.dbId,author_id:state.profile.id,message:'Atendimento atribuído a '+names,kind:'status'});
        if(history.error)console.error('Atendimento iniciado, mas o histórico não foi registrado',history.error);
        ticket.status='Em atendimento';ticket.technician=names;ticket.technicianIds=ids;ticket.technicianId=ids[0]||null;ticket.serverReplyPending=false;
        ticket.updates=[...(ticket.updates||[]),{message:'Atendimento atribuído a '+names,kind:'status',author:state.profile.full_name,createdAt:startedAt}];
        renderTickets();renderDetail();refreshMetrics();toast('Atendimento iniciado com '+names+'.');
      }catch(error){assign.disabled=false;assign.textContent='Atribuir e iniciar';fail(error,'Não foi possível iniciar o atendimento.')}
    };
  };

  const renderDetailBeforeFeedbackConfirmation=renderDetail;
  renderDetail=function(){
    renderDetailBeforeFeedbackConfirmation();
    if(!selected?.feedbackConfirmedAt)return;
    $('#ticketDetail .detail-top')?.insertAdjacentHTML('afterend',`<div class="feedback-confirmed-alert"><strong>✓ Atendimento confirmado pelo servidor</strong><span>Confirmação recebida em ${fmt(selected.feedbackConfirmedAt)}.</span></div>`);
  };

  // Mantém mensagens longas do histórico compactas. A medição por scrollHeight
  // não é confiável quando o navegador aplica -webkit-line-clamp, portanto a
  // decisão usa também o conteúdo efetivo da mensagem.
  const detailWithReliableHistoryClamp=renderDetail;
  renderDetail=function(){
    detailWithReliableHistoryClamp();
    $('#ticketDetail')?.querySelectorAll('.ticket-history article').forEach(card=>{
      const message=card.querySelector('.history-message');
      const toggle=card.querySelector('.history-toggle');
      if(!message||!toggle)return;
      const content=message.textContent||'';
      const isLong=content.length>180||content.split(/\r?\n/).length>3;
      if(!isLong){
        message.classList.remove('collapsed');
        toggle.hidden=true;
        return;
      }
      message.classList.add('collapsed');
      toggle.hidden=false;
      toggle.textContent='Ver tudo';
      toggle.setAttribute('aria-expanded','false');
      toggle.onclick=()=>{
        const expand=message.classList.contains('collapsed');
        message.classList.toggle('collapsed',!expand);
        toggle.textContent=expand?'Recolher':'Ver tudo';
        toggle.setAttribute('aria-expanded',String(expand));
      };
    });
  };

  // Interações consistentes por teclado, foco e clique externo.
  $('#protocolInput').addEventListener('keydown',event=>{if(event.key==='Enter'){event.preventDefault();$('#protocolButton').click()}});
  $('#adminTeacherSearch').addEventListener('keydown',event=>{if(event.key!=='Enter')return;event.preventDefault();const choices=[...adminTeacherSelect.options].filter(option=>option.value);if(choices.length===1){adminTeacherSelect.value=choices[0].value;adminTeacherSelect.dispatchEvent(new Event('change'));adminTeacherSelect.focus()}});

  document.addEventListener('click',event=>{
    if(!accountDropdown.hidden&&!event.target.closest('.account-menu')){$('#accountButton').setAttribute('aria-expanded','false');accountDropdown.hidden=true}
    const menu=$('#adminMenuDropdown'),menuButton=$('#adminMenuButton');
    if(menu&&!menu.hidden&&!event.target.closest('.admin-menu')&&event.target!==menuButton)menu.hidden=true;
    if(event.target.classList.contains('modal-backdrop'))event.target.querySelector('.modal-close, [id^="cancel"]')?.click();
  });

  document.addEventListener('keydown',event=>{
    if(event.key!=='Escape')return;
    const visibleModal=[...document.querySelectorAll('.modal-backdrop:not([hidden])')].pop();
    if(visibleModal){visibleModal.querySelector('.modal-close, [id^="cancel"]')?.click();return}
    if(!accountDropdown.hidden){$('#accountButton').click();$('#accountButton').focus();return}
    const menu=$('#adminMenuDropdown');if(menu&&!menu.hidden){menu.hidden=true;$('#adminMenuButton')?.focus();return}
    const detail=$('#ticketDetail');if(detail?.classList.contains('detail-expanded'))detail.querySelector('.detail-close')?.click();
  });

  const focusOpenedModal=new MutationObserver(entries=>entries.forEach(({target,attributeName})=>{if(attributeName==='hidden'&&!target.hidden){setTimeout(()=>target.querySelector('input:not([type="hidden"]), select, textarea, button')?.focus(),0)}}));
  document.querySelectorAll('.modal-backdrop').forEach(modal=>focusOpenedModal.observe(modal,{attributes:true,attributeFilter:['hidden']}));

  // Sincroniza o painel sem perder o chamado aberto, os filtros ou a rolagem.
  let adminSyncRunning=false,adminSyncQueued=false,adminSyncTimer=null,lastAdminSignature='',knownTicketIds=new Set();
  async function adminSignature(){
    const [ticketResult,updateResult]=await Promise.all([
      sb.from('tickets').select('id,updated_at').order('updated_at',{ascending:false}).limit(1).maybeSingle(),
      sb.from('ticket_updates').select('id,created_at').order('created_at',{ascending:false}).limit(1).maybeSingle()
    ]);
    if(ticketResult.error||updateResult.error)throw ticketResult.error||updateResult.error;
    return `${ticketResult.data?.id||''}:${ticketResult.data?.updated_at||''}|${updateResult.data?.id||''}:${updateResult.data?.created_at||''}`;
  }
  async function synchronizeAdmin(){
    if(!state.profile||$('#adminView').hidden)return;
    if(adminSyncRunning){adminSyncQueued=true;return}
    adminSyncRunning=true;
    const selectedId=selected?.dbId,expanded=$('#ticketDetail')?.classList.contains('detail-expanded'),queueScroll=$('#ticketList')?.scrollTop||0,detailScroll=$('#ticketDetail')?.scrollTop||0,search=$('#ticketSearch')?.value||'',status=$('#statusFilter')?.value||'Todos os status',before=new Set(tickets.map(ticket=>ticket.dbId));
    try{
      await loadAdmin();
      selected=selectedId?tickets.find(ticket=>ticket.dbId===selectedId&&!ticket.deletedAt)||null:null;
      $('#ticketSearch').value=search;$('#statusFilter').value=status;
      renderTickets();renderArchivedTickets();renderDetail();refreshMetrics();
      if(expanded&&selected){$('#ticketDetail').classList.add('detail-expanded');document.body.classList.add('detail-open')}else if(!expanded){$('#ticketDetail').classList.remove('detail-expanded');document.body.classList.remove('detail-open')}
      $('#ticketList').scrollTop=queueScroll;$('#ticketDetail').scrollTop=detailScroll;
      const newcomers=tickets.filter(ticket=>!before.has(ticket.dbId)&&!ticket.deletedAt);
      if(knownTicketIds.size&&newcomers.length){
        const newest=newcomers[0];
        showIncomingTicketAlert(newest);
      }
      knownTicketIds=new Set(tickets.map(ticket=>ticket.dbId));
      lastAdminSignature=await adminSignature();
    }catch(error){console.error('Falha ao atualizar o painel automaticamente',error)}
    finally{adminSyncRunning=false;if(adminSyncQueued){adminSyncQueued=false;scheduleAdminSync(250)}}
  }
  function scheduleAdminSync(delay=700){clearTimeout(adminSyncTimer);adminSyncTimer=setTimeout(synchronizeAdmin,delay)}
  async function checkAdminChanges(){
    if(!state.profile||document.hidden)return;
    try{const signature=await adminSignature();if(!lastAdminSignature)lastAdminSignature=signature;else if(signature!==lastAdminSignature)scheduleAdminSync(100)}catch(error){console.error('Falha na verificação periódica do painel',error)}
  }
  let adminLiveChannel=null,globalTicketAlertChannel=null,adminPollInterval=null;
  function startAdminSynchronization(){
    if(!state.profile)return;
    knownTicketIds=new Set(tickets.map(ticket=>ticket.dbId));
    adminSignature().then(signature=>{lastAdminSignature=signature}).catch(error=>console.error('Falha ao iniciar sincronização',error));

    if(adminLiveChannel){sb.removeChannel(adminLiveChannel);adminLiveChannel=null}
    if(globalTicketAlertChannel){sb.removeChannel(globalTicketAlertChannel);globalTicketAlertChannel=null}

    globalTicketAlertChannel=sb.channel('labinfo-global-ticket-alerts')
      .on('broadcast',{event:'new_ticket'},payload=>{
        if(state.profile&&!$('#adminView').hidden&&payload.payload){
          showIncomingTicketAlert(payload.payload);
          scheduleAdminSync(50);
        }
      })
      .subscribe();

    adminLiveChannel=sb.channel('labinfo-admin-live')
      .on('postgres_changes',{event:'INSERT',schema:'public',table:'tickets'},payload=>{
        if(state.profile&&!$('#adminView').hidden){
          if(payload.new)showIncomingTicketAlert(payload.new);
          scheduleAdminSync(80);
        }else if(document.hidden){
          adminSyncQueued=true;
        }
      })
      .on('postgres_changes',{event:'*',schema:'public',table:'tickets'},()=>document.hidden?adminSyncQueued=true:scheduleAdminSync())
      .on('postgres_changes',{event:'*',schema:'public',table:'ticket_updates'},()=>document.hidden?adminSyncQueued=true:scheduleAdminSync())
      .on('postgres_changes',{event:'*',schema:'public',table:'ticket_assignees'},()=>document.hidden?adminSyncQueued=true:scheduleAdminSync())
      .on('postgres_changes',{event:'*',schema:'public',table:'attachments'},()=>document.hidden?adminSyncQueued=true:scheduleAdminSync())
      .subscribe();

    if(adminPollInterval)clearInterval(adminPollInterval);
    adminPollInterval=setInterval(checkAdminChanges,3500);

    document.addEventListener('visibilitychange',()=>{if(!document.hidden){if(adminSyncQueued){adminSyncQueued=false;scheduleAdminSync(100)}else checkAdminChanges()}});
    window.addEventListener('focus',checkAdminChanges);
  }

  let activeIncomingTicketAlert=null;
  function showIncomingTicketAlert(ticket){
    if(!ticket||!state.profile||$('#adminView').hidden)return;
    const alertId=ticket.dbId||ticket.id||ticket.protocol;
    if(!alertId||activeIncomingTicketAlert===alertId)return;
    activeIncomingTicketAlert=alertId;

    const modal=$('#incomingTicketAlert');
    if(!modal)return;

    const proto=ticket.id||ticket.protocol||'NOVO CHAMADO';
    const cat=ticket.category||ticket.category_name||(data.categories.find(c=>c.id===ticket.category_id)?.name)||'Geral';
    const serverName=ticket.teacher||ticket.server_name||ticket.server_full_name||(data.teachers.find(t=>t.id===ticket.server_id||t.siape===ticket.guest_siape)?.name)||'Servidor Solicitante';
    const labName=ticket.lab||ticket.lab_name||(data.labs.find(l=>l.id===ticket.lab_id)?.name)||'Local não informado';
    const timeStr=ticket.time||(ticket.created_at?fmt(ticket.created_at):'Agora');

    const protoBadge=$('#incomingTicketProtocolBadge');
    const catBadge=$('#incomingTicketCategoryBadge');
    const nameEl=$('#incomingTicketServerName');
    const detailsEl=$('#incomingTicketServerDetails');
    const titleEl=$('#incomingTicketTitle');
    const descEl=$('#incomingTicketDescription');

    if(protoBadge)protoBadge.textContent=proto;
    if(catBadge)catBadge.textContent=cat;
    if(nameEl)nameEl.textContent=serverName;
    if(detailsEl)detailsEl.textContent=`${labName} • ${timeStr}`;
    if(titleEl)titleEl.textContent=ticket.title||'Solicitação de Suporte';
    if(descEl)descEl.textContent=ticket.description||'Sem descrição detalhada informada.';

    modal.hidden=false;
    document.body.classList.add('modal-open');
    playChatNotificationSound();
  }

  $('#dismissIncomingTicketBtn')?.addEventListener('click',()=>{
    $('#incomingTicketAlert').hidden=true;
    document.body.classList.remove('modal-open');
    activeIncomingTicketAlert=null;
  });

  $('#viewIncomingTicketBtn')?.addEventListener('click',()=>{
    const alertTicketId=activeIncomingTicketAlert;
    $('#incomingTicketAlert').hidden=true;
    document.body.classList.remove('modal-open');
    activeIncomingTicketAlert=null;

    if(alertTicketId){
      const target=tickets.find(t=>t.dbId===alertTicketId||t.id===alertTicketId);
      if(target){
        selected=target;
        renderTickets();
        renderDetail();
        const row=document.querySelector(`.ticket-row[data-id="${target.id}"]`);
        if(row)row.scrollIntoView({behavior:'smooth',block:'center'});
        if(window.innerWidth<=900){
          $('#ticketDetail')?.classList.add('detail-expanded');
          document.body.classList.add('detail-open');
        }
      }
    }
  });

  $('#incomingTicketAlert')?.addEventListener('click',e=>{
    if(e.target===$('#incomingTicketAlert')){
      $('#incomingTicketAlert').hidden=true;
      document.body.classList.remove('modal-open');
      activeIncomingTicketAlert=null;
    }
  });

  // ==========================================================================
  // MÓDULO DE CHAT AO VIVO — ATENDIMENTO EM TEMPO REAL E GERAÇÃO DE CHAMADOS
  // ==========================================================================

  let chatAvailability = { available: false, online_count: 0 };
  let staffHeartbeatTimer = null;
  let staffChatDesiredOnline = false;
  let staffChatPresenceListenersBound = false;
  let staffOnlinePromptTimer = null;
  let currentPublicChatSession = null;
  let currentPublicServer = null;
  let publicChatChannel = null;
  let adminChatChannel = null;
  let activeAdminChatSession = null;
  let activeAdminChatMessages = [];
  let incomingAlertSessionId = null;
  let incomingCallRingtoneTimer = null;

  function playChatNotificationSound() {
    try {
      const AudioCtx = window.AudioContext || window.webkitAudioContext;
      if (!AudioCtx) return;
      const ctx = new AudioCtx();
      if (ctx.state === 'suspended') ctx.resume();
      
      const now = ctx.currentTime;
      const osc1 = ctx.createOscillator();
      const gain1 = ctx.createGain();
      osc1.type = 'sine';
      osc1.frequency.setValueAtTime(587.33, now);
      gain1.gain.setValueAtTime(0.22, now);
      gain1.gain.exponentialRampToValueAtTime(0.001, now + 0.35);
      osc1.connect(gain1);
      gain1.connect(ctx.destination);
      osc1.start(now);
      osc1.stop(now + 0.35);

      const osc2 = ctx.createOscillator();
      const gain2 = ctx.createGain();
      osc2.type = 'sine';
      osc2.frequency.setValueAtTime(880, now + 0.14);
      gain2.gain.setValueAtTime(0.24, now + 0.14);
      gain2.gain.exponentialRampToValueAtTime(0.001, now + 0.6);
      osc2.connect(gain2);
      gain2.connect(ctx.destination);
      osc2.start(now + 0.14);
      osc2.stop(now + 0.6);
    } catch (e) {
      console.warn('Alerta sonoro indisponível:', e);
    }
  }

  function startIncomingCallRingtone() {
    stopIncomingCallRingtone();
    playChatNotificationSound();
    incomingCallRingtoneTimer = setInterval(() => {
      const alert = $('#incomingChatAlert');
      if (alert && !alert.hidden) {
        playChatNotificationSound();
      } else {
        stopIncomingCallRingtone();
      }
    }, 1800);
  }

  function stopIncomingCallRingtone() {
    if (incomingCallRingtoneTimer) {
      clearInterval(incomingCallRingtoneTimer);
      incomingCallRingtoneTimer = null;
    }
  }

  async function loadChatAvailability() {
    try {
      const { data: res, error } = await sb.rpc('get_chat_availability');
      if (error) throw error;
      chatAvailability = res || { available: false, online_count: 0, technicians: [] };

      const badge = $('#chatAvailabilityBadge');
      const desc = $('#chatAvailabilityDescription');
      const action = $('#chatAvailabilityAction');
      const warning = $('#chatAvailabilityWarning');

      if (badge) {
        badge.className = 'chat-status-badge ' + (chatAvailability.available ? 'online' : 'offline');
        badge.innerHTML = chatAvailability.available
          ? `<span class="status-dot online"></span> Online (${chatAvailability.online_count} de plantão)`
          : '<span class="status-dot offline"></span> Offline';
      }
      if (desc) {
        desc.textContent = chatAvailability.available
          ? 'Técnicos disponíveis para tirar dúvidas e prestar auxílio imediato.'
          : 'Converse em tempo real com os técnicos de plantão dos laboratórios.';
      }
      if (action) {
        action.textContent = chatAvailability.available
          ? 'Falar com técnico agora →'
          : 'Acessar atendimento →';
      }
      if (warning) {
        warning.hidden = chatAvailability.available;
      }

      // Atualiza presença no topo e no painel do técnico
      const techs = chatAvailability.technicians || [];
      const topbarPill = $('#topbarOnlineStaffPill');
      if (topbarPill) {
        topbarPill.className = 'chat-status-badge ' + (techs.length > 0 ? 'online' : 'offline');
        topbarPill.innerHTML = techs.length > 0 ? `<span class="status-dot online"></span> ${techs.length} online` : '<span class="status-dot offline"></span> 0 online';
        topbarPill.title = techs.length > 0
          ? `Técnicos online: ${techs.map(t => t.name).join(', ')}`
          : 'Nenhum outro técnico online';
      }

      const countEl = $('#onlineStaffCount');
      if (countEl) countEl.textContent = techs.length;

      const badgesContainer = $('#onlineStaffBadges');
      if (badgesContainer) {
        if (techs.length === 0) {
          badgesContainer.innerHTML = '<span class="chat-status-badge offline">Nenhum técnico online no momento</span>';
        } else {
          badgesContainer.innerHTML = techs.map(t => {
            const isMe = state.profile && t.id === state.profile.id;
            return `<span class="chat-status-badge online" style="font-size:12px;padding:5px 10px;${isMe ? 'background:#dff3e7;color:#08733b;' : 'background:#e8f4fc;color:#185b8c;'}">
              <span class="status-dot online"></span> <strong>${safe(t.name)}</strong>${isMe ? ' <small style="font-weight:400;">(Você)</small>' : ''}
            </span>`;
          }).join('');
        }
      }
    } catch (err) {
      console.warn('Não foi possível verificar disponibilidade do chat', err);
    }
  }

  async function renderChatAdminDashboard() {
    loadChatAvailability();
    const toggle = $('#staffChatToggle');
    const isOnline = toggle ? toggle.checked : false;
    const badge = $('#chatAdminStatusIndicator');
    const btn = $('#chatAdminToggleStatusBtn');
    if (badge) {
      badge.className = 'chat-status-badge ' + (isOnline ? 'online' : 'offline');
      badge.innerHTML = isOnline ? '<span class="status-dot online"></span> Online (Você está disponível)' : '<span class="status-dot offline"></span> Offline';
    }
    if (btn) {
      btn.textContent = isOnline ? 'Ficar Offline' : 'Ficar Online';
      btn.className = isOnline ? 'secondary' : 'primary';
    }

    try {
      let sessions = [];
      const { data: rpcSessions, error: rpcErr } = await sb.rpc('get_admin_chat_dashboard');
      if (!rpcErr && Array.isArray(rpcSessions)) {
        sessions = rpcSessions;
      } else {
        const [sessRes, servRes, profRes, tickRes] = await Promise.all([
          sb.from('chat_sessions').select('*').order('created_at', { ascending: false }).limit(60),
          sb.from('servers').select('id, full_name, siape, email'),
          sb.from('profiles').select('id, full_name'),
          sb.from('tickets').select('id, protocol')
        ]);

        const rawSessions = sessRes.data || [];
        const serverMap = new Map((servRes.data || []).map(s => [s.id, s]));
        const profileMap = new Map((profRes.data || []).map(p => [p.id, p]));
        const ticketMap = new Map((tickRes.data || []).map(t => [t.id, t]));

        sessions = rawSessions.map(s => {
          const sv = serverMap.get(s.server_id);
          const pf = profileMap.get(s.technician_id);
          const tk = ticketMap.get(s.ticket_id);
          return {
            ...s,
            server_name: sv?.full_name || 'Servidor',
            server_siape: sv?.siape || '—',
            server_email: sv?.email || '—',
            technician_name: pf?.full_name || '—',
            ticket_protocol: tk?.protocol || null
          };
        });
      }

      // Filtra e auto-encerra solicitações que ficaram esperando há mais de 20 minutos
      const nowMs = Date.now();
      const validSessions = (sessions || []).filter(s => {
        if (!s || !s.id) return false;
        if (s.status === 'waiting' && s.created_at) {
          const ageMin = (nowMs - new Date(s.created_at).getTime()) / 60000;
          if (ageMin > 20) {
            Promise.resolve(sb.rpc('close_chat_session', { p_session_id: s.id, p_notes: 'Expirado por inatividade na fila' })).catch(() => {});
            return false;
          }
        }
        return true;
      });

      const waiting = validSessions.filter(s => s.status === 'waiting');
      const active = validSessions.filter(s => s.status === 'active');
      const closed = validSessions.filter(s => s.status === 'closed');

      const menuBadge = $('#chatMenuBadge');
      if (menuBadge) {
        menuBadge.textContent = waiting.length;
        menuBadge.hidden = waiting.length === 0;
      }
      const waitingCountEl = $('#chatWaitingCount');
      if (waitingCountEl) waitingCountEl.textContent = waiting.length;
      const activeCountEl = $('#chatActiveCount');
      if (activeCountEl) activeCountEl.textContent = active.length;

      const waitingList = $('#chatWaitingList');
      if (waitingList) {
        waitingList.innerHTML = waiting.length ? waiting.map(s => `
          <div class="chat-session-item waiting-item">
            <div class="chat-session-info">
              <strong>${safe(s.server_name || 'Servidor')}</strong>
              <small>SIAPE: ${safe(s.server_siape || '—')} • Aberto ${fmt(s.created_at)}</small>
              <p>${safe(s.subject || 'Dúvida geral')}</p>
            </div>
            <div class="chat-waiting-item-actions" style="display:flex;gap:6px;align-items:center;">
              <button class="primary chat-attend-btn" type="button" data-attend-session="${s.id}">Atender agora →</button>
              <button class="secondary chat-dismiss-btn" type="button" data-dismiss-session="${s.id}" title="Descartar esta solicitação">Descartar</button>
            </div>
          </div>
        `).join('') : '<p class="empty">Nenhum servidor aguardando no momento.</p>';

        waitingList.querySelectorAll('[data-attend-session]').forEach(b => {
          b.onclick = () => openAdminChatRoom(b.dataset.attendSession);
        });
        waitingList.querySelectorAll('[data-dismiss-session]').forEach(b => {
          b.onclick = async () => {
            const sid = b.dataset.dismissSession;
            b.disabled = true;
            b.textContent = '…';
            try {
              await sb.rpc('close_chat_session', { p_session_id: sid, p_notes: 'Cancelado pelo técnico' });
            } catch {
              await sb.from('chat_sessions').update({ status: 'closed', closed_at: new Date().toISOString(), notes: 'Cancelado pelo técnico' }).eq('id', sid);
            }
            toast('Solicitação removida da fila.');
            renderChatAdminDashboard();
          };
        });
      }

      const activeList = $('#chatActiveList');
      if (activeList) {
        activeList.innerHTML = active.length ? active.map(s => `
          <div class="chat-session-item active-item">
            <div class="chat-session-info">
              <strong>${safe(s.server_name || 'Servidor')}</strong>
              <small>Técnico: ${safe(s.technician_name || 'Em atendimento')} • Iniciado ${fmt(s.started_at || s.created_at)}</small>
              <p>${safe(s.subject || 'Dúvida geral')}</p>
            </div>
            <div class="chat-active-item-actions">
              <button class="secondary chat-open-btn" type="button" data-open-session="${s.id}">Abrir conversa →</button>
            </div>
          </div>
        `).join('') : '<p class="empty">Nenhum chat ativo no momento.</p>';

        activeList.querySelectorAll('[data-open-session]').forEach(b => {
          b.onclick = () => openAdminChatRoom(b.dataset.openSession);
        });
      }

      const historyList = $('#chatHistoryList');
      if (historyList) {
        historyList.innerHTML = closed.length ? `
          <div class="chat-history-row chat-history-head">
            <span>Servidor</span>
            <span>Assunto</span>
            <span>Técnico</span>
            <span>Protocolo</span>
            <span>Data/Hora</span>
          </div>
          ${closed.map(s => `
            <div class="chat-history-row">
              <strong>${safe(s.server_name || '—')}</strong>
              <span>${safe(s.subject || '—')}</span>
              <span>${safe(s.technician_name || '—')}</span>
              <strong>${s.ticket_protocol ? `<span class="badge done">${s.ticket_protocol}</span>` : '<span class="badge">Sem chamado</span>'}</strong>
              <small>${fmt(s.closed_at || s.created_at)}</small>
            </div>
          `).join('')}
        ` : '<p class="empty">Nenhum atendimento finalizado registrado ainda.</p>';
      }
    } catch (e) {
      console.warn('Erro ao carregar painel de chat', e);
      const historyList = $('#chatHistoryList');
      if (historyList) {
        historyList.innerHTML = '<p class="empty">Não foi possível carregar o histórico de atendimentos.</p>';
      }
    }
  }

  async function initStaffChatStatus() {
    if (!state.profile || state.profile.role !== 'tecnico') {
      const wrap = document.querySelectorAll('.staff-chat-toggle-wrap');
      wrap.forEach(w => w.hidden = true);
      return;
    }
    const toggle = $('#staffChatToggle');
    const label = $('#staffChatToggleLabel');
    if (!toggle || !label) return;

    try {
      const { data: row } = await sb.from('staff_chat_status').select('is_online, last_heartbeat').eq('profile_id', state.profile.id).maybeSingle();
      const savedPreference=localStorage.getItem(staffChatPreferenceKey(state.profile.id));
      const isOnline=savedPreference===null?Boolean(row?.is_online):savedPreference==='true';
      staffChatDesiredOnline=isOnline;
      toggle.checked = isOnline;
      label.innerHTML = `Chat: <strong>${isOnline ? 'Online' : 'Offline'}</strong>`;

      if (isOnline) {
        await renewStaffChatPresence();
        startStaffHeartbeat();
      }
      bindStaffChatPresenceRecovery();
      scheduleStaffOnlinePrompt();
    } catch (e) {
      console.warn('Falha ao carregar status do técnico', e);
    }

    toggle.onchange = async () => {
      const nextOnline = toggle.checked;
      staffChatDesiredOnline=nextOnline;
      localStorage.setItem(staffChatPreferenceKey(state.profile.id),String(nextOnline));
      label.innerHTML = `Chat: <strong>${nextOnline ? 'Online' : 'Offline'}</strong>`;
      try {
        const { error } = await sb.rpc('set_staff_chat_status', { p_online: nextOnline });
        if (error) throw error;
        if (nextOnline) {
          startStaffHeartbeat();
          stopStaffOnlinePrompt();
          toast('Você está ONLINE para atendimento via chat.');
        } else {
          stopStaffHeartbeat();
          scheduleStaffOnlinePrompt();
          toast('Você está OFFLINE para atendimento via chat.');
        }
        await loadChatAvailability();
        renderChatAdminDashboard();
      } catch (err) {
        staffChatDesiredOnline=!nextOnline;
        localStorage.setItem(staffChatPreferenceKey(state.profile.id),String(!nextOnline));
        toggle.checked = !nextOnline;
        label.innerHTML = `Chat: <strong>${!nextOnline ? 'Online' : 'Offline'}</strong>`;
        fail(err, 'Não foi possível alterar seu status.');
      }
    };
  }

  function staffChatPreferenceKey(profileId){return 'labinfo_staff_chat_online_'+profileId}

  function staffOnlinePromptKey(profileId){
    return `labinfo_staff_online_prompt_${profileId}_${new Date().toLocaleDateString('sv-SE')}`;
  }

  function stopStaffOnlinePrompt(){
    if(staffOnlinePromptTimer){
      clearTimeout(staffOnlinePromptTimer);
      staffOnlinePromptTimer=null;
    }
    const modal=$('#staffOnlinePrompt');
    if(modal){
      modal.hidden=true;
      if(!document.querySelector('.modal-backdrop:not([hidden])'))document.body.classList.remove('modal-open');
    }
  }

  function scheduleStaffOnlinePrompt(delay=12000){
    if(!state.profile||state.profile.role!=='tecnico'||staffChatDesiredOnline)return;
    if(staffOnlinePromptTimer)clearTimeout(staffOnlinePromptTimer);
    staffOnlinePromptTimer=setTimeout(showStaffOnlinePrompt,delay);
  }

  function showStaffOnlinePrompt(){
    staffOnlinePromptTimer=null;
    if(!state.profile||state.profile.role!=='tecnico'||staffChatDesiredOnline||document.hidden)return;
    const key=staffOnlinePromptKey(state.profile.id);
    let stateForDay={count:0,lastDismissedAt:0};
    try{stateForDay={...stateForDay,...JSON.parse(localStorage.getItem(key)||'{}')}}catch(_){/* preferência inválida */}
    const now=Date.now();
    // No máximo três lembretes no dia, espaçados por duas horas após cada recusa.
    if(stateForDay.count>=3 || (stateForDay.lastDismissedAt && now-stateForDay.lastDismissedAt<2*60*60*1000)){
      const remaining=Math.max(0,2*60*60*1000-(now-(stateForDay.lastDismissedAt||now)));
      if(stateForDay.count<3)scheduleStaffOnlinePrompt(remaining||2*60*60*1000);
      return;
    }
    let modal=$('#staffOnlinePrompt');
    if(!modal){
      document.body.insertAdjacentHTML('beforeend',`<div id="staffOnlinePrompt" class="modal-backdrop staff-online-prompt-backdrop" hidden><div class="card staff-online-prompt-card" role="dialog" aria-modal="true" aria-labelledby="staffOnlinePromptTitle"><span class="eyebrow">CHAT AO VIVO</span><h2 id="staffOnlinePromptTitle">Quer ficar online?</h2><p>Há servidores que podem precisar de atendimento imediato. Você precisa confirmar sua disponibilidade para aparecer no chat ao vivo.</p><div class="modal-actions"><button id="staffOnlinePromptNo" class="secondary" type="button">Agora não</button><button id="staffOnlinePromptYes" class="primary" type="button">Sim, ficar online</button></div></div></div>`);
      modal=$('#staffOnlinePrompt');
      $('#staffOnlinePromptNo').onclick=()=>dismissStaffOnlinePrompt(false);
      $('#staffOnlinePromptYes').onclick=()=>dismissStaffOnlinePrompt(true);
    }
    modal.hidden=false;
    document.body.classList.add('modal-open');
  }

  function dismissStaffOnlinePrompt(goOnline){
    if(!state.profile)return;
    const key=staffOnlinePromptKey(state.profile.id);
    let stateForDay={count:0,lastDismissedAt:0};
    try{stateForDay={...stateForDay,...JSON.parse(localStorage.getItem(key)||'{}')}}catch(_){/* preferência inválida */}
    stateForDay.count=Math.min(3,(Number(stateForDay.count)||0)+1);
    stateForDay.lastDismissedAt=Date.now();
    localStorage.setItem(key,JSON.stringify(stateForDay));
    const modal=$('#staffOnlinePrompt');
    if(modal)modal.hidden=true;
    document.body.classList.remove('modal-open');
    if(goOnline){
      const toggle=$('#staffChatToggle');
      if(toggle&&!toggle.checked){
        toggle.checked=true;
        toggle.dispatchEvent(new Event('change'));
      }
      return;
    }
    if(stateForDay.count<3)scheduleStaffOnlinePrompt(2*60*60*1000);
  }

  async function renewStaffChatPresence(){
    if(!state.profile||state.profile.role!=='tecnico'||!staffChatDesiredOnline)return;
    try{
      const {error}=await sb.rpc('set_staff_chat_status',{p_online:true});
      if(error)throw error;
    }catch(e){
      console.warn('Falha ao renovar presença do técnico',e);
    }
  }

  function bindStaffChatPresenceRecovery(){
    if(staffChatPresenceListenersBound)return;
    staffChatPresenceListenersBound=true;
    const recover=()=>{if(!document.hidden)renewStaffChatPresence()};
    document.addEventListener('visibilitychange',recover);
    window.addEventListener('focus',recover);
    window.addEventListener('online',renewStaffChatPresence);
    window.addEventListener('storage',event=>{
      if(!state.profile||event.key!==staffChatPreferenceKey(state.profile.id))return;
      staffChatDesiredOnline=event.newValue==='true';
      const toggle=$('#staffChatToggle'),label=$('#staffChatToggleLabel');
      if(toggle)toggle.checked=staffChatDesiredOnline;
      if(label)label.innerHTML=`Chat: <strong>${staffChatDesiredOnline?'Online':'Offline'}</strong>`;
      staffChatDesiredOnline?startStaffHeartbeat():stopStaffHeartbeat();
    });
  }

  function startStaffHeartbeat() {
    stopStaffHeartbeat();
    renewStaffChatPresence();
    staffHeartbeatTimer=setInterval(renewStaffChatPresence,45000);
  }

  function stopStaffHeartbeat() {
    if (staffHeartbeatTimer) {
      clearInterval(staffHeartbeatTimer);
      staffHeartbeatTimer = null;
    }
  }

  let staffIncomingPollTimer = null;
  let staffIncomingChannel = null;

  function listenIncomingChats() {
    if (!state.profile || (state.profile.role !== 'tecnico' && state.profile.role !== 'supervisor')) return;

    if (staffIncomingPollTimer) clearInterval(staffIncomingPollTimer);
    staffIncomingPollTimer = setInterval(async () => {
      if (!state.profile || document.hidden) return;

      // Se há um alerta tocando na tela, checa se a sessão ainda está em espera
      if (incomingAlertSessionId) {
        try {
          const { data: currentSess } = await sb.from('chat_sessions').select('id, status, technician_id').eq('id', incomingAlertSessionId).maybeSingle();
          if (!currentSess || currentSess.status !== 'waiting') {
            stopIncomingCallRingtone();
            $('#incomingChatAlert').hidden = true;
            document.body.classList.remove('modal-open');
            if (currentSess && currentSess.technician_id && currentSess.technician_id !== state.profile.id) {
              toast('O chamado foi assumido por outro técnico.');
            }
            incomingAlertSessionId = null;
          }
        } catch (e) {
          console.warn('Checagem de alerta ativo:', e);
        }
      }

      const chatSec = $('#chatAdminSection');
      if (chatSec && !chatSec.hidden) {
        renderChatAdminDashboard();
      }
    }, 1500);

    if (staffIncomingChannel) {
      sb.removeChannel(staffIncomingChannel);
      staffIncomingChannel = null;
    }

    staffIncomingChannel = sb.channel('labinfo-staff-chat-incoming')
      .on('broadcast', { event: 'chat_session_accepted' }, (payload) => {
        const p = payload.payload;
        if (p && incomingAlertSessionId === p.session_id) {
          if (!state.profile || p.technician_id !== state.profile.id) {
            stopIncomingCallRingtone();
            $('#incomingChatAlert').hidden = true;
            document.body.classList.remove('modal-open');
            toast(`O atendimento foi assumido por ${p.technician_name || 'outro técnico'}.`);
            incomingAlertSessionId = null;
          }
        }
        renderChatAdminDashboard();
      })
      .on('postgres_changes', { event: '*', schema: 'public', table: 'chat_sessions' }, async (payload) => {
        renderChatAdminDashboard();
        if (payload.eventType === 'INSERT' && payload.new.status === 'waiting') {
          const toggle = $('#staffChatToggle');
          if (toggle && toggle.checked) {
            const { data: server } = await sb.from('servers').select('full_name, siape, email').eq('id', payload.new.server_id).maybeSingle();
            incomingAlertSessionId = payload.new.id;
            const alert = $('#incomingChatAlert');
            const nameEl = $('#incomingChatServerName');
            const siapeEl = $('#incomingChatServerSiape');
            const subEl = $('#incomingChatSubjectText');
            if (nameEl) nameEl.textContent = server ? server.full_name : 'Novo Servidor';
            if (siapeEl) siapeEl.textContent = server ? `SIAPE: ${server.siape} • ${server.email}` : 'Servidor cadastrado';
            if (subEl) subEl.textContent = payload.new.subject || 'Atendimento via chat';
            if (alert) {
              alert.hidden = false;
              document.body.classList.add('modal-open');
              startIncomingCallRingtone();
            }
          }
        } else if (incomingAlertSessionId && (payload.new?.id === incomingAlertSessionId || payload.old?.id === incomingAlertSessionId)) {
          if (payload.new?.status !== 'waiting') {
            stopIncomingCallRingtone();
            $('#incomingChatAlert').hidden = true;
            document.body.classList.remove('modal-open');
            if (payload.new?.technician_id && payload.new?.technician_id !== state.profile?.id) {
              toast('O chamado foi assumido por outro técnico.');
            }
            incomingAlertSessionId = null;
          }
        }
      })
      .subscribe();

    renderChatAdminDashboard();
  }

  $('#dismissIncomingChatBtn')?.addEventListener('click', () => {
    stopIncomingCallRingtone();
    $('#incomingChatAlert').hidden = true;
    document.body.classList.remove('modal-open');
    incomingAlertSessionId = null;
  });

  $('#incomingChatAlert')?.addEventListener('click', (e) => {
    if (e.target === $('#incomingChatAlert')) {
      stopIncomingCallRingtone();
      $('#incomingChatAlert').hidden = true;
      document.body.classList.remove('modal-open');
      incomingAlertSessionId = null;
    }
  });

  $('#acceptIncomingChatBtn')?.addEventListener('click', async () => {
    if (!incomingAlertSessionId) return;
    const sessionId = incomingAlertSessionId;
    stopIncomingCallRingtone();
    $('#incomingChatAlert').hidden = true;
    document.body.classList.remove('modal-open');
    incomingAlertSessionId = null;
    await openAdminChatRoom(sessionId);
  });

  async function openAdminChatRoom(sessionId) {
    try {
      const { data: acceptRes, error: acceptErr } = await sb.rpc('accept_chat_session', { p_session_id: sessionId });
      if (acceptErr) {
        console.warn('Aviso no accept_chat_session:', acceptErr);
      }

      // Notifica todos os outros técnicos em tempo real que a chamada foi aceita
      try {
        if (staffIncomingChannel) {
          staffIncomingChannel.send({
            type: 'broadcast',
            event: 'chat_session_accepted',
            payload: {
              session_id: sessionId,
              technician_id: state.profile?.id,
              technician_name: state.profile?.full_name || 'Outro técnico'
            }
          }).catch(() => {});
        }
      } catch (e) {
        console.warn('Broadcast chat aceito:', e);
      }

      const { data: session, error: sessErr } = await sb.from('chat_sessions').select('*, servers(*)').eq('id', sessionId).maybeSingle();
      if (sessErr || !session) {
        throw sessErr || new Error('Sessão de chat não encontrada.');
      }
      activeAdminChatSession = session;
      activeAdminChatMessages = [];

      const parsedAccept = Array.isArray(acceptRes) ? acceptRes[0] : (acceptRes || {});
      const serverName = session.servers?.full_name || parsedAccept.server_name || 'Servidor';
      const serverSiape = session.servers?.siape || parsedAccept.server_siape || '—';
      const serverEmail = session.servers?.email || parsedAccept.server_email || '—';
      const subject = session.subject || parsedAccept.subject || 'Atendimento via chat';

      $('#adminChatModalTitle').textContent = serverName;
      $('#adminChatServerMeta').textContent = `SIAPE: ${serverSiape} • ${serverEmail} • ${subject}`;

      $('#adminChatModal').hidden = false;
      document.body.classList.add('modal-open');

      await loadAdminChatMessages(sessionId);
      subscribeAdminChatMessages(sessionId);
      renderChatAdminDashboard();
    } catch (err) {
      console.error('Falha ao abrir atendimento do chat:', err);
      fail(err, 'Não foi possível aceitar a sessão de chat.');
    }
  }

  async function loadAdminChatMessages(sessionId) {
    const list = $('#adminChatMessagesList');
    list.innerHTML = '<p class="empty">Carregando mensagens...</p>';
    const { data: msgs, error } = await sb.from('chat_messages').select('*').eq('session_id', sessionId).order('created_at', { ascending: true });
    if (error) return fail(error);
    activeAdminChatMessages = msgs || [];
    renderAdminChatMessages();
  }

  function renderAdminChatMessages() {
    const list = $('#adminChatMessagesList');
    if (!list) return;
    list.innerHTML = activeAdminChatMessages.map(m => {
      const isSystem = m.sender_type === 'system';
      const isMine = m.sender_type === 'technician';
      const time = fmt(m.created_at);
      if (isSystem) {
        return `<div class="chat-bubble system"><span>${safe(m.message)}</span></div>`;
      }
      return `
        <div class="chat-bubble ${isMine ? 'mine' : 'other'}">
          <span class="chat-bubble-author">${safe(m.sender_name)}</span>
          <div class="chat-bubble-text">${safe(m.message)}</div>
          <time class="chat-bubble-meta">${time}</time>
        </div>
      `;
    }).join('');
    list.scrollTop = list.scrollHeight;
  }

  let adminChatPollTimer = null;

  function stopAdminChatPolling() {
    if (adminChatPollTimer) {
      clearInterval(adminChatPollTimer);
      adminChatPollTimer = null;
    }
  }

  function startAdminChatPolling(sessionId) {
    stopAdminChatPolling();
    adminChatPollTimer = setInterval(async () => {
      if (!activeAdminChatSession) {
        stopAdminChatPolling();
        return;
      }
      try {
        const { data: msgs } = await sb.from('chat_messages').select('*').eq('session_id', sessionId).order('created_at', { ascending: true });
        if (msgs && (msgs.length !== activeAdminChatMessages.length || (msgs.length > 0 && msgs[msgs.length - 1].id !== activeAdminChatMessages[activeAdminChatMessages.length - 1]?.id))) {
          activeAdminChatMessages = msgs;
          renderAdminChatMessages();
        }
      } catch (e) {
        console.warn('Polling de chat admin:', e);
      }
    }, 2000);
  }

  function subscribeAdminChatMessages(sessionId) {
    if (adminChatChannel) {
      sb.removeChannel(adminChatChannel);
      adminChatChannel = null;
    }
    adminChatChannel = sb.channel('admin-chat-room-' + sessionId)
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'chat_messages', filter: `session_id=eq.${sessionId}` }, (payload) => {
        if (!activeAdminChatMessages.some(m => m.id === payload.new.id)) {
          activeAdminChatMessages.push(payload.new);
          renderAdminChatMessages();
          if (payload.new.sender_type === 'server') {
            playChatNotificationSound();
          }
        }
      })
      .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'chat_sessions', filter: `id=eq.${sessionId}` }, (payload) => {
        if (payload.new.status === 'closed') {
          toast('Este chat foi finalizado.');
          stopAdminChatPolling();
        }
      })
      .subscribe();

    startAdminChatPolling(sessionId);
  }

  $('#adminChatMessageForm')?.addEventListener('submit', async (e) => {
    e.preventDefault();
    if (!activeAdminChatSession) return;
    const input = $('#adminChatMessageInput');
    const msg = input.value.trim();
    if (!msg) return;
    input.value = '';

    const { error } = await sb.rpc('send_chat_message', {
      p_session_id: activeAdminChatSession.id,
      p_sender_type: 'technician',
      p_message: msg
    });
    if (error) {
      input.value = msg;
      fail(error, 'Erro ao enviar mensagem.');
    } else {
      loadAdminChatMessages(activeAdminChatSession.id);
    }
  });

  $('#closeAdminChatModal')?.addEventListener('click', () => {
    stopAdminChatPolling();
    $('#adminChatModal').hidden = true;
    document.body.classList.remove('modal-open');
  });

  // Modal: Gerar Chamado Oficial do Chat
  $('#adminFinishChatBtn')?.addEventListener('click', () => {
    if (!activeAdminChatSession) return;

    const transcript = activeAdminChatMessages.map(m => {
      const time = fmt(m.created_at);
      return `[${time}] ${m.sender_name}: ${m.message}`;
    }).join('\n');

    $('#chatTicketTranscript').value = transcript || 'Nenhuma mensagem registrada.';
    $('#chatTicketTitle').value = `Atendimento via Chat: ${activeAdminChatSession.subject || 'Dúvida/Suporte'}`;
    $('#chatTicketResolution').value = '';

    $('#chatTicketLab').innerHTML = '<option value="">Selecione o local</option>' + data.labs.map(l => `<option value="${l.id}">${safe(l.name)}</option>`).join('');
    $('#chatTicketCategory').innerHTML = '<option value="">Selecione a categoria</option>' + data.categories.map(c => `<option value="${c.id}">${safe(c.name)}</option>`).join('');

    $('#chatToTicketModal').hidden = false;
  });

  $('#closeChatToTicketModal')?.addEventListener('click', () => {
    $('#chatToTicketModal').hidden = true;
  });
  $('#cancelChatToTicket')?.addEventListener('click', () => {
    $('#chatToTicketModal').hidden = true;
  });

  $('#chatTicketStatus')?.addEventListener('change', (e) => {
    const isDone = e.target.value === 'Concluído';
    $('#chatTicketResolutionLabel').hidden = !isDone;
    $('#chatTicketResolution').required = isDone;
  });

  $('#chatToTicketForm')?.addEventListener('submit', async (e) => {
    e.preventDefault();
    if (!activeAdminChatSession) return;
    const button = e.target.querySelector('[type="submit"]');
    button.disabled = true;
    button.textContent = 'Gerando chamado…';

    const labId = $('#chatTicketLab').value || null;
    const catId = $('#chatTicketCategory').value || null;
    const title = $('#chatTicketTitle').value.trim();
    const status = $('#chatTicketStatus').value;
    const resolution = $('#chatTicketResolution').value.trim();

    try {
      const { data: ticketRes, error } = await sb.rpc('create_ticket_from_chat', {
        p_session_id: activeAdminChatSession.id,
        p_lab: labId,
        p_category: catId,
        p_title: title,
        p_resolution: resolution,
        p_status: status
      });
      if (error) throw error;

      const created = Array.isArray(ticketRes) ? ticketRes[0] : (ticketRes || {});
      $('#chatToTicketModal').hidden = true;
      $('#adminChatModal').hidden = true;
      document.body.classList.remove('modal-open');

      if (adminChatChannel) {
        sb.removeChannel(adminChatChannel);
        adminChatChannel = null;
      }
      activeAdminChatSession = null;

      await loadAdmin();
      renderChatAdminDashboard();
      toast(`Chamado ${created?.protocol || ''} criado com sucesso a partir do chat!`);
    } catch (err) {
      fail(err, 'Não foi possível gerar o chamado do atendimento.');
    } finally {
      button.disabled = false;
      button.textContent = 'Confirmar e gerar protocolo →';
    }
  });

  // 4. Lado do Servidor / Docente (Público)
  let chatIdentifyTimer;
  $('#chatSiape')?.addEventListener('input', () => {
    clearTimeout(chatIdentifyTimer);
    currentPublicServer = null;
    const hint = $('#chatIdentity');
    hint.textContent = 'Validando SIAPE…';
    hint.className = 'field-hint';

    chatIdentifyTimer = setTimeout(async () => {
      const siape = $('#chatSiape').value.trim();
      if (siape.length < 5) {
        hint.textContent = 'Digite seu SIAPE para validação automática.';
        return;
      }
      const { data: rows, error } = await sb.rpc('identify_server', { p_siape: siape });
      const server = rows?.[0];
      if (error || !server) {
        hint.textContent = 'SIAPE não localizado ou inativo. Apenas servidores cadastrados podem iniciar chat.';
        hint.className = 'field-hint error';
        return;
      }
      currentPublicServer = server;
      hint.textContent = `${server.full_name} • ${server.email}`;
      hint.className = 'field-hint found';
    }, 350);
  });

  $('#chatPublicForm')?.addEventListener('submit', async (e) => {
    e.preventDefault();
    if (!currentPublicServer) {
      return toast('Informe um SIAPE válido e cadastrado para continuar.');
    }
    const siape = $('#chatSiape').value.trim();
    const subject = $('#chatSubject').value.trim();
    const button = $('#startChatButton');
    button.disabled = true;
    button.textContent = 'Iniciando atendimento…';

    try {
      const { data: res, error } = await sb.rpc('request_chat_session', {
        p_siape: siape,
        p_subject: subject
      });
      if (error) throw error;

      const session = res?.[0];
      currentPublicChatSession = session;

      $('#chatIdentifyCard').hidden = true;
      $('#chatWaitingCard').hidden = false;
      $('#chatWaitingServerName').textContent = currentPublicServer.full_name;
      $('#chatWaitingSubject').textContent = subject;

      subscribePublicChatSession(session.session_id);
    } catch (err) {
      fail(err, 'Não foi possível solicitar o chat.');
    } finally {
      button.disabled = false;
      button.innerHTML = 'Iniciar atendimento ao vivo <span>→</span>';
    }
  });

  $('#cancelChatRequest')?.addEventListener('click', async () => {
    if (!currentPublicChatSession) return;
    await sb.rpc('close_chat_session', { p_session_id: currentPublicChatSession.session_id, p_notes: 'Cancelado pelo servidor antes do atendimento.' });
    cleanupPublicChat();
    $('#chatWaitingCard').hidden = true;
    $('#chatIdentifyCard').hidden = false;
    toast('Solicitação de chat cancelada.');
  });

  let publicChatMessages = [];
  let publicChatPollTimer = null;

  function stopPublicChatPolling() {
    if (publicChatPollTimer) {
      clearInterval(publicChatPollTimer);
      publicChatPollTimer = null;
    }
  }

  function startPublicChatPolling(sessionId) {
    stopPublicChatPolling();
    publicChatPollTimer = setInterval(async () => {
      if (!currentPublicChatSession) {
        stopPublicChatPolling();
        return;
      }
      try {
        const { data: sess, error: rpcErr } = await sb.rpc('get_public_chat_session', { p_session_id: sessionId });
        if (!rpcErr && sess) {
          if (sess.status === 'active') {
            $('#chatRoomTechName').textContent = sess.technician_name || 'Técnico de Plantão';
            if (!$('#chatWaitingCard').hidden) {
              $('#chatWaitingCard').hidden = true;
              $('#chatActiveCard').hidden = false;
              playChatNotificationSound();
            }
          } else if (sess.status === 'closed') {
            const protocol = sess.protocol || 'Registrado';
            const protocolEl = $('#chatGeneratedProtocol');
            if (protocolEl) protocolEl.textContent = protocol;
            $('#chatActiveCard').hidden = true;
            $('#chatWaitingCard').hidden = true;
            $('#chatEndedCard').hidden = false;
            stopPublicChatPolling();
          }
        } else if (rpcErr) {
          // get_public_chat_session é o único caminho de leitura pública da sessão
          // (chat_sessions não aceita mais SELECT direto de anon). Sem resposta da
          // RPC, apenas registra e tenta de novo no próximo ciclo de polling.
          console.warn('Falha ao consultar sessão pública de chat:', rpcErr);
        }

        await loadPublicChatMessages(sessionId);
      } catch (e) {
        console.warn('Polling de chat público:', e);
      }
    }, 1500);
  }

  function subscribePublicChatSession(sessionId) {
    // O lado público não tem mais leitura direta de chat_sessions/chat_messages
    // (endurecimento de RLS de 26/08/2026 — antes a policy era "using(true)" e
    // expunha todas as conversas a qualquer visitante). Sem SELECT direto,
    // postgres_changes não entrega eventos para o papel anon, então o
    // acompanhamento público passa a depender só do polling a cada 1,5s em
    // startPublicChatPolling, que já usa exclusivamente as RPCs públicas
    // (get_public_chat_session / get_public_chat_messages).
    if (publicChatChannel) {
      sb.removeChannel(publicChatChannel);
      publicChatChannel = null;
    }

    loadPublicChatMessages(sessionId);
    startPublicChatPolling(sessionId);
  }

  async function loadPublicChatMessages(sessionId) {
    try {
      const { data: msgs } = await sb.rpc('get_public_chat_messages', { p_session_id: sessionId });
      if (msgs) {
        const hasNew = msgs.length !== publicChatMessages.length || (msgs.length > 0 && msgs[msgs.length - 1].id !== publicChatMessages[publicChatMessages.length - 1]?.id);
        publicChatMessages = msgs;
        if (hasNew) {
          renderPublicChatMessages();
          const techMsg = msgs.find(m => m.sender_type === 'technician');
          if (techMsg) {
            $('#chatRoomTechName').textContent = techMsg.sender_name || 'Técnico de Plantão';
          }
          if (msgs.some(m => m.sender_type === 'technician' || (m.sender_type === 'system' && m.message.includes('entrou na sala')))) {
            if (!$('#chatWaitingCard').hidden) {
              $('#chatWaitingCard').hidden = true;
              $('#chatActiveCard').hidden = false;
            }
          }
        }
      }
    } catch (e) {
      console.warn('Erro ao carregar mensagens públicas:', e);
    }
  }

  function renderPublicChatMessages() {
    const list = $('#chatMessagesList');
    if (!list) return;
    list.innerHTML = publicChatMessages.map(m => {
      const isSystem = m.sender_type === 'system';
      const isMine = m.sender_type === 'server';
      const time = fmt(m.created_at);
      if (isSystem) {
        return `<div class="chat-bubble system"><span>${safe(m.message)}</span></div>`;
      }
      return `
        <div class="chat-bubble ${isMine ? 'mine' : 'other'}">
          <span class="chat-bubble-author">${safe(m.sender_name)}</span>
          <div class="chat-bubble-text">${safe(m.message)}</div>
          <time class="chat-bubble-meta">${time}</time>
        </div>
      `;
    }).join('');
    list.scrollTop = list.scrollHeight;
  }

  $('#chatMessageForm')?.addEventListener('submit', async (e) => {
    e.preventDefault();
    if (!currentPublicChatSession) return;
    const input = $('#chatMessageInput');
    const msg = input.value.trim();
    if (!msg) return;
    input.value = '';

    const { error } = await sb.rpc('send_chat_message', {
      p_session_id: currentPublicChatSession.session_id,
      p_sender_type: 'server',
      p_message: msg,
      p_sender_name: currentPublicServer?.full_name || 'Servidor'
    });
    if (error) {
      input.value = msg;
      fail(error, 'Erro ao enviar mensagem.');
    } else {
      loadPublicChatMessages(currentPublicChatSession.session_id);
    }
  });

  $('#endChatPublicBtn')?.addEventListener('click', async () => {
    if (!currentPublicChatSession) return;
    if (!confirm('Deseja realmente encerrar este atendimento?')) return;
    await sb.rpc('close_chat_session', { p_session_id: currentPublicChatSession.session_id });
    stopPublicChatPolling();
    $('#chatActiveCard').hidden = true;
    $('#chatEndedCard').hidden = false;
  });

  $('#chatBackToHomeBtn')?.addEventListener('click', () => {
    cleanupPublicChat();
    window.labinfoShowPublic('home');
  });

  $('#chatViewMyTicketsBtn')?.addEventListener('click', () => {
    const siape = currentPublicServer?.siape || $('#chatSiape')?.value.trim();
    cleanupPublicChat();
    window.labinfoShowPublic('support');
    if (siape) {
      const input = $('#protocolInput');
      if (input) {
        input.value = siape;
        setTimeout(() => $('#protocolButton')?.click(), 150);
      }
    }
  });

  function cleanupPublicChat() {
    stopPublicChatPolling();
    if (publicChatChannel) {
      sb.removeChannel(publicChatChannel);
      publicChatChannel = null;
    }
    currentPublicChatSession = null;
    publicChatMessages = [];
    $('#chatIdentifyCard').hidden = false;
    $('#chatWaitingCard').hidden = true;
    $('#chatActiveCard').hidden = true;
    $('#chatEndedCard').hidden = true;
    $('#chatPublicForm')?.reset();
    $('#chatIdentity').textContent = 'Digite seu SIAPE para validação automática.';
    $('#chatIdentity').className = 'field-hint';
  }

  sb.channel('labinfo-chat-status-watch')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'staff_chat_status' }, () => {
      loadChatAvailability();
    })
    .subscribe();

  // Permite ao técnico complementar chamados recebidos por e-mail antes de
  // iniciar o atendimento. A categoria é obrigatória para manter os relatórios
  // consistentes; o laboratório continua opcional para atendimentos gerais.
  const renderDetailWithTicketEditor = renderDetail;
  renderDetail = function () {
    renderDetailWithTicketEditor();
    if (!selected || state.profile?.role !== 'tecnico' || selected.status === 'Concluído') return;

    const details = $('#ticketDetail .detail-data');
    if (!details) return;
    const missingCategory = !selected.categoryId;
    const categoryOptions = data.categories.filter(item => item.active !== false).map(item =>
      `<option value="${safe(item.id)}" ${item.id === selected.categoryId ? 'selected' : ''}>${safe(item.name)}</option>`
    ).join('');
    const labOptions = data.labs.filter(item => item.active !== false).map(item =>
      `<option value="${safe(item.id)}" ${item.id === selected.labId ? 'selected' : ''}>${safe(item.name)}</option>`
    ).join('');

    details.insertAdjacentHTML('afterend', `
      <section class="ticket-edit-panel ${missingCategory ? 'is-required' : ''}">
        <button id="toggleTicketEditor" class="ticket-edit-toggle" type="button" aria-expanded="${missingCategory}">
          <span><strong>${missingCategory ? 'Complete as informações para iniciar' : 'Editar informações do chamado'}</strong><small>${missingCategory ? 'Selecione ao menos uma categoria.' : 'Título, descrição, categoria e laboratório.'}</small></span>
          <b>${missingCategory ? '−' : '+'}</b>
        </button>
        <form id="ticketEditForm" ${missingCategory ? '' : 'hidden'}>
          <div class="field-row">
            <label>Categoria <select id="ticketEditCategory" required><option value="">Selecione</option>${categoryOptions}</select></label>
            <label>Laboratório <select id="ticketEditLab"><option value="">Não informado</option>${labOptions}</select></label>
          </div>
          <label>Título do chamado<input id="ticketEditTitle" maxlength="100" value="${safe(selected.title)}" required></label>
          <label>Descrição<textarea id="ticketEditDescription" maxlength="2000" rows="4" required>${safe(selected.description || '')}</textarea></label>
          <div class="ticket-edit-actions"><button id="cancelTicketEdit" class="secondary" type="button">Cancelar</button><button class="primary" type="submit">Salvar informações</button></div>
        </form>
      </section>`);

    const panel = $('#ticketDetail .ticket-edit-panel');
    const form = $('#ticketEditForm');
    const toggle = $('#toggleTicketEditor');
    const setExpanded = expanded => {
      form.hidden = !expanded;
      toggle.setAttribute('aria-expanded', String(expanded));
      toggle.querySelector('b').textContent = expanded ? '−' : '+';
    };
    toggle.onclick = () => setExpanded(form.hidden);
    $('#cancelTicketEdit').onclick = () => setExpanded(false);
    form.onsubmit = async event => {
      event.preventDefault();
      const categoryId = $('#ticketEditCategory').value;
      if (!categoryId) return toast('Selecione uma categoria para o chamado.');
      const labId = $('#ticketEditLab').value || null;
      const title = $('#ticketEditTitle').value.trim();
      const description = $('#ticketEditDescription').value.trim();
      const save = form.querySelector('.primary');
      save.disabled = true; save.textContent = 'Salvando…';
      const now = new Date().toISOString();
      const result = await sb.from('tickets').update({category_id:categoryId,lab_id:labId,title,description,updated_at:now}).eq('id',selected.dbId);
      if (result.error) { save.disabled = false; save.textContent = 'Salvar informações'; return fail(result.error, 'Não foi possível atualizar o chamado.'); }
      const category = data.categories.find(item => item.id === categoryId);
      const lab = data.labs.find(item => item.id === labId);
      selected.categoryId = categoryId; selected.category = category?.name || 'Sem categoria';
      selected.labId = labId; selected.lab = lab?.name || 'Não informado';
      selected.title = title; selected.description = description;
      const history = await sb.from('ticket_updates').insert({ticket_id:selected.dbId,author_id:state.profile.id,message:'Informações do chamado atualizadas pela equipe técnica.',kind:'status'});
      if (history.error) console.error('Chamado atualizado, mas o histórico não foi registrado', history.error);
      renderTickets(); renderDetail(); toast('Informações do chamado atualizadas.');
    };

    const assign = $('#assign');
    if (assign) {
      const startAssignment = assign.onclick;
      assign.onclick = event => {
        if (!selected.categoryId) {
          setExpanded(true); panel.scrollIntoView({behavior:'smooth',block:'center'}); $('#ticketEditCategory').focus();
          return toast('Informe a categoria antes de iniciar o atendimento.');
        }
        return startAssignment?.call(assign, event);
      };
    }
  };

  // Chamados simples podem ser encerrados ainda no estado "Recebido". A RPC
  // registra o técnico e o histórico na mesma transação; o gatilho de e-mail
  // observa apenas Recebido -> Concluído e, portanto, não envia "Em atendimento".
  const renderDetailWithDirectCompletion = renderDetail;
  renderDetail = function () {
    renderDetailWithDirectCompletion();
    if (!selected || selected.status !== 'Recebido' || state.profile?.role !== 'tecnico') return;
    const actions = $('#ticketDetail .detail-actions');
    const reply = $('#reply');
    if (!actions || !reply || $('#completeTicketDirectly')) return;
    const button = document.createElement('button');
    button.id = 'completeTicketDirectly';
    button.className = 'secondary direct-completion-button';
    button.type = 'button';
    button.textContent = 'Concluir diretamente';
    actions.append(button);
    button.onclick = async () => {
      if (!selected.categoryId) {
        const editor=$('#ticketEditForm'),toggle=$('#toggleTicketEditor');if(editor)editor.hidden=false;if(toggle){toggle.setAttribute('aria-expanded','true');const marker=toggle.querySelector('b');if(marker)marker.textContent='−'}
        $('#ticketEditCategory')?.focus();
        return toast('Informe a categoria antes de concluir o chamado.');
      }
      const resolution = reply.value.trim();
      if (resolution.length < 5) {
        reply.closest('label').childNodes[0].textContent = 'Solução realizada (será enviada ao servidor)';
        reply.placeholder = 'Descreva objetivamente o que foi realizado e testado...';
        reply.focus();
        return toast('Descreva a solução antes de concluir diretamente.');
      }
      button.disabled = true; button.textContent = 'Concluindo…';
      const ticket = selected;
      const result = await sb.rpc('staff_complete_ticket',{p_ticket:ticket.dbId,p_resolution:resolution,p_direct:true});
      if (result.error) { button.disabled=false; button.textContent='Concluir diretamente'; return fail(result.error,'Não foi possível concluir o chamado.'); }
      let cleanupFailed=false;
      if(ticket.attachments?.length){const storageResult=await sb.storage.from('ticket-attachments').remove(ticket.attachments.map(item=>item.path));if(storageResult.error){cleanupFailed=true;console.error(storageResult.error)}else{const attachmentResult=await sb.from('attachments').delete().eq('ticket_id',ticket.dbId);if(attachmentResult.error){cleanupFailed=true;console.error(attachmentResult.error)}}}
      await loadAdmin();selected=null;$('#ticketDetail').classList.remove('detail-expanded');document.body.classList.remove('detail-open');renderDetail();
      toast(cleanupFailed?'Chamado concluído diretamente e servidor notificado. Alguns anexos exigem limpeza manual.':'Chamado concluído diretamente. Somente o e-mail de conclusão será enviado.');
    };
  };

  // Trata SIAPEs já existentes (inclusive inativos) sempre que o formulário é recriado.
  function installSafeServerRegistration(){const form=$('#registrationForm'),registrationSubmit=form?.onsubmit;if(!form||!registrationSubmit)return;form.onsubmit=async event=>{
    if(regType!=='teachers')return registrationSubmit(event);
    event.preventDefault();setProcessing(true,'Salvando cadastro…');
    try{const entry=Object.fromEntries(new FormData(event.target)),siape=String(entry.siape||'').trim(),email=String(entry.email||'').trim().toLowerCase(),result=await sb.rpc('staff_upsert_server',{p_siape:siape,p_full_name:entry.name,p_email:email});
      if(result.error)return fail(result.error);
      event.target.reset();await loadAdmin();registration();toast(result.data?.reactivated?'Servidor reativado e atualizado.':'Cadastro salvo.');
    }finally{setProcessing(false)}
  }}
  const registrationRenderBase=registration;registration=function(){registrationRenderBase();installSafeServerRegistration()};
  installSafeServerRegistration();
  catalogs();
  loadServiceHours();
  loadChatAvailability();
  confirmFeedbackFromLink();
  if (isAdminRoute) enterAdmin().then(startAdminSynchronization);
})();
