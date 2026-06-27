/**
 * push.js — Gestione delle Web Push notifications (subscription + invio notifiche admin).
 *
 * COSA FA
 * Registra/aggiorna la subscription push del browser, la salva su Supabase, gestisce permessi
 * (incluso il caso iOS/standalone e il banner "permesso negato"), la cleanup al logout, e
 * inoltra le notifiche agli admin della org (nuova prenotazione / annullamento / nuovo cliente).
 *
 * COME FUNZIONA
 * - Flag PUSH_ENABLED (oggi false = demo, nessuna Edge Function di notifica deployata): gatea la
 *   subscribe ma lascia raggiungibile il resto (es. teardown al logout). VAPID_PUBLIC_KEY è la
 *   chiave pubblica; la privata sta nel secret edge VAPID_PRIVATE_KEY.
 * - Subscribe: registerPushSubscription() (guard anti-concorrenza _pushInFlight, una sola volta a
 *   sessione via _pushRegisteredThisSession/_pushFailedThisSession) usa urlBase64ToUint8Array() e
 *   pushManager.subscribe(); rigenera la subscription se la chiave VAPID è cambiata o il permesso
 *   era stato revocato. savePushSubscription()/_doSavePush() persistono su tabella push_subscriptions.
 * - Logout: teardownPushOnLogout() rimuove il backup locale e annulla la subscription (così
 *   l'endpoint del tenant A non resta legato ad A su un device condiviso).
 * - Notifiche admin: notifyAdminBooking()/notifyAdminCancellation()/notifyAdminNewClient() fanno
 *   fetch alle Edge Functions notify-admin-booking|cancellation|new-client (POST a
 *   ${SUPABASE_URL}/functions/v1/...). La org è risolta server-side dal booking_id; il token è la
 *   ANON_KEY (_getPushAuthToken). _disabledSlotAvailableBroadcast() colpisce slot-available-disabled.
 * - Permessi/UI: promptPushPermission(), _syncPushEnabled() (aggiorna profiles.push_enabled),
 *   _showDeniedBanner(), _isIOS()/_isStandalone()/_userHasBookings(); branding via _brandPrimaryColor()
 *   (OrgSettings 'branding.primary_color' → CSS var --primary-purple → default #8B5CF6).
 *
 * CONNESSIONI
 * - Tabelle Supabase via supabaseClient: push_subscriptions, profiles (push_enabled), org-scoped da RLS.
 * - Edge Functions notify-admin-* (vedi supabase/functions/). Service Worker (sw.js) per la subscription.
 * - Helper esterni: SUPABASE_ANON_KEY/SUPABASE_URL (js/supabase-client.js), OrgSettings, ensureValidSession.
 */
// Push notification subscription management
// Chiave pubblica VAPID — la privata va nelle env vars di Supabase (secret VAPID_PRIVATE_KEY)
const VAPID_PUBLIC_KEY = 'BOIkkllAmpdW6-MWn85UW36xGPDk9rJDtEIs23w9gmVxGeKx3OSTqTVzcZOcz7gfm8kCHmzc3jp6J2IlEXC0AGA';

// Flag esplicito: push in "Demo" (nessuna Edge Function di notifica push deployata).
// Sostituisce i vecchi early-return che rendevano irraggiungibile il resto del file
// (inclusa la cleanup VAPID per il logout). Gateando dietro un flag, il codice resta
// raggiungibile e si può riattivare cambiando una sola riga.
const PUSH_ENABLED = false;

// Helper: token per autenticazione Edge Functions.
// Per booking/cancellation va bene la ANON_KEY: la gateway Supabase l'accetta e le
// edge notify-admin-* risolvono ora la org dal booking_id lato server (server-authoritative),
// quindi non serve un Bearer utente. Se in futuro si vuole l'identità del caller, passare
// qui il token di sessione con fallback alla anon key.
function _getPushAuthToken() {
    return typeof SUPABASE_ANON_KEY !== 'undefined' ? SUPABASE_ANON_KEY : null;
}

