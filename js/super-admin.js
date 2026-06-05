/* ══════════════════════════════════════════════════════════════════════════
   Super-Admin di piattaforma — logica dashboard.
   Tutta l'autorizzazione vera vive lato DB (is_platform_admin + RPC SECURITY
   DEFINER). Qui usiamo solo le RPC: nessuna query cross-tenant lato client.
   ══════════════════════════════════════════════════════════════════════════ */
(function () {
    'use strict';

    let ORGS = [];               // dataset completo (da admin_platform_organizations)
    let sortKey = 'created_at';  // colonna di ordinamento corrente
    let sortDir = -1;            // 1 asc, -1 desc
    let filterText = '';
    let filterStatus = '';
    let filterPlan = '';
    let currentOrg = null;       // studio aperto nel drawer

    // ── Attesa client Supabase pronto ────────────────────────────────────────
    function waitForClient() {
        return new Promise((resolve) => {
            const t0 = Date.now();
            (function tick() {
                if (typeof supabaseClient !== 'undefined' && supabaseClient) return resolve(supabaseClient);
                if (Date.now() - t0 > 8000) return resolve(null);
                setTimeout(tick, 50);
            })();
        });
    }

    // ── Helper di formato ─────────────────────────────────────────────────────
    const euro = (n) => '€' + (Number(n) || 0).toLocaleString('it-IT', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    const intf = (n) => (Number(n) || 0).toLocaleString('it-IT');
    function fmtDate(s) {
        if (!s) return '—';
        const d = new Date(s);
        if (isNaN(d)) return '—';
        return d.toLocaleDateString('it-IT', { day: '2-digit', month: 'short', year: 'numeric' });
    }
    function daysFromNow(s) {
        if (!s) return null;
        const d = new Date(s);
        if (isNaN(d)) return null;
        return Math.ceil((d.getTime() - Date.now()) / 86400000);
    }
    function esc(s) {
        return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => (
            { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
        ));
    }

    function toast(msg, isErr) {
        const el = document.getElementById('saToast');
        el.textContent = msg;
        el.className = 'sa-toast show' + (isErr ? ' err' : '');
        clearTimeout(toast._t);
        toast._t = setTimeout(() => { el.className = 'sa-toast' + (isErr ? ' err' : ''); }, 3200);
    }

    // ── KPI overview ──────────────────────────────────────────────────────────
    function renderKpis(k) {
        const grid = document.getElementById('saKpis');
        const cards = [
            { lbl: '🏋️ Studi totali', val: intf(k.total_orgs), sub: `+${intf(k.new_orgs_30d)} negli ultimi 30gg`, cls: 'accent' },
            { lbl: '✅ Abbonati attivi', val: intf(k.orgs_active), sub: `${intf(k.orgs_trialing)} in trial`, cls: 'good' },
            { lbl: '💶 MRR', val: euro(k.mrr), sub: `ARR ${euro((Number(k.mrr) || 0) * 12)}`, cls: 'accent' },
            { lbl: '⏳ Trial in scadenza', val: intf(k.trials_expiring_7d), sub: 'entro 7 giorni', cls: k.trials_expiring_7d > 0 ? 'warn' : '' },
            { lbl: '⚠️ Da gestire', val: intf((k.orgs_past_due || 0) + (k.orgs_suspended || 0)), sub: `${intf(k.orgs_past_due)} insoluti · ${intf(k.orgs_suspended)} sospesi`, cls: '' },
            { lbl: '👥 Clienti finali', val: intf(k.total_clients), sub: `${intf(k.total_bookings)} prenotazioni totali`, cls: '' },
            { lbl: '🔁 Incassato clienti (30gg)', val: euro(k.gmv_clients_30d), sub: `${euro(k.gmv_clients_total)} totali`, cls: '' },
            { lbl: '🚫 Cancellati', val: intf(k.orgs_cancelled), sub: 'abbonamenti chiusi', cls: '' },
        ];
        grid.innerHTML = cards.map((c) => `
            <div class="sa-kpi ${c.cls}">
                <div class="lbl">${c.lbl}</div>
                <div class="val">${c.val}</div>
                <div class="sub">${esc(c.sub)}</div>
            </div>`).join('');
    }

    // ── Filtri + ordinamento ──────────────────────────────────────────────────
    function applyView() {
        let rows = ORGS.slice();

        if (filterStatus) rows = rows.filter((r) => r.status === filterStatus);
        if (filterPlan)   rows = rows.filter((r) => (r.plan_code || '') === filterPlan);
        if (filterText) {
            const q = filterText.toLowerCase();
            rows = rows.filter((r) =>
                (r.name || '').toLowerCase().includes(q) ||
                (r.slug || '').toLowerCase().includes(q) ||
                (r.owner_email || '').toLowerCase().includes(q));
        }

        rows.sort((a, b) => {
            let va = a[sortKey], vb = b[sortKey];
            if (sortKey === 'created_at' || sortKey === 'trial_end' || sortKey === 'last_activity') {
                va = va ? new Date(va).getTime() : 0;
                vb = vb ? new Date(vb).getTime() : 0;
            } else if (typeof va === 'string' || typeof vb === 'string') {
                va = (va || '').toString().toLowerCase();
                vb = (vb || '').toString().toLowerCase();
            } else { va = Number(va) || 0; vb = Number(vb) || 0; }
            if (va < vb) return -1 * sortDir;
            if (va > vb) return 1 * sortDir;
            return 0;
        });

        renderTable(rows);
        document.getElementById('saCount').textContent =
            `${rows.length} stud${rows.length === 1 ? 'io' : 'i'} su ${ORGS.length}`;
    }

    function statusBadge(s) {
        const lbl = { trialing: 'Trial', active: 'Attivo', past_due: 'Insoluto', suspended: 'Sospeso', cancelled: 'Cancellato' }[s] || s || '—';
        return `<span class="sa-badge ${esc(s)}">${esc(lbl)}</span>`;
    }

    function trialCell(r) {
        if (r.status !== 'trialing' || !r.trial_end) return '—';
        const d = daysFromNow(r.trial_end);
        if (d == null) return fmtDate(r.trial_end);
        if (d < 0)  return `<span class="sa-trial-over">scaduto</span>`;
        if (d <= 7) return `<span class="sa-trial-soon">${d}g rimasti</span>`;
        return `${d}g`;
    }

    function renderTable(rows) {
        const tb = document.getElementById('saTbody');
        if (!rows.length) {
            tb.innerHTML = `<tr><td colspan="9"><div class="sa-empty">Nessuno studio corrisponde ai filtri.</div></td></tr>`;
            return;
        }
        tb.innerHTML = rows.map((r) => `
            <tr data-id="${esc(r.org_id)}">
                <td>
                    <div class="studio">
                        <b>${esc(r.name || '—')}</b>
                        <span>/${esc(r.slug || '')} · ${esc(r.owner_email || 'nessun owner')}</span>
                    </div>
                </td>
                <td>${statusBadge(r.status)}</td>
                <td>${r.plan_code ? `<span class="sa-plan-pill">${esc(r.plan_name || r.plan_code)}</span>` : '—'}</td>
                <td>${trialCell(r)}</td>
                <td class="num">${intf(r.client_count)}</td>
                <td class="num">${intf(r.booking_count)}</td>
                <td class="num">${euro(r.revenue_total)}</td>
                <td>${fmtDate(r.created_at)}</td>
                <td>${fmtDate(r.last_activity)}</td>
            </tr>`).join('');

        tb.querySelectorAll('tr[data-id]').forEach((tr) => {
            tr.addEventListener('click', () => openDrawer(tr.getAttribute('data-id')));
        });
    }

    // ── Drawer dettaglio + azioni ─────────────────────────────────────────────
    function openDrawer(orgId) {
        const r = ORGS.find((o) => o.org_id === orgId);
        if (!r) return;
        currentOrg = r;

        document.getElementById('saDrawerName').textContent = r.name || '—';
        document.getElementById('saDrawerSlug').textContent = '/' + (r.slug || '');

        const trialInfo = (r.status === 'trialing' && r.trial_end)
            ? `${fmtDate(r.trial_end)} (${trialCell(r).replace(/<[^>]+>/g, '')})` : '—';

        document.getElementById('saDrawerBody').innerHTML = `
            <dl class="sa-dl">
                <dt>Stato</dt><dd>${statusBadge(r.status)}</dd>
                <dt>Owner</dt><dd>${esc(r.owner_name || '—')}</dd>
                <dt>Email owner</dt><dd>${esc(r.owner_email || '—')}</dd>
                <dt>Piano SaaS</dt><dd>${esc(r.plan_name || '—')}${r.plan_price != null ? ' · ' + euro(r.plan_price) + '/mese' : ''}</dd>
                <dt>Abbonamento</dt><dd>${esc(r.sub_status || '—')}</dd>
                <dt>Fine trial</dt><dd>${trialInfo}</dd>
                <dt>Rinnovo</dt><dd>${fmtDate(r.current_period_end)}${r.cancel_at_period_end ? ' · disdetto' : ''}</dd>
                <dt>Stripe</dt><dd>${r.stripe_customer_id ? '✓ collegato' : '—'}</dd>
                <dt>Iscritto il</dt><dd>${fmtDate(r.created_at)} · ${esc(r.created_via || '')}</dd>
            </dl>

            <div class="sa-section-title">Numeri</div>
            <dl class="sa-dl">
                <dt>Clienti</dt><dd>${intf(r.client_count)}</dd>
                <dt>Staff</dt><dd>${intf(r.member_count)}</dd>
                <dt>Prenotazioni</dt><dd>${intf(r.booking_count)} (${intf(r.bookings_30d)} ultimi 30gg)</dd>
                <dt>Incassato clienti</dt><dd>${euro(r.revenue_total)} (${euro(r.revenue_30d)} 30gg)</dd>
                <dt>Ultima attività</dt><dd>${fmtDate(r.last_activity)}</dd>
            </dl>

            <div class="sa-section-title">Azioni</div>
            <div class="sa-actions">
                <div class="row">
                    ${r.status === 'suspended'
                        ? `<button class="sa-btn good" data-act="reactivate">▶ Riattiva studio</button>`
                        : `<button class="sa-btn danger" data-act="suspend">⏸ Sospendi studio</button>`}
                    <button class="sa-btn" data-act="extend">⏳ +30gg trial</button>
                </div>
                <div class="row">
                    <select id="saPlanSelect">
                        <option value="">Cambia piano…</option>
                        <option value="starter">Starter — €39,99</option>
                        <option value="pro">Pro — €79,99</option>
                        <option value="business">Business — €149,99</option>
                    </select>
                    <button class="sa-btn" data-act="setplan">Applica</button>
                </div>
            </div>`;

        document.getElementById('saDrawerBody').querySelectorAll('[data-act]').forEach((b) => {
            b.addEventListener('click', () => runAction(b.getAttribute('data-act')));
        });

        document.getElementById('saDrawerBack').classList.add('open');
        document.getElementById('saDrawer').classList.add('open');
    }

    function closeDrawer() {
        document.getElementById('saDrawerBack').classList.remove('open');
        document.getElementById('saDrawer').classList.remove('open');
        currentOrg = null;
    }

    async function runAction(act) {
        if (!currentOrg) return;
        const id = currentOrg.org_id;
        let rpc, params, confirmMsg, okMsg;

        if (act === 'suspend') {
            confirmMsg = `Sospendere "${currentOrg.name}"? Lo studio non potrà più operare finché non lo riattivi.`;
            rpc = 'admin_platform_set_org_status'; params = { p_org_id: id, p_status: 'suspended' };
            okMsg = 'Studio sospeso';
        } else if (act === 'reactivate') {
            rpc = 'admin_platform_set_org_status'; params = { p_org_id: id, p_status: 'active' };
            okMsg = 'Studio riattivato';
        } else if (act === 'extend') {
            rpc = 'admin_platform_extend_trial'; params = { p_org_id: id, p_days: 30 };
            okMsg = 'Trial esteso di 30 giorni';
        } else if (act === 'setplan') {
            const code = document.getElementById('saPlanSelect').value;
            if (!code) { toast('Seleziona un piano', true); return; }
            rpc = 'admin_platform_set_plan'; params = { p_org_id: id, p_plan_code: code };
            okMsg = 'Piano aggiornato';
        } else return;

        if (confirmMsg && !window.confirm(confirmMsg)) return;

        try {
            const { error } = await supabaseClient.rpc(rpc, params);
            if (error) throw error;
            toast(okMsg);
            closeDrawer();
            await loadAll(true);     // ricarica dati aggiornati
        } catch (e) {
            console.error('[super-admin] action error:', e);
            toast('Errore: ' + (e.message || e), true);
        }
    }

    // ── Lock accesso (passa da "aperto a tutti" a una singola email) ──────────
    async function lockAccess() {
        const email = window.prompt(
            'Inserisci l\'email (già registrata) che resterà l\'UNICO super-admin.\n' +
            'Da quel momento la dashboard sarà accessibile solo a quell\'account.');
        if (!email) return;
        try {
            const { error } = await supabaseClient.rpc('admin_platform_lock', { p_email: email.trim() });
            if (error) throw error;
            toast('Accesso chiuso. Solo ' + email.trim() + ' potrà entrare.');
            document.getElementById('saBanner').style.display = 'none';
        } catch (e) {
            toast('Errore: ' + (e.message || e), true);
        }
    }

    // ── Caricamento dati ──────────────────────────────────────────────────────
    async function loadAll(silent) {
        try {
            const [ov, orgs] = await Promise.all([
                supabaseClient.rpc('admin_platform_overview'),
                supabaseClient.rpc('admin_platform_organizations'),
            ]);
            if (ov.error) throw ov.error;
            if (orgs.error) throw orgs.error;
            renderKpis(ov.data || {});
            ORGS = orgs.data || [];
            applyView();
        } catch (e) {
            console.error('[super-admin] load error:', e);
            if (!silent) {
                document.getElementById('saTbody').innerHTML =
                    `<tr><td colspan="9"><div class="sa-empty">Errore nel caricamento: ${esc(e.message || e)}</div></td></tr>`;
            }
            toast('Errore nel caricamento dati', true);
        }
    }

    // ── Gate di accesso ───────────────────────────────────────────────────────
    async function boot() {
        const client = await waitForClient();
        if (!client) { document.body.innerHTML = '<div class="sa-empty">Client Supabase non disponibile.</div>'; return; }

        const { data: { session } } = await client.auth.getSession();
        if (!session) {
            location.href = 'login.html?redirect=super-admin.html';
            return;
        }

        // ── Un SOLO giro di rete ──────────────────────────────────────────────
        // Lanciamo in parallelo: check autorizzazione + i due dataset + il
        // conteggio per il banner. Prima erano 3 await in serie (3 RTT). Le RPC
        // verificano comunque is_platform_admin() lato server, quindi anticipare
        // i dataset non espone nulla a chi non è autorizzato (riceve 'unauthorized').
        // NB: le chiamate supabase-js risolvono con {data,error} e NON rigettano,
        //     perciò Promise.all non va in catch per gli errori RPC.
        const [adminRes, ovRes, orgsRes, padminRes] = await Promise.all([
            client.rpc('is_platform_admin'),
            client.rpc('admin_platform_overview'),
            client.rpc('admin_platform_organizations'),
            client.from('platform_admins').select('user_id', { count: 'exact', head: true }),
        ]);

        // Autorizzazione server-side: mai fidarsi del solo client.
        if (adminRes.error || adminRes.data !== true) {
            if (adminRes.error) console.error('[super-admin] auth check failed:', adminRes.error);
            document.getElementById('saMain').innerHTML =
                `<div class="sa-empty">⛔ Accesso riservato al gestore della piattaforma.<br><br>
                 <a class="sa-link" href="admin.html">← Torna all'amministrazione</a></div>`;
            return;
        }

        // Banner accesso aperto: solo se non c'è ancora nessun super-admin in whitelist.
        if (!padminRes.error && (padminRes.count || 0) === 0) {
            document.getElementById('saBanner').style.display = 'flex';
        }

        wireUi();

        // Render coi dati già pronti: nessun ulteriore round-trip.
        if (ovRes.error || orgsRes.error) {
            const err = ovRes.error || orgsRes.error;
            console.error('[super-admin] load error:', err);
            document.getElementById('saTbody').innerHTML =
                `<tr><td colspan="9"><div class="sa-empty">Errore nel caricamento: ${esc(err.message || err)}</div></td></tr>`;
            toast('Errore nel caricamento dati', true);
            return;
        }
        renderKpis(ovRes.data || {});
        ORGS = orgsRes.data || [];
        applyView();
    }

    function wireUi() {
        document.getElementById('saSearch').addEventListener('input', (e) => { filterText = e.target.value; applyView(); });
        document.getElementById('saStatus').addEventListener('change', (e) => { filterStatus = e.target.value; applyView(); });
        document.getElementById('saPlan').addEventListener('change', (e) => { filterPlan = e.target.value; applyView(); });
        document.getElementById('saRefresh').addEventListener('click', () => loadAll());
        document.getElementById('saLock').addEventListener('click', lockAccess);
        document.getElementById('saDrawerBack').addEventListener('click', closeDrawer);
        document.getElementById('saDrawerClose').addEventListener('click', closeDrawer);
        document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeDrawer(); });

        document.querySelectorAll('th[data-sort]').forEach((th) => {
            th.addEventListener('click', () => {
                const k = th.getAttribute('data-sort');
                if (sortKey === k) sortDir *= -1; else { sortKey = k; sortDir = (k === 'name' || k === 'status') ? 1 : -1; }
                document.querySelectorAll('th[data-sort] .arr').forEach((a) => a.textContent = '');
                const arr = th.querySelector('.arr'); if (arr) arr.textContent = sortDir === 1 ? '▲' : '▼';
                applyView();
            });
        });
    }

    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
    else boot();
})();
