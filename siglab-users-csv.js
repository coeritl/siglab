/* CSV de acessos: análise local e gravação pelas mesmas RPCs auditadas do cadastro. */
(() => {
  const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const norm=v=>String(v||'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').trim().toLowerCase();
  function parse(text){
    text=String(text).replace(/^\uFEFF/,'');
    const first=text.split(/\r?\n/)[0]||'',delimiter=first.includes(';')?';':',';
    let rows=[],row=[],cell='',quoted=false,line=1,start=1,closed=false;
    for(let i=0;i<text.length;i++){
      const c=text[i];
      if(quoted){if(c==='"'){if(text[i+1]==='"'){cell+='"';i++}else{quoted=false;closed=true}}else{cell+=c;if(c==='\n')line++}continue}
      if(c==='"'){if(cell||closed)throw new Error(`Aspas inválidas na linha ${line}.`);quoted=true;continue}
      if(closed&&c!==delimiter&&c!=='\n'&&c!=='\r'&&c!==' '&&c!=='\t')throw new Error(`Conteúdo após aspas na linha ${line}.`);
      if(c===delimiter){row.push(cell.trim());cell='';closed=false}
      else if(c==='\n'||c==='\r'){
        if(c==='\r'&&text[i+1]==='\n')i++;
        row.push(cell.trim());if(row.some(Boolean))rows.push({line:start,cells:row});row=[];cell='';closed=false;line++;start=line;
      }else if(!closed)cell+=c;
    }
    if(quoted)throw new Error('Há um campo com aspas não fechadas.');
    row.push(cell.trim());if(row.some(Boolean))rows.push({line:start,cells:row});
    if(rows.length<2)throw new Error('Inclua o cabeçalho e pelo menos um usuário.');
    if(rows.length>501)throw new Error('Importe no máximo 500 usuários por arquivo.');
    const header=rows.shift().cells.map(norm);
    if(new Set(header).size!==header.length)throw new Error('Há colunas duplicadas no cabeçalho.');
    for(const field of ['nome','email','siape','perfil','setores','ativo'])if(!header.includes(field))throw new Error(`Coluna obrigatória ausente: ${field}. Use o modelo.`);
    return rows.map(r=>({line:r.line,fields:Object.fromEntries(header.map((h,i)=>[h,r.cells[i]||''])),columnError:r.cells.length!==header.length}));
  }
  function validate(text,data,selfEmail=''){
    const emails=new Set(),siapes=new Set();
    return parse(text).map(row=>{
      const f=row.fields,email=f.email.trim().toLowerCase(),role=norm(f.perfil),siape=f.siape.trim(),errors=[];
      if(row.columnError)errors.push('Número de colunas diferente do cabeçalho');
      if(f.nome.trim().length<2||f.nome.length>160)errors.push('Nome deve ter de 2 a 160 caracteres');
      if(!/^[^@\s]+@ifms\.edu\.br$/.test(email))errors.push('E-mail deve ser @ifms.edu.br');
      if(emails.has(email))errors.push('E-mail duplicado no arquivo');emails.add(email);
      if(siape&&!/^[0-9]{5,12}$/.test(siape))errors.push('SIAPE deve conter de 5 a 12 dígitos');
      if(role!=='master'&&!siape)errors.push('SIAPE obrigatório para servidor e gestor');
      if(siape&&siapes.has(siape))errors.push('SIAPE duplicado no arquivo');if(siape)siapes.add(siape);
      if(!['master','gestor','servidor'].includes(role))errors.push('Perfil deve ser servidor, gestor ou master');
      const activeValue=norm(f.ativo),active=['sim','true','1','ativo'].includes(activeValue);
      if(!['sim','true','1','ativo','nao','false','0','inativo'].includes(activeValue))errors.push('Ativo deve ser sim ou nao');
      const slugs=f.setores.split('|').map(norm).filter(Boolean),ids=[];
      for(const slug of slugs){const s=data.sectors.find(x=>x.slug===slug&&x.active&&x.reservation_mode==='internal');if(!s)errors.push(`Setor inexistente, externo ou inativo: ${slug}`);else ids.push(s.id)}
      if(role==='gestor'&&!ids.length)errors.push('Gestor precisa de ao menos um setor');
      if(role!=='gestor'&&slugs.length)errors.push('Preencha setores apenas para gestores');
      if(email===String(selfEmail).toLowerCase())errors.push('Altere sua própria conta apenas pelo cadastro manual');
      const existing=data.users.find(u=>u.email===email);
      if(siape&&data.users.some(u=>u.email!==email&&u.siape===siape))errors.push('SIAPE já vinculado a outra conta');
      return {...row,email,existing,errors,args:{p_email:email,p_name:f.nome.trim(),p_siape:siape||null,p_role:role,p_sectors:[...new Set(ids)],p_active:active}};
    });
  }
  function mount(target,data,reload){
    target.insertAdjacentHTML('afterbegin',`<details class="card master-csv"><summary><strong>Importar usuários por CSV</strong><span>Modelo, prévia e validação antes de salvar</span></summary><div class="master-csv-body"><p>Colunas: <code>nome;email;siape;perfil;setores;ativo</code>. Use servidor, gestor ou master. Em setores, informe identificadores separados por <code>|</code>. Preserve zeros iniciais do SIAPE como texto. Máximo: 500 usuários e 1 MB.</p><button class="secondary" id="downloadUsersCsv" type="button">Baixar modelo CSV</button><label>Arquivo CSV UTF-8<input id="usersCsvFile" type="file" accept=".csv,text/csv"></label><label class="siglab-check"><input id="csvUpdateExisting" type="checkbox"><span>Atualizar também as contas existentes (inclusive perfil, setores e situação)</span></label><label class="siglab-check"><input id="csvConfirmSensitive" type="checkbox"><span>Autorizo os perfis master e as desativações indicadas na prévia</span></label><div id="usersCsvPreview" aria-live="polite"></div><p id="usersCsvProgress" role="status"></p><button class="primary" id="importUsersCsv" type="button" disabled>Confirmar importação</button><button class="secondary" id="finishUsersCsv" type="button" hidden>Atualizar lista de usuários</button></div></details>`);
    const $=s=>target.querySelector(s);let rows=[],busy=false,generation=0;
    $('#downloadUsersCsv').onclick=()=>{const url=URL.createObjectURL(new Blob(['\uFEFFnome;email;siape;perfil;setores;ativo\r\n'],{type:'text/csv;charset=utf-8'})),a=document.createElement('a');a.href=url;a.download='modelo-usuarios-siglab.csv';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000)};
    function preview(){
      const chosen=rows.filter(r=>!r.existing||$('#csvUpdateExisting').checked),invalid=rows.filter(r=>r.errors.length),sensitive=chosen.some(r=>r.args.p_role==='master'||!r.args.p_active);
      $('#usersCsvPreview').innerHTML=`<p><strong>${chosen.length} para importar</strong> · ${rows.length-chosen.length} existentes ignorados · ${invalid.length} com erros</p><div class="master-csv-scroll"><table><thead><tr><th>Linha</th><th>Usuário</th><th>Perfil / situação</th><th>Resultado da validação</th></tr></thead><tbody>${rows.map(r=>`<tr><td>${r.line}</td><td>${esc(r.args.p_name)}<small>${esc(r.email)}</small></td><td>${esc(r.args.p_role)} · ${r.args.p_active?'Ativo':'Inativo'}</td><td>${esc(r.errors.join('; ')||(r.existing?($('#csvUpdateExisting').checked?'Atualizar existente':'Ignorar existente'):'Novo cadastro'))}</td></tr>`).join('')}</tbody></table></div>`;
      $('#importUsersCsv').disabled=busy||!chosen.length||invalid.length>0||(sensitive&&!$('#csvConfirmSensitive').checked);
    }
    $('#usersCsvFile').onchange=async()=>{
      const current=++generation;rows=[];$('#importUsersCsv').disabled=true;$('#usersCsvPreview').textContent='';
      const file=$('#usersCsvFile').files[0];if(!file)return;
      try{if(file.size>1048576)throw new Error('Arquivo maior que 1 MB.');const text=await file.text();if(current!==generation)return;rows=validate(text,data,window.siglabAuth.getState().session?.user?.email);preview()}
      catch(e){if(current===generation)$('#usersCsvPreview').textContent=e.message}
    };
    $('#csvUpdateExisting').onchange=preview;$('#csvConfirmSensitive').onchange=preview;
    $('#finishUsersCsv').onclick=reload;
    $('#importUsersCsv').insertAdjacentHTML('afterend','<div id="usersCsvConfirmation" class="linked-notice" hidden><p id="usersCsvConfirmationText"></p><button id="executeUsersCsv" class="primary" type="button">Sim, iniciar importação</button><button id="cancelUsersCsv" class="secondary" type="button">Voltar à prévia</button></div>');
    $('#cancelUsersCsv').onclick=()=>{$('#usersCsvConfirmation').hidden=true;preview()};
    $('#importUsersCsv').onclick=()=>{
      if(busy||$('#importUsersCsv').disabled)return;
      const chosen=rows.filter(r=>!r.existing||$('#csvUpdateExisting').checked);
      $('#usersCsvConfirmationText').textContent=`Importar ${chosen.length} usuário(s)? Contas existentes só serão alteradas se a opção de atualização estiver marcada.`;
      $('#usersCsvConfirmation').hidden=false;
      $('#usersCsvConfirmation').scrollIntoView({behavior:'smooth',block:'nearest'});
    };
    $('#executeUsersCsv').onclick=async()=>{
      if(busy||$('#importUsersCsv').disabled)return;
      const chosen=rows.filter(r=>!r.existing||$('#csvUpdateExisting').checked);
      $('#usersCsvConfirmation').hidden=true;
      busy=true;const controls=[...document.querySelectorAll('#masterSection button,#masterSection input,#masterSection select')];controls.forEach(c=>c.disabled=true);
      let success=0,failures=[];
      try{for(let i=0;i<chosen.length;i++){
        const row=chosen[i];$('#usersCsvProgress').textContent=`Processando ${i+1} de ${chosen.length}…`;
        try{const result=await window.siglabDb.rpc('master_save_access',row.args);if(result.error)throw result.error;success++}
        catch(e){failures.push(`Linha ${row.line}: ${e.message||'Falha de comunicação; confira o cadastro antes de tentar novamente.'}`)}
      }}finally{
        busy=false;$('#usersCsvProgress').textContent=`Concluído: ${success} salvo(s), ${failures.length} falha(s). Os registros salvos foram mantidos; não há rollback do arquivo inteiro.`;
        $('#usersCsvPreview').innerHTML=failures.map(f=>`<p class="error-text">${esc(f)}</p>`).join('');
        $('#finishUsersCsv').hidden=false;$('#finishUsersCsv').disabled=false;
      }
    };
  }
  window.siglabUsersCsv={parse,validate,mount};
})();
