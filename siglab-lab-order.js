// Ordem natural: LAB 2 antes de LAB 10, sem alterar os cadastros ou reservas.
(() => {
  const collator = new Intl.Collator('pt-BR', {numeric:true,sensitivity:'base'});
  window.siglabOrderLabs = rows => [...(rows || [])].sort((a,b) =>
    collator.compare(String(a.name || ''),String(b.name || '')) ||
    String(a.id || '').localeCompare(String(b.id || '')));
})();