// Cleanup push al logout: rimuove il backup locale e (best-effort) annulla la
// subscription attiva del browser, così l'endpoint push del tenant A non resta legato
// all'identità di A su un device condiviso. Funziona anche con PUSH_ENABLED false.
async function teardownPushOnLogout() {
    try { localStorage.removeItem('push_subscription'); } catch (_) {}
    try {
        if (('PushManager' in window) && navigator.serviceWorker) {
            const reg = await navigator.serviceWorker.getRegistration();
            const sub = reg && await reg.pushManager.getSubscription();
            if (sub) { try { await sub.unsubscribe(); } catch (_) {} }
        }
    } catch (_) { /* best-effort */ }
}
if (typeof window !== 'undefined') window.teardownPushOnLogout = teardownPushOnLogout;

// Colore primario per-org (branding) con fallback al viola di default.
// Legge da OrgSettings se disponibile (guard typeof), altrimenti dalla CSS var
// --primary-purple, infine dal default hardcoded.
function _brandPrimaryColor() {
    if (typeof OrgSettings !== 'undefined') {
        const c = OrgSettings.getString('branding.primary_color', '');
        if (c) return c;
    }
    try {
        const cssVar = getComputedStyle(document.documentElement)
            .getPropertyValue('--primary-purple').trim();
        if (cssVar) return cssVar;
    } catch (_) {}
    return '#8B5CF6';
}

function urlBase64ToUint8Array(base64String) {
    const padding = '='.repeat((4 - base64String.length % 4) % 4);
    const base64 = (base64String + padding).replace(/-/g, '+').replace(/_/g, '/');
    const raw = atob(base64);
    return Uint8Array.from([...raw].map(c => c.charCodeAt(0)));
}

// Guard per dedup: evita chiamate concorrenti a pushManager.subscribe (che su Chrome
// con rete saturata causano "Registration failed - push service error").
let _pushInFlight = null;
let _pushRegisteredThisSession = false;
// Guard di sessione: se la subscribe fallisce, NON ritentiamo nella stessa apertura.
// Il retry differito a 8s tipicamente cadeva durante le sync admin pesanti, peggiorando
// la congestione. Si ritenta al prossimo page load.
let _pushFailedThisSession = false;

async function registerPushSubscription() {
    // Demo: push notifications disabilitate (no Edge Functions di notifica deployate)
    if (!PUSH_ENABLED) return null;

    if (!('PushManager' in window) || !navigator.serviceWorker) return null;
    if (_pushInFlight) return _pushInFlight;
    if (_pushRegisteredThisSession || _pushFailedThisSession) return null;

    _pushInFlight = (async () => {
        const reg = await navigator.serviceWorker.ready;
        const appKey = urlBase64ToUint8Array(VAPID_PUBLIC_KEY);

        async function _subscribe() {
            let sub = await reg.pushManager.getSubscription();
            if (sub) {
                const existingKey = sub.options?.applicationServerKey;
                if (existingKey) {
                    const a = new Uint8Array(existingKey);
                    const b = appKey;
                    const mismatch = a.length !== b.length || a.some((v, i) => v !== b[i]);
                    if (mismatch) {
                        console.log('[Push] Chiave VAPID cambiata — cancello subscription vecchia');
                        await sub.unsubscribe();
                        sub = null;
                    }
                }
                if (sub && localStorage.getItem('push_permission_was_denied') === '1') {
                    console.log('[Push] Permesso era stato revocato — forzo rinnovo subscription');
                    localStorage.removeItem('push_permission_was_denied');
                    await sub.unsubscribe();
                    sub = null;
                }
            }
            if (!sub) {
                sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: appKey });
            }
            return sub;
        }

        try {
            const sub = await _subscribe();
            await savePushSubscription(sub);
            _pushRegisteredThisSession = true;
            return sub;
        } catch (e) {
            console.warn('[Push] Subscription fallita (ritento al prossimo page load):', e.message);
            _pushFailedThisSession = true;
            return null;
        }
    })();

    try {
        return await _pushInFlight;
    } finally {
        _pushInFlight = null;
    }
}

