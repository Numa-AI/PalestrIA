// Maintenance mode — mostra overlay "sistema non disponibile" se attivato da admin.
// Legge il flag da app_settings (Supabase). Se la query fallisce → fail-open (nessun blocco).
// L'admin bypassa automaticamente (sessionStorage.adminAuth === 'true'), salvo maintenance_admin.

(function () {
    if (typeof supabaseClient === 'undefined') return;

    const isAdminPage = location.pathname.includes('admin.html');
    const isAdmin = () => sessionStorage.getItem('adminAuth') === 'true';

    async function checkMaintenance() {
        try {
            const { data, error } = await supabaseClient
                .from('app_settings')
                .select('key, value')
                .in('key', ['maintenance_mode', 'maintenance_message', 'maintenance_admin']);
            if (error || !data) return; // fail-open

            const flags = Object.fromEntries(data.map(r => [r.key, r.value]));

            const modeOn = flags.maintenance_mode === true || flags.maintenance_mode === 'true';
            if (!modeOn) { _removeOverlay(); return; }

            const adminDown = flags.maintenance_admin === true || flags.maintenance_admin === 'true';

            // Admin bypassa, a meno che maintenance_admin sia attivo
            if (isAdmin() && !adminDown) { _removeOverlay(); return; }
            // Se siamo su admin.html e maintenance_admin non è attivo, bypassa
            if (isAdminPage && !adminDown) { _removeOverlay(); return; }

            const message = (typeof flags.maintenance_message === 'string' && flags.maintenance_message.trim())
                ? flags.maintenance_message.trim()
                : 'Sistema temporaneamente non disponibile. Riprova più tardi.';

            _showOverlay(message);
        } catch (e) {
            // fail-open: se qualcosa va storto, non bloccare
            console.warn('[Maintenance] check failed:', e);
        }
    }

    function _showOverlay(message) {
        if (document.getElementById('maintenanceOverlay')) return;
        const overlay = document.createElement('div');
        overlay.id = 'maintenanceOverlay';
        overlay.style.cssText = 'position:fixed;inset:0;z-index:99999;background:rgba(0,0,0,0.92);display:flex;flex-direction:column;align-items:center;justify-content:center;padding:2rem;text-align:center;';
        overlay.innerHTML = `
            <div style="max-width:420px;">
                <img src="images/logo-palestria-light.png" alt="PalestrIA" style="width:80px;height:80px;border-radius:50%;margin-bottom:1.25rem;object-fit:cover;">
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

    // Check iniziale (dopo un breve delay per dare tempo a initAuth di settare adminAuth)
    setTimeout(checkMaintenance, 800);

    // Realtime: reagisci ai cambiamenti di app_settings
    try {
        supabaseClient
            .channel('maintenance-rt')
            .on('postgres_changes', { event: '*', schema: 'public', table: 'app_settings' }, () => {
                setTimeout(checkMaintenance, 300);
            })
            .subscribe();
    } catch (e) { /* ignore */ }
})();
