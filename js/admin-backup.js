// Action buttons
// NB: il sistema crediti/debiti/bonus è stato rimosso → le relative chiavi
// localStorage non vengono più incluse nel backup.
const BACKUP_KEYS = [
    'gym_bookings', 'gym_stats', 'gym_users', 'weeklyScheduleTemplate',
    'scheduleOverrides', 'scheduleVersion',
    'gym_cancellation_mode', 'gym_cert_scadenza_editable',
    'gym_cert_block_expired', 'gym_cert_block_not_set',
    'gym_assic_block_expired', 'gym_assic_block_not_set', 'dataClearedByUser',
    'dataLastCleared', 'gym_week_templates', 'gym_active_week_template'
];

// Helper: fetch paginato per superare il limite default PostgREST (~1000 righe).
// Interfaccia identica a supabase query: restituisce { data, error }.
// Usato dal backup per scaricare in modo completo tabelle che possono superare 1000 righe
// (bookings, payments, admin_audit_log, client_notifications, ecc.).
async function _fetchAllPaginated(tableName, selectCols = '*', orderBy = null, timeoutMs = 30000) {
    if (typeof supabaseClient === 'undefined') return { data: null, error: { message: 'no client' } };
    const all = [];
    const BATCH = 1000;
    const MAX_PAGES = 500; // cap di sicurezza: 500k righe per tabella
    for (let page = 0; page < MAX_PAGES; page++) {
        const from = page * BATCH;
        let q = supabaseClient.from(tableName).select(selectCols).range(from, from + BATCH - 1);
        if (orderBy) q = q.order(orderBy.col, { ascending: orderBy.ascending !== false });
        const { data, error } = await _queryWithTimeout(q, timeoutMs);
        if (error) return { data: null, error };
        if (!data || data.length === 0) break;
        all.push(...data);
        if (data.length < BATCH) break;
    }
    return { data: all, error: null };
}

// Converte il formato backup Nextcloud/cron (tabelle Supabase raw) nel formato admin
function _convertCronToAdminFormat(cron) {
    const data = {};
    // Bookings: array Supabase → array locale
    if (Array.isArray(cron.bookings)) {
        data['gym_bookings'] = JSON.stringify(cron.bookings.map(b => ({
            id: b.local_id || b.id,
            userId: b.user_id,
            date: b.date,
            time: b.time,
            slotType: b.slot_type,
            name: b.name,
            email: b.email,
            whatsapp: b.whatsapp,
            notes: b.notes || '',
            status: b.status || 'confirmed',
            paid: b.paid || false,
            paymentMethod: b.payment_method || null,
            paidAt: b.paid_at || null,
            createdAt: b.created_at,
            dateDisplay: b.date_display || '',
            cancellationRequestedAt: b.cancellation_requested_at || null,
            cancelledAt: b.cancelled_at || null,
            cancelledPaymentMethod: b.cancelled_payment_method || null,
            cancelledPaidAt: b.cancelled_paid_at || null,
            cancelledRefundPct: b.cancelled_refund_pct ?? null,
            arrivedAt: b.arrived_at || null,
        })));
    }
    // Schedule overrides: array → oggetto per data
    if (Array.isArray(cron.schedule_overrides)) {
        const overrides = {};
        for (const r of cron.schedule_overrides) {
            if (!overrides[r.date]) overrides[r.date] = [];
            const slot = { time: r.time, type: r.slot_type };
            if (r.slot_type_id) slot.slotTypeId = r.slot_type_id;
            if (r.capacity != null) slot.capacity = r.capacity;   // capienza assoluta (nuovo schema)
            overrides[r.date].push(slot);
        }
        data['scheduleOverrides'] = JSON.stringify(overrides);
    }
    // Settings: array {key, value} → chiavi localStorage
    if (Array.isArray(cron.settings)) {
        const sMap = Object.fromEntries(cron.settings.map(r => [r.key, r.value]));
        const mapping = {
            'cancellation_mode': 'gym_cancellation_mode',
            'cert_scadenza_editable': 'gym_cert_scadenza_editable',
            'cert_block_expired': 'gym_cert_block_expired',
            'cert_block_not_set': 'gym_cert_block_not_set',
            'assic_block_expired': 'gym_assic_block_expired',
            'assic_block_not_set': 'gym_assic_block_not_set',
            'week_templates': 'gym_week_templates',
            'active_week_template': 'gym_active_week_template',
        };
        for (const [dbKey, lsKey] of Object.entries(mapping)) {
            if (sMap[dbKey] != null) data[lsKey] = String(sMap[dbKey]);
        }
    }
    // Profiles → gym_users
    if (Array.isArray(cron.profiles)) {
        data['gym_users'] = JSON.stringify(cron.profiles.map(p => ({
            name: p.name, email: p.email, whatsapp: p.whatsapp || '',
            provider: p.provider || 'email', role: p.role || 'user',
            certificatoMedicoScadenza: p.medical_cert_expiry || null,
            medicalCertHistory: p.medical_cert_history || [],
            assicurazioneScadenza: p.insurance_expiry || null,
            insuranceHistory: p.insurance_history || [],
            codiceFiscale: p.codice_fiscale || null,
            indirizzoVia: p.indirizzo_via || null,
            indirizzoPaese: p.indirizzo_paese || null,
            indirizzoCap: p.indirizzo_cap || null,
            documentoFirmato: p.documento_firmato || false,
        })));
    }
    // Tabelle raw per Supabase restore diretto
    if (Array.isArray(cron.push_subscriptions)) data['_push_subscriptions'] = JSON.stringify(cron.push_subscriptions);
    if (Array.isArray(cron.admin_audit_log))    data['_admin_audit_log']    = JSON.stringify(cron.admin_audit_log);
    if (Array.isArray(cron.profiles))           data['_profiles']           = JSON.stringify(cron.profiles);
    // settings rinominata in org_settings: accetta entrambe le chiavi dai backup legacy
    if (Array.isArray(cron.org_settings))       data['_org_settings']       = JSON.stringify(cron.org_settings);
    else if (Array.isArray(cron.settings))      data['_org_settings']       = JSON.stringify(cron.settings);
    if (Array.isArray(cron.admin_messages))        data['_admin_messages']        = JSON.stringify(cron.admin_messages);
    if (Array.isArray(cron.client_notifications)) data['_client_notifications'] = JSON.stringify(cron.client_notifications);
    // Nuove tabelle billing/scheduling multi-tenant
    if (Array.isArray(cron.payments))                    data['_payments']                    = JSON.stringify(cron.payments);
    if (Array.isArray(cron.client_packages))             data['_client_packages']             = JSON.stringify(cron.client_packages);
    if (Array.isArray(cron.client_memberships))          data['_client_memberships']          = JSON.stringify(cron.client_memberships);
    if (Array.isArray(cron.slot_types))                  data['_slot_types']                  = JSON.stringify(cron.slot_types);
    if (Array.isArray(cron.time_slots_config))           data['_time_slots_config']           = JSON.stringify(cron.time_slots_config);
    if (Array.isArray(cron.weekly_schedule_templates))   data['_weekly_schedule_templates']   = JSON.stringify(cron.weekly_schedule_templates);

    return {
        version: 2,
        exportedAt: cron.generated_at || new Date().toISOString(),
        data
    };
}