async function savePushSubscription(subscription) {
    const json = subscription.toJSON();

    // Recupera user_id direttamente dalla sessione Supabase (non dipende dal timing di initAuth)
    let userId = null;
    let userEmail = null;
    if (typeof supabaseClient !== 'undefined') {
        try {
            const { data: { session } } = await supabaseAuth.auth.getSession();
            userId    = session?.user?.id    ?? null;
            userEmail = session?.user?.email ?? null;
        } catch {}
    }
    // Fallback al cached getCurrentUser se la sessione non è ancora pronta
    if (!userId) {
        const u = typeof getCurrentUser === 'function' ? getCurrentUser() : null;
        userId    = u?.id    ?? null;
        userEmail = u?.email ?? null;
    }

    // Se l'utente non è ancora autenticato, ritenta dopo 3 secondi (una sola volta)
    if (!userId && typeof supabaseClient !== 'undefined') {
        console.log('[Push] Utente non ancora autenticato — ritento fra 3s');
        setTimeout(async () => {
            try {
                const { data: { session } } = await supabaseAuth.auth.getSession();
                const retryUserId = session?.user?.id ?? null;
                const retryEmail  = session?.user?.email ?? null;
                if (retryUserId) {
                    await _doSavePush(json, retryUserId, retryEmail);
                } else {
                    console.warn('[Push] Retry fallito — utente ancora non autenticato');
                }
            } catch (e) {
                console.warn('[Push] Retry savePushSubscription fallito:', e);
            }
        }, 3000);
        // Salva comunque in locale come backup
        localStorage.setItem('push_subscription', JSON.stringify({
            endpoint: json.endpoint, p256dh: json.keys.p256dh, auth: json.keys.auth,
            user_email: userEmail, saved_at: new Date().toISOString()
        }));
        return;
    }

    await _doSavePush(json, userId, userEmail);
}

async function _doSavePush(json, userId, userEmail) {
    // Salva su Supabase via RPC (SECURITY DEFINER — bypassa RLS)
    if (typeof supabaseClient !== 'undefined' && userId) {
        const { error } = await supabaseClient.rpc('save_push_subscription', {
            p_endpoint:   json.endpoint,
            p_p256dh:     json.keys.p256dh,
            p_auth:       json.keys.auth,
            p_user_email: userEmail,
            p_user_id:    userId,
        });
        if (error) {
            console.warn('[Push] Supabase RPC error:', error.message, error);
            const toastFn = typeof showToast === 'function' ? showToast : null;
            toastFn?.('Notifiche attivate, ma non salvate sul server. Riprova.', 'warning');
        } else {
            console.log('[Push] Subscription salvata su Supabase per', userEmail, userId);
        }
    } else {
        console.warn('[Push] Utente non autenticato — subscription non salvata su Supabase', { userId, userEmail, supabaseReady: typeof supabaseClient !== 'undefined' });
    }

    // Backup locale
    localStorage.setItem('push_subscription', JSON.stringify({
        endpoint:   json.endpoint,
        p256dh:     json.keys.p256dh,
        auth:       json.keys.auth,
        user_email: userEmail,
        saved_at:   new Date().toISOString()
    }));
}

// Notifica "slot disponibile" dopo una cancellazione — chiamata dal client
async function _disabledSlotAvailableBroadcast(booking) {
    if (!PUSH_ENABLED) return;
    if (typeof SUPABASE_URL === 'undefined') return;

    // Notifica solo se lo slot era pieno prima della cancellazione.
    // A questo punto la cancellazione è già avvenuta: se ora ci sono (capacity-1)
    // prenotati confermati, significa che lo slot era pieno.
    if (typeof BookingStorage !== 'undefined') {
        const allBookings = BookingStorage.getAllBookings();
        const confirmedInSlot = allBookings.filter(b =>
            b.date === booking.date && b.time === booking.time && b.status === 'confirmed'
        ).length;
        const capacity = typeof BookingStorage.getEffectiveCapacity === 'function'
            ? BookingStorage.getEffectiveCapacity(booking.date, booking.time, booking.slotType)
            : 5;
        const wasFullBeforeCancellation = confirmedInSlot === capacity - 1;
        if (!wasFullBeforeCancellation) {
            console.log('[Push] Slot non era pieno — notifica slot available saltata');
            return;
        }
    }

    const user = typeof getCurrentUser === 'function' ? getCurrentUser() : null;
    let excludeUserId = user?.id ?? null;
    // Fallback: prova dalla sessione Supabase
    if (!excludeUserId && typeof supabaseClient !== 'undefined') {
        try {
            const { data: { session } } = await supabaseAuth.auth.getSession();
            excludeUserId = session?.user?.id ?? null;
        } catch {}
    }
    const dateDisplay = booking.dateDisplay || booking.date_display || booking.date || '';
    const date = booking.date || '';
    const time = booking.time || '';
    const spotsAvailable = capacity - confirmedInSlot;
    const token = await _getPushAuthToken();
    if (!token) { console.warn('[Push] slot available disabilitato: nessun token disponibile'); return; }
    try {
        await fetch(`${SUPABASE_URL}/functions/v1/slot-available-disabled`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + token },
            body: JSON.stringify({ date_display: dateDisplay, date, time, exclude_user_id: excludeUserId, spots_available: spotsAvailable, max_capacity: capacity }),
        });
    } catch (e) {
        console.warn('[Push] slot available disabilitato error:', e);
    }
}

