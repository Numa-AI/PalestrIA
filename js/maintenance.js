// Maintenance mode — mostra overlay "sistema non disponibile" se attivato da admin.
// Legge i flag da org_settings (per-tenant): chiavi maintenance.mode / maintenance.message
// / maintenance.admin. Per gli anonimi usa la RPC get_public_org_settings(slug)
// (maintenance.% è in whitelist). Se la query fallisce → fail-open (nessun blocco).
// L'admin bypassa automaticamente (sessionStorage.adminAuth === 'true'), salvo maintenance.admin.

(function () {
    if (typeof supabaseClient === 'undefined') return;

    const isAdminPage = location.pathname.includes('admin.html');
    const isAdmin = () => sessionStorage.getItem('adminAuth') === 'true';

    function _orgSlug() {
        if (typeof window !== 'undefined' && window._orgSlug) return window._orgSlug;
        if (typeof _resolveOrgSlug === 'function') { try { return _resolveOrgSlug(); } catch (_) {} }
        return null;
    }

    // Ritorna { 'maintenance.mode', 'maintenance.message', 'maintenance.admin' } o null.
    async function _fetchFlags() {
        const orgId = (typeof window !== 'undefined') ? window._orgId : null;
        if (orgId) {
            // autenticato: lettura org-scoped diretta (RLS)
            const { data, error } = await supabaseClient
                .from('org_settings')
                .select('key, value')
                .eq('org_id', orgId)
                .in('key', ['maintenance.mode', 'maintenance.message', 'maintenance.admin']);
            if (error || !data) return null;
            return Object.fromEntries(data.map(r => [r.key, r.value]));
        }
        const slug = _orgSlug();
        if (slug) {
            // anonimo: whitelist pubblica
            const { data, error } = await supabaseClient.rpc('get_public_org_settings', { p_org_slug: slug });
            if (error || !data || typeof data !== 'object') return null;
            return data; // { 'maintenance.mode': true, ... }
        }
        return null;
    }

    async function checkMaintenance() {
        try {
            const flags = await _fetchFlags();
            if (!flags) return; // fail-open

            // value è jsonb: true/false nativi (non più stringhe 'true')
            const modeOn = flags['maintenance.mode'] === true || flags['maintenance.mode'] === 'true';
            if (!modeOn) { _removeOverlay(); return; }

            const adminDown = flags['maintenance.admin'] === true || flags['maintenance.admin'] === 'true';

            // Admin bypassa, a meno che maintenance.admin sia attivo
            if (isAdmin() && !adminDown) { _removeOverlay(); return; }
            if (isAdminPage && !adminDown) { _removeOverlay(); return; }

            const raw = flags['maintenance.message'];
            const message = (typeof raw === 'string' && raw.trim())
                ? raw.trim()
                : 'Sistema temporaneamente non disponibile. Riprova più tardi.';

            _showOverlay(message);
        } catch (e) {
            console.warn('[Maintenance] check failed:', e); // fail-open
        }
    }

    function _showOverlay(message) {
        if (document.getElementById('maintenanceOverlay')) return;
        const overlay = document.createElement('div');
        overlay.id = 'maintenanceOverlay';
        overlay.style.cssText = 'position:fixed;inset:0;z-index:99999;background:rgba(0,0,0,0.92);display:flex;flex-direction:column;align-items:center;justify-content:center;padding:2rem;text-align:center;';
        const logo = (typeof OrgSettings !== 'undefined' && OrgSettings.getString('branding.logo_url', '')) || 'images/logo-palestria-light.png';
        overlay.innerHTML = `
            <div style="max-width:420px;">
                <img src="${_escAttr(logo)}" alt="Logo" style="width:80px;height:80px;border-radius:50%;margin-bottom:1.25rem;object-fit:cover;">
                <h2 style="color:#fff;font-size:1.5rem;margin:0 0 1rem;">Sistema in manutenzione</h2>
                <p style="color:#9ca3af;font-size:1rem;line-height:1.6;margin:0;">${_esc(message)}</p>
            </div>`;
        document.body.appendChild(overlay);
    }

    function _removeOverlay() {
        const el = document.getElementById('maintenanceOverlay');
        if (el) el.remove();
    }

    function _esc(s) {
        const d = document.createElement('div');
        d.textContent = s;
        return d.innerHTML;
    }
    function _escAttr(s) { return String(s).replace(/"/g, '&quot;'); }

    // Check iniziale (dopo un breve delay per dare tempo a initAuth di settare adminAuth/_orgId)
    setTimeout(checkMaintenance, 800);

    // Realtime: reagisci ai cambiamenti di org_settings della propria org
    try {
        const orgId = (typeof window !== 'undefined') ? window._orgId : null;
        // Registrato nel registry di silent-refresh: così viene ripulito su unload e
        // soprattutto RIVIVIBILE da _reconnectDeadChannels dopo il wake da idle/sleep
        // (prima restava morto → maintenance non si aggiornava più finché non ricaricavi).
        const _maintRtFactory = function () {
            return supabaseClient.channel('maintenance-rt')
                .on('postgres_changes',
                    orgId
                        ? { event: '*', schema: 'public', table: 'org_settings', filter: `org_id=eq.${orgId}` }
                        : { event: '*', schema: 'public', table: 'org_settings' },
                    () => { setTimeout(checkMaintenance, 300); })
                .subscribe();
        };
        if (typeof window._registerRealtimeChannel === 'function') window._registerRealtimeChannel('maintenance-rt', _maintRtFactory);
        else _maintRtFactory();
    } catch (e) { /* ignore */ }
})();
