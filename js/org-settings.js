// ══════════════════════════════════════════════════════════════════════════════
// org-settings.js — Impostazioni per-tenant (org-aware)
//
// Sostituisce le vecchie Storage classes globali (DebtThreshold, CancellationMode,
// CertBooking, ...) con un layer unico che legge/scrive su org_settings filtrando
// per org_id corrente. Pattern dual-layer: cache in memoria + localStorage
// NAMESPACED per org (org_<id>_<key>) per evitare bleed cross-tenant sullo stesso
// browser. value è jsonb (niente più String()).
//
// Dipendenze globali: supabaseClient (js/supabase-client.js), window._orgId /
// window._orgSlug / window._currentUser (settati da auth.js).
// ══════════════════════════════════════════════════════════════════════════════

(function (global) {
    'use strict';

    const _cache = new Map();        // key -> value (già parsato)
    let   _orgId = null;
    let   _loaded = false;
    let   _rtChannel = null;
    const _listeners = new Set();    // callback(key, value) su cambi realtime/locali

    // ── risoluzione org ─────────────────────────────────────────────────────
    function _resolveOrgId() {
        // 1) settato da auth.js dopo il login (claim app_metadata.org_id)
        if (global._orgId) return global._orgId;
        // 2) profilo cliente caricato
        if (global._currentUser && global._currentUser.org_id) return global._currentUser.org_id;
        return null;
    }

    function _orgSlug() {
        // per i client anonimi: slug da sottodominio o primo segmento di path o ?org=
        if (global._orgSlug) return global._orgSlug;
        try {
            const host = location.hostname.split('.');
            if (host.length > 2 && !['www', 'app'].includes(host[0])) return host[0];
            const qs = new URLSearchParams(location.search).get('org');
            if (qs) return qs;
        } catch (_) {}
        return null;
    }

    function _lsKey(key) {
        const oid = _orgId || _resolveOrgId() || 'anon';
        return `org_${oid}_${key}`;
    }

    function _lsGet(key) {
        try {
            const raw = localStorage.getItem(_lsKey(key));
            return raw == null ? undefined : JSON.parse(raw);
        } catch (_) { return undefined; }
    }
    function _lsSet(key, value) {
        try { localStorage.setItem(_lsKey(key), JSON.stringify(value)); } catch (_) {}
    }

    // ── coercion difensiva (le vecchie get() facevano parseFloat/=== 'true') ──
    function asBool(v, dflt = false)  { if (v === undefined || v === null) return dflt; return v === true || v === 'true' || v === 1; }
    function asNumber(v, dflt = 0)    { const n = typeof v === 'number' ? v : parseFloat(v); return Number.isFinite(n) ? n : dflt; }
    function asString(v, dflt = '')   { return v === undefined || v === null ? dflt : String(v); }

    // ── caricamento da DB ─────────────────────────────────────────────────────
    async function load(force = false) {
        if (_loaded && !force) return;
        _orgId = _resolveOrgId();

        try {
            if (_orgId) {
                // utente autenticato → RLS limita alla propria org
                const { data, error } = await supabaseClient
                    .from('org_settings')
                    .select('key,value')
                    .eq('org_id', _orgId);
                if (!error && Array.isArray(data)) {
                    for (const row of data) { _cache.set(row.key, row.value); _lsSet(row.key, row.value); }
                }
            } else {
                // anonimo → whitelist pubblica via RPC
                const slug = _orgSlug();
                if (slug) {
                    const { data, error } = await supabaseClient.rpc('get_public_org_settings', { p_org_slug: slug });
                    if (!error && data && typeof data === 'object') {
                        for (const [k, v] of Object.entries(data)) { _cache.set(k, v); _lsSet(k, v); }
                    }
                }
            }
        } catch (e) {
            console.warn('[OrgSettings] load fallito, uso cache locale:', e && e.message);
        }
        _loaded = true;
        _subscribeRealtime();
        applyBranding();
    }

    // ── API sincrona di lettura (cache → localStorage → default) ──────────────
    function get(key, dflt) {
        if (_cache.has(key)) return _cache.get(key);
        const ls = _lsGet(key);
        if (ls !== undefined) { _cache.set(key, ls); return ls; }
        return dflt;
    }
    function getBool(key, dflt = false)   { return asBool(get(key), dflt); }
    function getNumber(key, dflt = 0)     { return asNumber(get(key), dflt); }
    function getString(key, dflt = '')    { return asString(get(key), dflt); }

    // ── scrittura (solo owner/admin: la RPC verifica is_org_admin) ────────────
    async function set(key, value) {
        _cache.set(key, value);
        _lsSet(key, value);
        _emit(key, value);
        const { error } = await supabaseClient.rpc('upsert_org_setting', { p_key: key, p_value: value });
        if (error) { console.error('[OrgSettings] upsert fallito:', error.message); throw error; }
    }

    // ── realtime filtrato per org ─────────────────────────────────────────────
    function _subscribeRealtime() {
        if (_rtChannel || !_orgId) return;
        try {
            _rtChannel = supabaseClient
                .channel(`org_settings_${_orgId}`)
                .on('postgres_changes',
                    { event: '*', schema: 'public', table: 'org_settings', filter: `org_id=eq.${_orgId}` },
                    (payload) => {
                        const row = payload.new || payload.old;
                        if (!row) return;
                        if (payload.eventType === 'DELETE') { _cache.delete(row.key); }
                        else { _cache.set(row.key, row.value); _lsSet(row.key, row.value); }
                        _emit(row.key, _cache.get(row.key));
                        if (row.key && row.key.startsWith('branding.')) applyBranding();
                    })
                .subscribe();
        } catch (e) { console.warn('[OrgSettings] realtime non disponibile:', e && e.message); }
    }

    function onChange(cb) { _listeners.add(cb); return () => _listeners.delete(cb); }
    function _emit(key, value) { for (const cb of _listeners) { try { cb(key, value); } catch (_) {} } }

    // ── branding: applica colore primario e nome studio a runtime ─────────────
    function applyBranding() {
        try {
            const color = getString('branding.primary_color', '');
            if (color) document.documentElement.style.setProperty('--primary-purple', color);
            const name = getString('branding.studio_name', '');
            if (name) {
                document.querySelectorAll('[data-org-name]').forEach(el => { el.textContent = name; });
            }
        } catch (_) {}
    }

    // helper localizzazione usati altrove (timezone/currency per-org)
    function timezone() { return getString('locale.timezone', 'Europe/Rome'); }
    function currency() { return getString('locale.currency', 'EUR'); }

    global.OrgSettings = {
        load, get, getBool, getNumber, getString, set, onChange, applyBranding,
        timezone, currency, asBool, asNumber, asString,
        get orgId() { return _orgId || _resolveOrgId(); },
    };
})(window);