// Notifica admin dopo una prenotazione confermata
async function notifyAdminBooking(booking) {
    console.log('[Push] notifyAdminBooking chiamata', booking);
    if (typeof SUPABASE_URL === 'undefined') {
        console.warn('[Push] SUPABASE_URL non definito — notifica admin saltata');
        return;
    }

    const dateDisplay = booking.dateDisplay || booking.date_display || booking.date || '';
    const date = booking.date || '';
    const time = booking.time || '';
    const slotType = booking.slotType || booking.slot_type || '';
    const maxCapacity = typeof BookingStorage !== 'undefined' && typeof BookingStorage.getEffectiveCapacity === 'function'
        ? BookingStorage.getEffectiveCapacity(date, time, slotType)
        : 5;

    const token = await _getPushAuthToken();
    if (!token) { console.warn('[Push] notifyAdminBooking: nessun token disponibile'); return; }

    try {
        const resp = await fetch(`${SUPABASE_URL}/functions/v1/notify-admin-booking`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer ' + token,
            },
            body: JSON.stringify({
                // La edge risolve la org dal booking_id (server-authoritative): non si invia più org_id.
                booking_id: booking.id || null,
                name: booking.name || '',
                date_display: dateDisplay,
                date,
                time,
                slot_type: slotType,
                max_capacity: maxCapacity,
            }),
        });
        const result = await resp.json();
        console.log('[Push] notifyAdminBooking response:', resp.status, result);
    } catch (e) {
        console.warn('[Push] notifyAdminBooking error:', e);
    }
}

// Notifica admin dopo un annullamento
async function notifyAdminCancellation(booking) {
    console.log('[Push] notifyAdminCancellation chiamata', booking);
    if (typeof SUPABASE_URL === 'undefined') {
        console.warn('[Push] SUPABASE_URL non definito — notifica admin saltata');
        return;
    }

    const dateDisplay = booking.dateDisplay || booking.date_display || booking.date || '';
    const date = booking.date || '';
    const time = booking.time || '';
    const slotType = booking.slotType || booking.slot_type || '';
    const maxCapacity = typeof BookingStorage !== 'undefined' && typeof BookingStorage.getEffectiveCapacity === 'function'
        ? BookingStorage.getEffectiveCapacity(date, time, slotType)
        : 5;

    const token = await _getPushAuthToken();
    if (!token) { console.warn('[Push] notifyAdminCancellation: nessun token disponibile'); return; }

    try {
        const resp = await fetch(`${SUPABASE_URL}/functions/v1/notify-admin-cancellation`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer ' + token,
            },
            body: JSON.stringify({
                // La edge risolve la org dal booking_id (server-authoritative): non si invia più org_id.
                booking_id: booking.id || null,
                name: booking.name || '',
                date_display: dateDisplay,
                date,
                time,
                slot_type: slotType,
                max_capacity: maxCapacity,
            }),
        });
        const result = await resp.json();
        console.log('[Push] notifyAdminCancellation response:', resp.status, result);
    } catch (e) {
        console.warn('[Push] notifyAdminCancellation error:', e);
    }
}