async function exportBackup(format = 'json') {
    const s = document.getElementById('backupStatus');
    if (s) s.textContent = '⏳ Esportazione in corso...';

    // ── Raccogli dati grezzi da Supabase ─────────────────────────────────────
    const tables = {};
    let _skippedTables = [];
    if (typeof supabaseClient !== 'undefined') {
        try {
            // Tutte le query di backup usano _fetchAllPaginated per scaricare in modo
            // completo: altrimenti con tabelle >1000 righe il backup sarebbe silenziosamente
            // troncato. profiles resta via RPC (è già gestita server-side).
            // NB: tabelle crediti/debiti/bonus rimosse dal sistema → non più nel backup.
            // Aggiunte le nuove tabelle billing/scheduling multi-tenant.
            const _exportQueries = [
                { key: 'bookings',                  q: _fetchAllPaginated('bookings',                  '*', { col: 'created_at', ascending: true }, 30000) },
                { key: 'payments',                  q: _fetchAllPaginated('payments',                  '*', { col: 'created_at', ascending: true }, 30000) },
                { key: 'client_packages',           q: _fetchAllPaginated('client_packages',           '*', { col: 'created_at', ascending: true }, 20000) },
                { key: 'client_memberships',        q: _fetchAllPaginated('client_memberships',        '*', { col: 'created_at', ascending: true }, 20000) },
                { key: 'slot_types',                q: _fetchAllPaginated('slot_types',                '*', { col: 'sort_order', ascending: true }, 20000) },
                { key: 'time_slots_config',         q: _fetchAllPaginated('time_slots_config',         '*', { col: 'sort_order', ascending: true }, 20000) },
                { key: 'weekly_schedule_templates', q: _fetchAllPaginated('weekly_schedule_templates', '*', { col: 'created_at', ascending: true }, 20000) },
                { key: 'schedule_overrides',        q: _fetchAllPaginated('schedule_overrides',        '*', { col: 'date', ascending: true }, 20000) },
                { key: 'profiles',                  q: _rpcWithTimeout(supabaseClient.rpc('get_all_profiles'), 20000) },
                { key: 'org_settings',              q: _fetchAllPaginated('org_settings',              '*', null, 20000) },
                { key: 'push_subscriptions',        q: _fetchAllPaginated('push_subscriptions',        '*', null, 20000) },
                { key: 'admin_audit_log',           q: _fetchAllPaginated('admin_audit_log',           '*', { col: 'created_at', ascending: true }, 30000) },
                { key: 'admin_messages',            q: _fetchAllPaginated('admin_messages',            '*', { col: 'created_at', ascending: true }, 20000) },
                { key: 'client_notifications',      q: _fetchAllPaginated('client_notifications',      '*', { col: 'created_at', ascending: true }, 30000) },
            ];
            const _exportResults = await Promise.allSettled(_exportQueries.map(e => e.q));
            _exportQueries.forEach((e, i) => {
                if (_exportResults[i].status === 'fulfilled' && _exportResults[i].value?.data) {
                    tables[e.key] = _exportResults[i].value.data;
                } else {
                    _skippedTables.push(e.key);
                }
            });
            if (_skippedTables.length > 0) console.warn('[Backup] Tabelle saltate (timeout/errore):', _skippedTables.join(', '));
        } catch (e) {
            console.warn('[Backup] Errore fetch Supabase:', e.message);
        }
    }

    if (format === 'csv') {
        // ── Export CSV (uno ZIP con un CSV per tabella) ───────────────────────
        _exportBackupCSV(tables, s);
        return;
    }

    // ── Export JSON — stesso formato del backup auto-cron di Nextcloud ───────
    const backup = {
        generated_at: new Date().toISOString(),
        source: 'admin-export',
        ...tables
    };

    const blob = new Blob([JSON.stringify(backup, null, 2)], { type: 'application/json' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = `gym-backup-${_localDateStr()}.json`;
    a.click();
    URL.revokeObjectURL(a.href);
    if (s) s.textContent = _skippedTables && _skippedTables.length > 0
        ? `⚠️ Backup esportato (tabelle mancanti: ${_skippedTables.join(', ')}) — ${new Date().toLocaleString('it-IT')}`
        : `✅ Backup JSON esportato il ${new Date().toLocaleString('it-IT')}`;
}

function _exportBackupCSV(tables, statusEl) {
    const dateStr = _localDateStr();

    // Converte un array di oggetti in stringa CSV
    function toCsv(rows) {
        if (!rows || rows.length === 0) return '';
        const headers = Object.keys(rows[0]);
        const escape = v => {
            if (v == null) return '';
            const s = typeof v === 'object' ? JSON.stringify(v) : String(v);
            return s.includes(',') || s.includes('"') || s.includes('\n')
                ? '"' + s.replace(/"/g, '""') + '"' : s;
        };
        return [headers.join(','), ...rows.map(r => headers.map(h => escape(r[h])).join(','))].join('\n');
    }

    // Genera un CSV per ogni tabella e scarica come file singoli in uno ZIP
    // Senza librerie ZIP, scarichiamo un singolo CSV multi-foglio separato da intestazioni
    const sections = [];
    for (const [name, rows] of Object.entries(tables)) {
        if (!Array.isArray(rows) || rows.length === 0) continue;
        sections.push(`\n### TABELLA: ${name.toUpperCase()} (${rows.length} righe) ###\n` + toCsv(rows));
    }

    if (sections.length === 0) {
        if (statusEl) statusEl.textContent = '❌ Nessun dato da esportare';
        return;
    }

    const content = `# Backup PalestrIA — ${dateStr}\n# Generato il ${new Date().toLocaleString('it-IT')}\n` + sections.join('\n\n');
    const blob = new Blob(['\uFEFF' + content], { type: 'text/csv;charset=utf-8' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = `gym-backup-${dateStr}.csv`;
    a.click();
    URL.revokeObjectURL(a.href);
    if (statusEl) statusEl.textContent = `✅ Backup CSV esportato il ${new Date().toLocaleString('it-IT')}`;
}

function importBackup(input) {
    const file = input.files[0];
    if (!file) return;
    const pw = prompt('Inserisci la password per importare il backup:');
    if (pw !== 'Palestra123') {
        alert('Password errata');
        input.value = '';
        return;
    }
    const reader = new FileReader();
    reader.onload = async e => {
        try {
            let backup = JSON.parse(e.target.result);
            console.log('[Backup] Chiavi trovate nel file:', Object.keys(backup));

            // ── Rileva e normalizza formato Nextcloud/cron ──────────────
            // Formato A: { generated_at, bookings: [...], payments: [...], ... }
            // Formato B: { exportedAt, source, tables: { bookings: [...], ... } }
            // Formato admin: { version, exportedAt, data: { gym_bookings: "...", ... } }

            // Formato B (tables wrapper): appiattisci in formato A
            if (!backup.data && backup.tables && typeof backup.tables === 'object') {
                const flat = { generated_at: backup.exportedAt || backup.generated_at, ...backup.tables };
                console.log('[Backup] Rilevato formato Nextcloud con tables wrapper, appiattisco...');
                backup = flat;
            }

            if (!backup.data && (backup.bookings || backup.payments || backup.generated_at)) {
                console.log('[Backup] Rilevato formato Nextcloud/cron, converto...');
                backup = _convertCronToAdminFormat(backup);
                console.log('[Backup] Conversione completata, chiavi data:', Object.keys(backup.data || {}));
            }

            if (!backup?.data || typeof backup.data !== 'object') {
                console.error('[Backup] Formato non riconosciuto. Struttura:', JSON.stringify(backup).substring(0, 500));
                throw new Error('Formato non valido');
            }
            const keyCount = Object.keys(backup.data).length;
            const exportDate = (backup.exportedAt || backup.generated_at)
                ? new Date(backup.exportedAt || backup.generated_at).toLocaleString('it-IT')
                : 'data sconosciuta';
            if (!confirm(`Ripristinare il backup del ${exportDate}?\n\nConterrà ${keyCount} sezioni di dati.\n\n⚠️ ATTENZIONE: tutti i dati attuali verranno sovrascritti.`)) {
                input.value = '';
                return;
            }
            BACKUP_KEYS.forEach(key => {
                if (backup.data[key] !== undefined) {
                    localStorage.setItem(key, backup.data[key]);
                }
            });
            const s = document.getElementById('backupStatus');
            const _restoreStep = (label) => { if (s) s.textContent = `⏳ Ripristino: ${label}...`; };
            _restoreStep('avvio');

            // ── Push dati ripristinati su Supabase ──────────────
            if (typeof supabaseClient !== 'undefined') {
                try {
                    const promises = [];
                    const _restoreErrors = [];
                    const _T = 20000; // timeout per step

                    // 1. Bookings — upsert completo
                    _restoreStep('bookings');
                    const bookings = JSON.parse(backup.data.gym_bookings || '[]');
                    if (Array.isArray(bookings) && bookings.length > 0) {
                        const bRows = bookings
                            .filter(b => b.id && !b.id.startsWith('demo-') && !b.id.startsWith('_avail_'))
                            .map(b => ({
                                local_id:                  b.id,
                                user_id:                   b.userId || null,
                                date:                      b.date,
                                time:                      b.time,
                                slot_type:                 b.slotType,
                                name:                      b.name,
                                email:                     b.email,
                                whatsapp:                  b.whatsapp,
                                notes:                     b.notes || '',
                                status:                    b.status || 'confirmed',
                                paid:                      b.paid || false,
                                payment_method:            b.paymentMethod || null,
                                paid_at:                   b.paidAt || null,
                                created_at:                b.createdAt,
                                date_display:              b.dateDisplay || '',
                                cancellation_requested_at: b.cancellationRequestedAt || null,
                                cancelled_at:              b.cancelledAt || null,
                                cancelled_payment_method:  b.cancelledPaymentMethod || null,
                                cancelled_paid_at:         b.cancelledPaidAt || null,
                                cancelled_refund_pct:      b.cancelledRefundPct ?? null,
                            }));
                        if (bRows.length > 0) {
                            promises.push(_queryWithTimeout(supabaseClient.from('bookings').upsert(bRows, { onConflict: 'local_id' }), _T).catch(e => { _restoreErrors.push('bookings'); }));
                        }
                    }

                    // 2. Payments (ledger unificato) — sostituisce crediti/debiti/bonus
                    _restoreStep('payments');
                    if (backup.data._payments) {
                        const payRows = JSON.parse(backup.data._payments || '[]');
                        if (payRows.length > 0) {
                            promises.push(_queryWithTimeout(supabaseClient.from('payments').upsert(payRows, { onConflict: 'id' }), _T).catch(e => { _restoreErrors.push('payments'); }));
                        }
                    }

                    // 3. Client packages
                    _restoreStep('client_packages');
                    if (backup.data._client_packages) {
                        const cpRows = JSON.parse(backup.data._client_packages || '[]');
                        if (cpRows.length > 0) {
                            promises.push(_queryWithTimeout(supabaseClient.from('client_packages').upsert(cpRows, { onConflict: 'id' }), _T).catch(e => { _restoreErrors.push('client_packages'); }));
                        }
                    }

                    // 4. Client memberships
                    _restoreStep('client_memberships');
                    if (backup.data._client_memberships) {
                        const cmRows = JSON.parse(backup.data._client_memberships || '[]');
                        if (cmRows.length > 0) {
                            promises.push(_queryWithTimeout(supabaseClient.from('client_memberships').upsert(cmRows, { onConflict: 'id' }), _T).catch(e => { _restoreErrors.push('client_memberships'); }));
                        }
                    }

                    // 5. Schedule overrides
                    _restoreStep('schedule_overrides');
                    const overrides = JSON.parse(backup.data.scheduleOverrides || '{}');
                    const oRows = [];
                    for (const [dateStr, slots] of Object.entries(overrides)) {
                        for (const slot of (Array.isArray(slots) ? slots : [])) {
                            const row = { org_id: window._orgId, date: dateStr, time: slot.time, slot_type: slot.type };
                            if (slot.slotTypeId) row.slot_type_id = slot.slotTypeId;
                            if (slot.capacity != null) row.capacity = slot.capacity;   // capienza assoluta
                            oRows.push(row);
                        }
                    }
                    if (oRows.length > 0) {
                        promises.push(_queryWithTimeout(supabaseClient.from('schedule_overrides').upsert(oRows, { onConflict: 'org_id,date,time' }), _T).catch(e => { _restoreErrors.push('schedule_overrides'); }));
                    }

                    // 6. Scheduling config (slot_types, time_slots_config, weekly templates)
                    _restoreStep('slot_types');
                    if (backup.data._slot_types) {
                        const stRows = JSON.parse(backup.data._slot_types || '[]');
                        if (stRows.length > 0) {
                            promises.push(_queryWithTimeout(supabaseClient.from('slot_types').upsert(stRows, { onConflict: 'id' }), _T).catch(e => { _restoreErrors.push('slot_types'); }));
                        }
                    }
                    if (backup.data._time_slots_config) {
                        const tscRows = JSON.parse(backup.data._time_slots_config || '[]');
                        if (tscRows.length > 0) {
                            promises.push(_queryWithTimeout(supabaseClient.from('time_slots_config').upsert(tscRows, { onConflict: 'id' }), _T).catch(e => { _restoreErrors.push('time_slots_config'); }));
                        }
                    }
                    if (backup.data._weekly_schedule_templates) {
                        const wstRows = JSON.parse(backup.data._weekly_schedule_templates || '[]');
                        if (wstRows.length > 0) {
                            promises.push(_queryWithTimeout(supabaseClient.from('weekly_schedule_templates').upsert(wstRows, { onConflict: 'id' }), _T).catch(e => { _restoreErrors.push('weekly_schedule_templates'); }));
                        }
                    }

                    // 7. Org settings (tabella Supabase, ex 'settings')
                    _restoreStep('org_settings');
                    if (backup.data._org_settings) {
                        const sRows = JSON.parse(backup.data._org_settings || '[]');
                        if (sRows.length > 0) {
                            promises.push(_queryWithTimeout(supabaseClient.from('org_settings').upsert(sRows, { onConflict: 'org_id,key' }), _T).catch(e => { _restoreErrors.push('org_settings'); }));
                        }
                    }

                    // 8. Profiles — ripristino su Supabase
                    _restoreStep('profiles');
                    if (backup.data._profiles) {
                        const pRows = JSON.parse(backup.data._profiles || '[]');
                        if (pRows.length > 0) {
                            for (const p of pRows) {
                                promises.push(_queryWithTimeout(supabaseClient.from('profiles').update({
                                    name: p.name,
                                    whatsapp: p.whatsapp || null,
                                    medical_cert_expiry: p.medical_cert_expiry || null,
                                    medical_cert_history: p.medical_cert_history || [],
                                    insurance_expiry: p.insurance_expiry || null,
                                    insurance_history: p.insurance_history || [],
                                    codice_fiscale: p.codice_fiscale || null,
                                    indirizzo_via: p.indirizzo_via || null,
                                    indirizzo_paese: p.indirizzo_paese || null,
                                    indirizzo_cap: p.indirizzo_cap || null,
                                    documento_firmato: p.documento_firmato || false,
                                    geo_enabled: p.geo_enabled || false,
                                    push_enabled: p.push_enabled || false,
                                }).eq('email', (p.email || '').toLowerCase()), _T).catch(() => { _restoreErrors.push('profiles'); }));
                            }
                        }
                    }

                    // 9. Push subscriptions
                    _restoreStep('push_subscriptions');
                    if (backup.data._push_subscriptions) {
                        const psRows = JSON.parse(backup.data._push_subscriptions || '[]');
                        if (psRows.length > 0) {
                            for (const ps of psRows) {
                                promises.push(_queryWithTimeout(supabaseClient.from('push_subscriptions').upsert({
                                    user_id: ps.user_id,
                                    endpoint: ps.endpoint,
                                    p256dh: ps.p256dh,
                                    auth: ps.auth,
                                }, { onConflict: 'endpoint' }), _T).catch(() => { _restoreErrors.push('push_subscriptions'); }));
                            }
                        }
                    }

                    // 10. Admin audit log
                    _restoreStep('admin_audit_log');
                    if (backup.data._admin_audit_log) {
                        const alRows = JSON.parse(backup.data._admin_audit_log || '[]');
                        if (alRows.length > 0) {
                            await _queryWithTimeout(supabaseClient.from('admin_audit_log').delete().neq('id', '00000000-0000-0000-0000-000000000000'), _T).catch(() => {});
                            promises.push(_queryWithTimeout(supabaseClient.from('admin_audit_log').insert(alRows), _T).catch(() => { _restoreErrors.push('admin_audit_log'); }));
                        }
                    }

                    // 11. Admin messages
                    _restoreStep('admin_messages');
                    if (backup.data._admin_messages) {
                        const amRows = JSON.parse(backup.data._admin_messages || '[]');
                        if (amRows.length > 0) {
                            await _queryWithTimeout(supabaseClient.from('admin_messages').delete().neq('id', '00000000-0000-0000-0000-000000000000'), _T).catch(() => {});
                            promises.push(_queryWithTimeout(supabaseClient.from('admin_messages').insert(amRows), _T).catch(() => { _restoreErrors.push('admin_messages'); }));
                        }
                    }

                    // 12. Client notifications
                    _restoreStep('client_notifications');
                    if (backup.data._client_notifications) {
                        const cnRows = JSON.parse(backup.data._client_notifications || '[]');
                        if (cnRows.length > 0) {
                            await _queryWithTimeout(supabaseClient.from('client_notifications').delete().neq('id', '00000000-0000-0000-0000-000000000000'), _T).catch(() => {});
                            promises.push(_queryWithTimeout(supabaseClient.from('client_notifications').insert(cnRows), _T).catch(() => { _restoreErrors.push('client_notifications'); }));
                        }
                    }

                    _restoreStep('finalizzazione');
                    const results = await Promise.allSettled(promises);
                    const errors = results.filter(r => r.status === 'fulfilled' && r.value?.error);
                    if (errors.length > 0) {
                        console.warn('[Backup] Alcuni upsert con errore:', errors.map(r => r.value.error.message));
                    }
                    if (_restoreErrors.length > 0) {
                        console.warn('[Backup] Step con timeout/errore:', _restoreErrors.join(', '));
                    }
                    console.log('[Backup] Ripristino Supabase completato:', results.length, 'operazioni');
                } catch (e) {
                    console.error('[Backup] Errore ripristino Supabase:', e);
                }
            }

            if (s) s.textContent = typeof _restoreErrors !== 'undefined' && _restoreErrors && _restoreErrors.length > 0
                ? `⚠️ Ripristinato con errori (${_restoreErrors.join(', ')}). Ricarico...`
                : '✅ Backup ripristinato. Ricarico...';
            setTimeout(() => location.reload(), 1200);
        } catch (err) {
            alert('Errore durante l\'importazione: ' + err.message);
            const s = document.getElementById('backupStatus');
            if (s) s.textContent = '❌ Importazione fallita: ' + err.message;
        } finally {
            input.value = '';
        }
    };
    reader.readAsText(file);
}

async function exportData() {
    const date = _localDateStr();

    // Mostra loading sul bottone durante il fetch
    const btn = document.querySelector('[onclick="exportData()"]');
    const origLabel = btn?.innerHTML;
    if (btn) { btn.innerHTML = '⏳ Caricamento...'; btn.disabled = true; }

    // ── Helpers ───────────────────────────────────────────────────
    function fmtDate(iso) {
        if (!iso) return '';
        const d = new Date(iso);
        return isNaN(d) ? iso : d.toLocaleDateString('it-IT');
    }
    function fmtDateTime(iso) {
        if (!iso) return '';
        const d = new Date(iso);
        return isNaN(d) ? iso : d.toLocaleString('it-IT');
    }

    const SLOT_LABEL = {
        'personal-training': 'Personal Training',
        'small-group':       'Small Group',
        'group-class':       'Lezione di Gruppo',
        'cleaning':          'Pulizie'
    };
    const STATUS_LABEL = {
        'confirmed':              'Confermata',
        'cancelled':              'Annullata',
        'cancellation_requested': 'Annullamento richiesto'
    };
    // Metodi pagamento allineati al constraint payments.method del baseline
    const METHOD_LABEL = {
        contanti: 'Contanti', 'contanti-report': 'Contanti con Report', carta: 'Carta', iban: 'Bonifico', stripe: 'Stripe', gratuito: 'Gratuita'
    };
    const DAYS = ['Domenica','Lunedì','Martedì','Mercoledì','Giovedì','Venerdì','Sabato'];

    // ── Fonti dati ─────────────────────────────────────────────────
    // Fetch tutti i booking direttamente da Supabase (bypass localStorage size limit)
    const allBookings  = (await BookingStorage.fetchForAdmin(null, null))
                            .sort((a, b) => b.date.localeCompare(a.date));
    const allUsers     = UserStorage.getAll();
    const allOverrides = BookingStorage.getScheduleOverrides() || {};
    // Pagamenti dal ledger unificato 'payments' (sostituisce crediti/debiti/bonus)
    let allPayments = [];
    if (typeof supabaseClient !== 'undefined') {
        const { data: payData } = await _fetchAllPaginated('payments', '*', { col: 'created_at', ascending: false }, 30000);
        if (Array.isArray(payData)) allPayments = payData;
    }

    // ── 1. CLIENTI ─────────────────────────────────────────────────
    const clientMap = {};
    allUsers.forEach(u => {
        const key = (u.email || u.whatsapp || '').toLowerCase();
        clientMap[key] = {
            nome:      u.name,
            email:     u.email || '',
            whatsapp:  u.whatsapp || '',
            cert_scad: u.certificatoMedicoScadenza || '',
            tipo:      u.provider === 'google' ? 'Google OAuth'
                     : u.passwordHash          ? 'Email/Password'
                                               : 'Profilo admin',
            creato_il: fmtDate(u.createdAt)
        };
    });
    allBookings.forEach(b => {
        const key = (b.email || normalizePhone(b.whatsapp) || '').toLowerCase();
        if (!clientMap[key]) {
            clientMap[key] = {
                nome: b.name, email: b.email || '', whatsapp: b.whatsapp || '',
                cert_scad: '', tipo: 'Solo prenotazioni', creato_il: fmtDate(b.createdAt)
            };
        }
    });
    const sheetClienti = [
        ['Nome','Email','WhatsApp','Scadenza Cert. Medico','Tipo Account','Creato Il'],
        ...Object.values(clientMap)
            .sort((a, b) => a.nome.localeCompare(b.nome))
            .map(c => [c.nome, c.email, c.whatsapp, c.cert_scad, c.tipo, c.creato_il])
    ];

    // ── 2. PRENOTAZIONI ────────────────────────────────────────────
    const sheetPrenotazioni = [
        ['ID','Data','Orario','Tipo Lezione','Nome','Email','WhatsApp','Note',
         'Stato','Pagato','Metodo Pagamento','Data Pagamento','Creato Il'],
        ...allBookings.map(b => [
            b.id,
            fmtDate(b.date + 'T12:00:00'),
            b.time,
            SLOT_LABEL[b.slotType] || b.slotType,
            b.name, b.email, b.whatsapp,
            b.notes || '',
            STATUS_LABEL[b.status] || 'Confermata',
            b.paid ? 'Sì' : 'No',
            METHOD_LABEL[b.paymentMethod] || '',
            fmtDateTime(b.paidAt),
            fmtDateTime(b.createdAt)
        ])
    ];

    // ── 3. PAGAMENTI (ledger unificato 'payments') ─────────────────
    const KIND_LABEL = {
        session:          'Sessione',
        membership:       'Abbonamento',
        package_purchase: 'Pacchetto',
        penalty_mora:     'Mora/Penale',
        adjustment:       'Rettifica',
    };
    const sheetPagamenti = [
        ['Data','Email Cliente','Tipo','Importo (€)','Metodo','Periodo Da','Periodo A','Nota'],
        ...allPayments.map(p => [
            fmtDateTime(p.created_at),
            p.client_email || '',
            KIND_LABEL[p.kind] || p.kind || '',
            p.amount ?? 0,
            METHOD_LABEL[p.method] || p.method || '',
            fmtDate(p.period_start ? p.period_start + 'T12:00:00' : ''),
            fmtDate(p.period_end ? p.period_end + 'T12:00:00' : ''),
            p.note || ''
        ])
    ];

    // ── 4. GESTIONE ORARI ──────────────────────────────────────────
    const sheetOrari = [
        ['Data','Giorno','Orario','Tipo Lezione','Cliente Assegnato','Booking ID'],
        ...Object.entries(allOverrides)
            .sort(([a], [b]) => a.localeCompare(b))
            .flatMap(([dateStr, slots]) => {
                const d = new Date(dateStr + 'T12:00:00');
                return (slots || []).map(s => [
                    fmtDate(dateStr + 'T12:00:00'),
                    DAYS[d.getDay()],
                    s.time,
                    SLOT_LABEL[s.type] || s.type,
                    s.client || '',
                    s.bookingId || ''
                ]);
            })
    ];

    // ── Crea workbook Excel con SheetJS ───────────────────────────
    const wb = XLSX.utils.book_new();
    const sheets = [
        ['Clienti',        sheetClienti],
        ['Prenotazioni',   sheetPrenotazioni],
        ['Pagamenti',      sheetPagamenti],
        ['Gestione Orari', sheetOrari],
    ];

    sheets.forEach(([name, data]) => {
        const ws = XLSX.utils.aoa_to_sheet(data);
        // Larghezza colonne automatica (stima dal contenuto)
        const colWidths = data[0].map((_, ci) =>
            Math.min(50, Math.max(10, ...data.map(r => String(r[ci] ?? '').length)))
        );
        ws['!cols'] = colWidths.map(w => ({ wch: w }));
        XLSX.utils.book_append_sheet(wb, ws, name);
    });

    const filename = `TB_Training_export_${date}.xlsx`;
    XLSX.writeFile(wb, filename);

    if (btn) {
        btn.disabled = false;
        btn.innerHTML = '✅ Scaricato!';
        setTimeout(() => { btn.innerHTML = origLabel; }, 2500);
    }
}

function resetDemoData() {
    if (confirm('⚠️ ATTENZIONE: Questo cancellerà tutti i dati esistenti e genererà nuovi dati demo da Gennaio al 15 Marzo. Continuare?')) {
        BookingStorage._cache = [];
        localStorage.removeItem(BookingStorage.STATS_KEY);
        localStorage.removeItem('scheduleOverrides');
        localStorage.removeItem('dataClearedByUser');
        BookingStorage.initializeDemoData();
        alert('✅ Dati demo rigenerati con successo!');
        location.reload();
    }
}

async function clearAllData() {
    if (!confirm('⚠️ ATTENZIONE: Questo eliminerà definitivamente tutte le prenotazioni e i dati sia localmente che su Supabase. NON verranno generati nuovi dati demo. Continuare?')) return;

    // 1. Cancella Supabase PRIMA del localStorage — così il sync post-reload
    //    non riscarica dati che stiamo per eliminare.
    if (typeof supabaseClient !== 'undefined') {
        // Disiscriviti dai canali Realtime per evitare che un evento
        // postgres_changes faccia syncFromSupabase() prima che il clear sia completo
        try { supabaseClient.removeAllChannels(); } catch (_) {}

        const { error: rpcErr } = await supabaseClient.rpc('admin_clear_all_data');
        if (rpcErr) {
            console.error('[Supabase] admin_clear_all_data RPC error:', rpcErr.message, rpcErr.code);
            alert('⚠️ Errore durante la cancellazione su Supabase: ' + rpcErr.message);
            return;
        }
        const now = new Date().toISOString();
        // Marker org-scoped su org_settings via RPC canonica (ex app_settings)
        const { error: settingsErr } = await supabaseClient.rpc('upsert_org_setting', {
            p_key: 'data_cleared_at', p_value: { ts: now },
        });
        if (settingsErr) console.error('[Supabase] clearAllData - upsert_org_setting error:', settingsErr.message);
        localStorage.setItem('dataLastCleared', now);
    }

    // 2. Svuota cache in memoria + localStorage settings
    BookingStorage._cache = [];
    UserStorage._cache = [];
    localStorage.removeItem(BookingStorage.STATS_KEY);
    localStorage.removeItem('scheduleOverrides');
    localStorage.setItem('dataClearedByUser', 'true');

    // 3. Svuota cache PWA — previene dati fantasma dal service worker
    if ('caches' in window) {
        try {
            const keys = await caches.keys();
            await Promise.all(keys.map(k => caches.delete(k)));
        } catch (_) {}
    }

    alert('✅ Tutti i dati sono stati eliminati (localStorage + Supabase).');
    location.reload();
}

function pruneOldData() {
    const months = parseInt(prompt(
        'Eliminare dati demo e prenotazioni più vecchie di quanti mesi?\n(es. 6 = tutto ciò che precede 6 mesi fa)',
        '12'
    ));
    if (!months || isNaN(months) || months <= 0) return;

    const cutoff = new Date();
    cutoff.setMonth(cutoff.getMonth() - months);
    const cutoffStr = _localDateStr(cutoff);

    if (!confirm(`⚠️ Verranno eliminati definitivamente:\n• Tutte le prenotazioni DEMO\n• Prenotazioni reali con data precedente al ${cutoff.toLocaleDateString('it-IT')}\n\nContinuare?`)) return;

    // 1. Rimuovi prenotazioni demo (sempre) + prenotazioni reali più vecchie del cutoff
    const bookings = BookingStorage.getAllBookings();
    BookingStorage.replaceAllBookings(
        bookings.filter(b => !b.id?.startsWith('demo-') && b.date >= cutoffStr)
    );
    // Impedisci che initializeDemoData rigeneri i dati al prossimo reload
    localStorage.setItem('dataClearedByUser', 'true');

    alert('✅ Dati storici e demo eliminati.');
    location.reload();
}

