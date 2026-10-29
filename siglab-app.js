(() => {
  const $ = selector => document.querySelector(selector);
  const safe = value => String(value ?? '').replace(/[&<>"']/g, char => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  })[char]);
  const cfg = window.LABINFO_SUPABASE || window.SIGLAB_SUPABASE || {};
  const siteBase = location.hostname.endsWith('.github.io') ? '/siglab' : '';
  const sitePath = route => `${siteBase}/${route ? String(route).replace(/^\/+|\/+$/g, '') + '/' : ''}`;
  let toastTimer = null;
  let currentProfile = null;

  window.toast = message => {
    const element = $('#toast');
    if (!element) return;
    clearTimeout(toastTimer);
    element.textContent = String(message || '');
    element.classList.add('show');
    toastTimer = setTimeout(() => element.classList.remove('show'), 5000);
  };

  const dbConfigured = Boolean(cfg.url && cfg.anonKey && window.supabase);
  const sb = window.siglabDb || (dbConfigured ? window.supabase.createClient(cfg.url, cfg.anonKey) : null);
  window.siglabDb = sb;
  window.labinfoDb = sb;

  if (!dbConfigured) {
    document.body.insertAdjacentHTML('afterbegin', '<div class="db-banner siglab-demo-banner"><strong>Ambiente de demonstração</strong><span>O banco exclusivo do SIGLAB ainda será configurado. A agenda abaixo contém apenas espaços ilustrativos.</span></div>');
  }

  function setPublicView(view, push = true) {
    document.body.classList.remove('admin-route');
    $('#homeView').hidden = view !== 'home';
    $('#reservationsPublicView').hidden = view !== 'reservations';
    $('#adminView').hidden = true;
    $('#adminAccount').hidden = true;
    $('.siglab-public-nav').hidden = false;
    if (push) history.pushState({}, '', view === 'reservations' ? sitePath('reservas') : sitePath(''));
    window.scrollTo(0, 0);
  }

  function openReservations(group = 'all') {
    window.siglabReservationGroup = group;
    if (typeof window.siglabOpenReservationGroup === 'function') window.siglabOpenReservationGroup(group);
    else if (typeof window.labinfoShowPublic === 'function') window.labinfoShowPublic('reservations');
    else setPublicView('reservations');
  }

  $('#headerScheduleButton').onclick = () => openReservations('all');
  $('#homeAdminButton')?.addEventListener('click', () => requestAdmin());
  $('#adminToggle').onclick = () => requestAdmin();
  $('#homeGoogleLogin').onclick = async () => {
    const button = $('#homeGoogleLogin');
    const notice = $('#homeLoginError');
    notice.hidden = true;
    button.disabled = true;
    try {
      if (!sb) throw new Error('Login institucional indisponível no momento.');
      await window.siglabAuth.signIn();
    } catch (error) {
      notice.textContent = 'Não foi possível iniciar o login Google IFMS. Verifique a configuração do provedor no Supabase.';
      notice.hidden = false;
    } finally {
      button.disabled = false;
    }
  };
  $('.siglab-brand').onclick = event => {
    event.preventDefault();
    if ($('#adminView').hidden) setPublicView('home');
  };

  const loginModal = $('#loginModal');
  function openLogin() {
    loginModal.hidden = false;
    document.body.classList.add('modal-open');
    if (!$('#staffGoogleLogin')) {
      const button = document.createElement('button');
      button.id = 'staffGoogleLogin'; button.className = 'primary'; button.type = 'button';
      button.textContent = 'Entrar com a conta Google IFMS';
      button.onclick = () => window.siglabAuth.signIn(sitePath('admin/reservas')).catch(error => toast(error.message));
      loginModal.querySelector('.siglab-login-card').append(button);
    }
  }
  function closeLogin() {
    loginModal.hidden = true;
    document.body.classList.remove('modal-open');
    $('#loginError').textContent = '';
  }
  $('#closeLogin').onclick = closeLogin;
  loginModal.onclick = event => { if (event.target === loginModal) closeLogin(); };

  async function getActiveProfile() {
    if (!sb) return null;
    await window.siglabAuthReady;
    const auth = window.siglabAuth.getState();
    return auth.identity ? auth.staff : null;
  }

  async function requestAdmin() {
    if (!sb) return toast('A área interna será liberada após a configuração do banco exclusivo do SIGLAB.');
    currentProfile = await getActiveProfile();
    if (!currentProfile) {
      const auth = window.siglabAuth.getState();
      if (auth.session) return toast(auth.error || 'Sua conta não possui acesso à área interna.');
      return openLogin();
    }
    await enterAdmin();
  }

  async function enterAdmin() {
    document.body.classList.add('admin-route');
    $('#homeView').hidden = true;
    $('#reservationsPublicView').hidden = true;
    $('#adminView').hidden = false;
    $('.siglab-public-nav').hidden = true;
    $('#adminAccount').hidden = false;
    $('#adminIdentity strong').textContent = currentProfile.full_name || currentProfile.email;
    $('#adminIdentity small').textContent = currentProfile.role === 'supervisor' ? 'Supervisão' : 'Equipe SIGLAB';
    history.pushState({}, '', sitePath('admin/reservas'));
    await window.labinfoReservationsReady;
    await window.labinfoOpenReservations?.();
    window.scrollTo(0, 0);
  }

  $('#logoutButton').onclick = async () => {
    await window.siglabAuth.signOut();
    currentProfile = null;
    setPublicView('home');
    toast('Sessão encerrada.');
  };

  $('#adminMenuButton').onclick = () => {
    const menu = $('#adminMenuDropdown');
    menu.hidden = !menu.hidden;
  };

  function hideAdminSections() {
    document.querySelectorAll('#adminView .admin-section').forEach(section => { section.hidden = true; });
    $('#adminMenuDropdown').hidden = true;
  }

  async function showAdminSection(section) {
    if (section === 'reservations') return window.labinfoOpenReservations?.();
    hideAdminSections();
    const target = section === 'labs' ? $('#labsSection') : $('#serversSection');
    target.hidden = false;
    $('#adminTitle').textContent = section === 'labs' ? 'Laboratórios e espaços' : 'Servidores cadastrados';
    $('#adminSubtitle').textContent = section === 'labs'
      ? 'Defina quais espaços podem aparecer publicamente para reserva.'
      : 'Gerencie quem pode solicitar reservas no portal.';
    if (section === 'labs') await renderLabs();
    else await renderServers();
  }

  $('#adminMenuDropdown').addEventListener('click', event => {
    const button = event.target.closest('[data-section]');
    if (!button) return;
    event.preventDefault();
    showAdminSection(button.dataset.section);
  });

  async function renderLabs() {
    const section = $('#labsSection');
    section.innerHTML = '<div class="card siglab-loading">Carregando laboratórios…</div>';
    const [{ data: labs, error }, { data: sectors, error: sectorsError }] = await Promise.all([
      sb.from('labs').select('*,sectors(name,slug)').order('name'),
      sb.from('sectors').select('id,name,slug').eq('active', true).eq('reservation_mode', 'internal').order('sort_order').order('name')
    ]);
    if (error || sectorsError) return section.innerHTML = `<div class="card siglab-error">${safe((error || sectorsError).message)}</div>`;
    const sectorOptions = (sectors || []).map(sector => `<option value="${sector.id}">${safe(sector.name)}</option>`).join('');
    section.innerHTML = `
      <div class="siglab-registry-grid">
        <form id="labRegistryForm" class="card siglab-registry-form">
          <span class="eyebrow">NOVO ESPAÇO</span><h2>Cadastrar laboratório</h2>
          <label>Nome<input name="name" maxlength="120" required></label>
          <label>Setor responsável<select name="sector_id" required><option value="">Selecione o setor</option>${sectorOptions}</select></label>
          <div class="field-row"><label>Código<input name="code" maxlength="30"></label><label>Localização<input name="location" maxlength="120"></label></div>
          <label class="siglab-check"><input name="reservation_enabled" type="checkbox"><span>Exibir publicamente para reserva</span></label>
          <button class="primary" type="submit">Salvar laboratório</button>
        </form>
        <section class="card siglab-registry-list"><header><div><span class="eyebrow">ESPAÇOS</span><h2>${labs.length} cadastro(s)</h2></div></header><div>${labs.map(lab => `
          <article><div><strong>${safe(lab.name)}</strong><span>${safe(lab.sectors?.name || 'Setor não definido')} · ${safe(lab.location || 'Local não informado')}</span></div><label class="siglab-inline-check"><input type="checkbox" data-lab-public="${lab.id}" ${lab.reservation_enabled ? 'checked' : ''}><span>Público</span></label><button class="${lab.active === false ? 'secondary' : 'danger-button'}" data-lab-active="${lab.id}" data-next="${lab.active === false}">${lab.active === false ? 'Reativar' : 'Desativar'}</button></article>
        `).join('') || '<p class="empty">Nenhum laboratório cadastrado.</p>'}</div></section>
      </div>`;

    $('#labRegistryForm').onsubmit = async event => {
      event.preventDefault();
      const form = new FormData(event.target);
      const payload = {
        name: form.get('name').trim(), code: form.get('code').trim() || null,
        sector_id: form.get('sector_id'),
        location: form.get('location').trim() || null,
        reservation_enabled: form.has('reservation_enabled'), active: true
      };
      const { error: insertError } = await sb.from('labs').insert(payload);
      if (insertError) return toast(insertError.message);
      toast('Laboratório cadastrado.');
      await renderLabs();
    };
    section.querySelectorAll('[data-lab-public]').forEach(control => control.onchange = async () => {
      const { error: updateError } = await sb.from('labs').update({ reservation_enabled: control.checked }).eq('id', control.dataset.labPublic);
      if (updateError) { control.checked = !control.checked; return toast(updateError.message); }
      toast(control.checked ? 'Espaço publicado para reservas.' : 'Espaço retirado da seleção pública.');
    });
    section.querySelectorAll('[data-lab-active]').forEach(button => button.onclick = async () => {
      const next = button.dataset.next === 'true';
      const { error: updateError } = await sb.from('labs').update({ active: next, reservation_enabled: false }).eq('id', button.dataset.labActive);
      if (updateError) return toast(updateError.message);
      await renderLabs();
    });
  }

  async function renderServers() {
    const section = $('#serversSection');
    section.innerHTML = '<div class="card siglab-loading">Carregando servidores…</div>';
    const { data: servers, error } = await sb.from('servers').select('*').order('full_name');
    if (error) return section.innerHTML = `<div class="card siglab-error">${safe(error.message)}</div>`;
    section.innerHTML = `
      <div class="siglab-registry-grid">
        <form id="serverRegistryForm" class="card siglab-registry-form">
          <span class="eyebrow">NOVO SERVIDOR</span><h2>Cadastrar ou reativar</h2>
          <label>Nome completo<input name="full_name" maxlength="160" required></label>
          <label>SIAPE<input name="siape" inputmode="numeric" maxlength="20" required></label>
          <label>E-mail institucional<input name="email" type="email" maxlength="180" required></label>
          <button class="primary" type="submit">Salvar servidor</button>
        </form>
        <section class="card siglab-registry-list"><header><div><span class="eyebrow">SERVIDORES</span><h2>${servers.length} cadastro(s)</h2></div></header><div>${servers.map(server => `
          <article><div><strong>${safe(server.full_name)}</strong><span>SIAPE ${safe(server.siape)} · ${safe(server.email)}</span></div><button class="${server.active === false ? 'secondary' : 'danger-button'}" data-server-active="${server.id}" data-next="${server.active === false}">${server.active === false ? 'Reativar' : 'Desativar'}</button></article>
        `).join('') || '<p class="empty">Nenhum servidor cadastrado.</p>'}</div></section>
      </div>`;

    $('#serverRegistryForm').onsubmit = async event => {
      event.preventDefault();
      const form = new FormData(event.target);
      const siape = form.get('siape').trim();
      const email = form.get('email').trim().toLowerCase();
      if (!email.endsWith('@ifms.edu.br')) return toast('Use um e-mail institucional @ifms.edu.br.');
      const { data: existing, error: lookupError } = await sb.from('servers').select('id').or(`siape.eq.${siape},email.eq.${email}`).limit(1).maybeSingle();
      if (lookupError) return toast(lookupError.message);
      const payload = { siape, email, full_name: form.get('full_name').trim(), active: true };
      const result = existing
        ? await sb.from('servers').update(payload).eq('id', existing.id)
        : await sb.from('servers').insert(payload);
      if (result.error) return toast(result.error.message);
      toast(existing ? 'Servidor reativado e atualizado.' : 'Servidor cadastrado.');
      await renderServers();
    };
    section.querySelectorAll('[data-server-active]').forEach(button => button.onclick = async () => {
      const { error: updateError } = await sb.from('servers').update({ active: button.dataset.next === 'true' }).eq('id', button.dataset.serverActive);
      if (updateError) return toast(updateError.message);
      await renderServers();
    });
  }

  window.addEventListener('popstate', () => {
    if (location.pathname.includes('/admin')) requestAdmin();
    else if (location.pathname.includes('/reservas')) openReservations();
    else setPublicView('home', false);
  });

  function renderInstitutionalSession() {
    const auth = window.siglabAuth.getState();
    if (!auth.staff && !$('#adminView').hidden) { currentProfile = null; setPublicView('home'); }
    $('#homeGoogleLogin').hidden = Boolean(auth.identity);
    let box = $('#siglabPublicSession');
    if (!box) {
      box = document.createElement('div'); box.id = 'siglabPublicSession'; box.className = 'card siglab-session';
      $('#homeGoogleLogin').after(box);
    }
    box.hidden = !auth.session;
    box.innerHTML = auth.session ? `<strong>${safe(auth.identity?.full_name || 'Conta não habilitada')}</strong><span>${safe(auth.identity?.email || auth.session.user?.email)}</span>${auth.staff?'<button id="openStaffSession" class="secondary" type="button">Área interna</button>':''}<button id="endPublicSession" class="secondary" type="button">Sair</button>` : '';
    $('#openStaffSession')?.addEventListener('click', requestAdmin);
    $('#endPublicSession')?.addEventListener('click', () => window.siglabAuth.signOut());
    $('#homeLoginError').textContent = auth.error || '';
    $('#homeLoginError').hidden = !auth.error;
  }
  window.addEventListener('siglab:auth', renderInstitutionalSession);
  window.siglabAuthReady.then(() => {
  renderInstitutionalSession();
  const params = new URLSearchParams(location.search);
  const route = params.get('route') || location.pathname.slice(siteBase.length).replace(/^\/+|\/+$/g, '');
  const reservationLink = ['confirm_reservation', 'cancel_reservation', 'manage_reservations', 'confirm_cancel_request'].some(key => params.has(key));
  if (route.startsWith('admin')) setTimeout(requestAdmin, 0);
  else if (route === 'reservas' || reservationLink) setTimeout(() => openReservations(params.get('grupo') || 'all'), 0);
  });
})();