// Notifica admin dopo una nuova registrazione
async function notifyAdminNewClient(name) {
    console.log('[Push] notifyAdminNewClient chiamata', name);
    if (typeof SUPABASE_URL === 'undefined') {
        console.warn('[Push] SUPABASE_URL non definito — notifica admin saltata');
        return;
    }

    // La edge richiede ora un Bearer utente VALIDO (fa getUser() e deriva la org dal caller).
    // Usa il token di sessione, non la anon key. login.html la chiama dopo signup → la sessione esiste.
    let accessToken = null;
    if (typeof supabaseAuth !== 'undefined') {
        try {
            const { data: { session } } = await supabaseAuth.auth.getSession();
            accessToken = session?.access_token ?? null;
        } catch (_) {}
    }
    if (!accessToken) { console.warn('[Push] notifyAdminNewClient: nessun token di sessione — chiamata saltata'); return; }

    try {
        const resp = await fetch(`${SUPABASE_URL}/functions/v1/notify-admin-new-client`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer ' + accessToken,
            },
            body: JSON.stringify({ name }),
        });
        const result = await resp.json();
        console.log('[Push] notifyAdminNewClient response:', resp.status, result);
    } catch (e) {
        console.warn('[Push] notifyAdminNewClient error:', e);
    }
}

// Ad ogni apertura: traccia stato permesso e registra subscription
if ('Notification' in window) {
    if (Notification.permission === 'granted') {
        const _scheduleRegister = () => navigator.serviceWorker?.ready.then(() => registerPushSubscription());
        if ('requestIdleCallback' in window) {
            requestIdleCallback(_scheduleRegister, { timeout: 4000 });
        } else {
            setTimeout(_scheduleRegister, 3000);
        }
    } else if (Notification.permission === 'denied') {
        localStorage.setItem('push_permission_was_denied', '1');
        localStorage.removeItem('push_permission_granted');
    }
}

// Sync push_enabled su ogni pagina — salva nel profilo solo quando lo stato è definitivo.
// Non salva false se il permesso è 'default' (non ancora deciso).
function _syncPushEnabled() {
    if (!('Notification' in window)) return;
    const perm = Notification.permission;
    // Solo 'granted' → true, 'denied' → false. 'default' → non aggiornare.
    if (perm !== 'granted' && perm !== 'denied') return;
    const enabled = perm === 'granted';
    setTimeout(async () => {
        if (typeof supabaseClient === 'undefined') return;
        try {
            const { data: { session } } = await supabaseAuth.auth.getSession();
            if (session?.user?.id) {
                // Aggiorna il proprio profilo (RLS consente l'update di id = auth.uid()).
                // Per trainer/staff senza riga profiles → 0 righe, nessun errore.
                await supabaseClient.from('profiles').update({ push_enabled: enabled }).eq('id', session.user.id);
                console.log('[Push] push_enabled salvato:', enabled);
            }
        } catch (e) {
            console.warn('[Push] sync push_enabled fallito:', e);
        }
    }, 5000);
}
_syncPushEnabled();


// Rileva iOS
function _isIOS() {
    return /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
}
// Rileva se la PWA è installata (standalone / display-mode)
function _isStandalone() {
    return window.matchMedia('(display-mode: standalone)').matches || navigator.standalone === true;
}

// Banner per permesso notifiche negato — guida l'utente a riabilitare dalle impostazioni.
// Appare al massimo una volta ogni 7 giorni.
function _showDeniedBanner() {
    if (!_userHasBookings()) return;
    const storageKey = 'denied_banner_shown_push';
    const lastShown = localStorage.getItem(storageKey);
    if (lastShown && Date.now() - Number(lastShown) < 7 * 24 * 60 * 60 * 1000) return;
    if (document.getElementById('pushBanner') || document.getElementById('deniedBanner')) return;

    const banner = document.createElement('div');
    banner.id = 'deniedBanner';
    banner.style.cssText = 'position:fixed;bottom:20px;left:50%;transform:translateX(-50%);width:calc(100% - 32px);max-width:400px;background:#1a1a1a;color:#fff;border-radius:18px;padding:18px 18px 16px;z-index:9999;box-shadow:0 8px 32px rgba(0,0,0,0.4);font-family:inherit;box-sizing:border-box';
    banner.innerHTML = `
        <div style="display:flex;align-items:center;gap:12px;margin-bottom:14px">
            <span style="font-size:26px;line-height:1">🔔</span>
            <div>
                <div style="font-weight:700;font-size:15px;line-height:1.2">Notifiche bloccate</div>
                <div style="font-size:12px;color:#aaa;margin-top:4px;line-height:1.5">Per ricevere promemoria e avvisi, riabilita le notifiche nelle impostazioni del sito.</div>
            </div>
        </div>
        <div style="display:flex;gap:10px">
            <button id="deniedBannerDone" style="flex:1;background:${_brandPrimaryColor()};color:#fff;border:none;padding:12px;border-radius:10px;cursor:pointer;font-weight:700;font-size:14px">Fatto, ricarica</button>
            <button id="deniedBannerLater" style="flex:0 0 auto;background:#333;color:#aaa;border:none;padding:12px 16px;border-radius:10px;cursor:pointer;font-size:13px">Dopo</button>
        </div>
    `;
    document.body.appendChild(banner);
    localStorage.setItem(storageKey, String(Date.now()));

    document.getElementById('deniedBannerDone').addEventListener('click', () => {
        location.reload();
    });
    document.getElementById('deniedBannerLater').addEventListener('click', () => banner.remove());
}

// Controlla se l'utente loggato ha almeno una prenotazione (attiva o passata)
function _userHasBookings() {
    const user = typeof getCurrentUser === 'function' ? getCurrentUser() : null;
    if (!user) return false;
    if (typeof BookingStorage === 'undefined') return false;
    const all = BookingStorage.getAllBookings();
    return all.some(b => b.userId === user.id);
}

// Mostra banner "Abilita notifiche" ad ogni apertura finché non viene accettato o negato dal browser.
// Chiamata da index.html dopo initAuth().
async function promptPushPermission() {
    if (!('Notification' in window) || !('PushManager' in window)) return;
    // Mostra banner solo per utenti con almeno una prenotazione
    if (Notification.permission !== 'granted' && !_userHasBookings()) return;

    // Su iOS le push funzionano SOLO se la PWA è installata (aggiunta alla Home).
    // Se non è installata, non mostrare il banner push — mostra invece un invito a installare.
    if (_isIOS() && !_isStandalone()) {
        // Non mostrare il banner notifiche — verrà gestito dal banner installazione PWA
        return;
    }

    if (Notification.permission === 'granted') {
        localStorage.setItem('push_permission_granted', '1');
        await registerPushSubscription();
        return;
    }
    if (Notification.permission === 'denied') {
        localStorage.setItem('push_permission_was_denied', '1');
        localStorage.removeItem('push_permission_granted');
        _showDeniedBanner();
        return;
    }

    // Su iOS il permission state può resettarsi a 'default' tra le sessioni.
    // Se l'utente aveva già concesso il permesso, ri-registra senza mostrare il banner.
    if (localStorage.getItem('push_permission_granted') === '1') {
        const permission = await Notification.requestPermission();
        if (permission === 'granted') {
            await registerPushSubscription();
        } else {
            localStorage.removeItem('push_permission_granted');
        }
        return;
    }

    const existing = document.getElementById('pushBanner');
    if (existing) return;

    const banner = document.createElement('div');
    banner.id = 'pushBanner';
    banner.style.cssText = 'position:fixed;bottom:20px;left:50%;transform:translateX(-50%);width:calc(100% - 32px);max-width:400px;background:#1a1a1a;color:#fff;border-radius:18px;padding:18px 18px 16px;z-index:9999;box-shadow:0 8px 32px rgba(0,0,0,0.4);font-family:inherit;box-sizing:border-box';
    banner.innerHTML = `
        <div style="display:flex;align-items:center;gap:12px;margin-bottom:14px">
            <span style="font-size:26px;line-height:1">🔔</span>
            <div>
                <div style="font-weight:700;font-size:15px;line-height:1.2">Abilita notifiche</div>
                <div style="font-size:12px;color:#aaa;margin-top:4px;line-height:1.5">Promemoria 1h prima della lezione<br>e avvisi quando si libera uno slot</div>
            </div>
        </div>
        <button id="pushBannerYes" style="width:100%;background:${_brandPrimaryColor()};color:#fff;border:none;padding:12px;border-radius:10px;cursor:pointer;font-weight:700;font-size:14px;letter-spacing:0.01em">Abilita notifiche</button>
    `;
    document.body.appendChild(banner);

    document.getElementById('pushBannerYes').addEventListener('click', async () => {
        banner.remove();
        const permission = await Notification.requestPermission();
        if (permission === 'granted') {
            localStorage.setItem('push_permission_granted', '1');
            await registerPushSubscription();
        }
    });
}
