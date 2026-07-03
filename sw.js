const CACHE_NAME = 'palestria-v577';

const APP_SHELL = [
    './',
    'chi-sono.html',
    'login.html',
    'prenotazioni.html',
    'dove-sono.html',
    'admin.html',
    'super-admin.html',
    'css/super-admin.css',
    'js/super-admin.js',
    'css/style.css',
    'css/admin.css',
    'css/login.css',
    'css/prenotazioni.css',
    'css/chi-sono.css',
    'css/dove-sono.css',
    'js/ui.js',
    'js/egress-debug.js',
    'js/data.js',
    'js/calendar.js',
    'js/booking.js',
    'js/auth.js',
    'js/admin.js',
    'js/admin-registro.js',
    'js/chart-mini.js',
    'js/push.js',
    'js/pwa-install.js',
    'js/sw-update.js',
    'js/new-client-popup.js',
    'js/pull-to-refresh.js',
    'js/silent-refresh.js',
    'js/app-watchdog.js',
    'js/admin-health.js',
    'js/maintenance.js',
    'js/admin-calendar.js',
    'js/admin-schedule.js',
    'js/admin-analytics.js',
    'js/admin-backup.js',
    'js/admin-messaggi.js',
    'js/admin-settings.js',
    'js/admin-payments.js',
    'js/admin-clients.js',
    'js/admin-importa.js',
    'js/admin-schede.js',
    'js/allenamento-report.js',
    'js/modals.js',
    'allenamento.html',
    'css/allenamento.css',
    'tablet.html',
    'css/tablet.css',
    'manifest-tablet.json',
    'images/logo-palestria.png',
    'images/logo-palestria-light.png',
    'manifest.json',
    'index.html',
    'signup-trainer.html',
    'nutrizione.html',
    'regolamento.html',
    'css/nutrizione.css',
    'css/regolamento.css',
    'js/supabase-client.js',
    'js/ls-namespace.js',
    'js/branding-boot.js',
    'js/org-settings.js',
    'js/entitlements.js',
    'privacy.html',
    'termini.html',
];

// Installazione: cacha ogni file singolarmente — se uno manca non blocca tutto
// Usa cache:'reload' per bypassare la HTTP cache del browser e ottenere file freschi
self.addEventListener('install', event => {
    event.waitUntil(
        caches.open(CACHE_NAME).then(cache =>
            Promise.allSettled(
                APP_SHELL.map(url =>
                    fetch(url, { cache: 'reload' })
                        .then(res => {
                            if (res.ok) return cache.put(url, res);
                            console.warn('[SW] Skip (not ok):', url);
                        })
                        .catch(() => console.warn('[SW] Skip:', url))
                )
            )
        ).then(() => self.skipWaiting())
    );
});

// Attivazione: rimuove cache vecchie
self.addEventListener('activate', event => {
    event.waitUntil(
        caches.keys()
            .then(keys => Promise.all(
                keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k))
            ))
            .then(() => self.clients.claim())
    );
});

// Push: riceve notifiche dal server (Supabase Edge Function)
self.addEventListener('push', event => {
    const data = event.data ? event.data.json() : {};
    const title = data.title || 'PalestrIA';
    const options = {
        body: data.body || '',
        icon: 'images/logo-palestria.png',
        badge: 'images/badge-mono-96.png',
        tag: data.tag || 'palestria-push',
        renotify: true,
        data: { url: data.url || 'prenotazioni.html' }
    };
    event.waitUntil(self.registration.showNotification(title, options));
});

// Notifiche: porta in primo piano la finestra app al click
self.addEventListener('notificationclick', event => {
    event.notification.close();
    const targetUrl = event.notification.data?.url || 'prenotazioni.html';
    event.waitUntil(
        self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(clients => {
            const appClient = clients[0];
            if (appClient) {
                appClient.focus();
                appClient.navigate(targetUrl);
                return;
            }
            return self.clients.openWindow(targetUrl);
        })
    );
});

// Fetch con timeout: su rete raggiungibile ma lentissima (es. Mac post-sleep con
// connessione degradata) un fetch resterebbe appeso fino al timeout di default del
// browser (~60s), congelando il caricamento dell'asset. Con AbortController forziamo
// il fallback alla cache entro `ms` (causa radice C10 del freeze idle).
function fetchWithTimeout(request, ms) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), ms);
    return fetch(request, { signal: controller.signal })
        .finally(() => clearTimeout(timer));
}

// Fetch: Network First per HTML, Cache First per asset statici
self.addEventListener('fetch', event => {
    const { request } = event;
    const url = new URL(request.url);

    // Ignora richieste non-GET e risorse esterne (Supabase, Google Fonts, ecc.)
    if (request.method !== 'GET') return;
    if (url.origin !== self.location.origin) return;

    // Network First per le pagine HTML (timeout 8s → fallback cache se rete appesa)
    if (request.mode === 'navigate') {
        event.respondWith(
            fetchWithTimeout(request, 8000)
                .then(response => {
                    // Cachare SOLO risposte valide: un 404/5xx transitorio (es. buco DNS/hosting
                    // durante un cambio di deploy) NON deve essere persistito come fallback offline,
                    // altrimenti la PWA resta "appesa" su una pagina 404 anche a sito sano. Stesso
                    // guard già presente sugli handler JS/CSS e immagini sotto.
                    if (response.ok) {
                        const clone = response.clone();
                        caches.open(CACHE_NAME).then(cache => cache.put(request, clone));
                    }
                    return response;
                })
                .catch(() => caches.match(request, { ignoreSearch: true }))
        );
        return;
    }

    // JS + CSS: Cache First con match ESATTO (incluso ?v=N), fallback rete.
    // L'HTML resta Network First e comanda le versioni: dopo un deploy referenzia
    // ?v=N+1 → cache miss → scaricato fresco. File invariato → servito istantaneo.
    // Il match esatto evita di servire stale: mai matchare ?v= nuovo con file vecchio.
    if (url.pathname.endsWith('.js') || url.pathname.endsWith('.css')) {
        event.respondWith(
            caches.match(request).then(cached => {
                if (cached) return cached;
                return fetchWithTimeout(request, 8000)
                    .then(response => {
                        if (response.ok) {
                            const clone = response.clone();
                            caches.open(CACHE_NAME).then(cache => cache.put(request, clone));
                        }
                        return response;
                    })
                    // Offline: meglio il pre-cache senza query (best effort) che niente
                    .catch(() => caches.match(request, { ignoreSearch: true }));
            })
        );
        return;
    }

    // Cache First per immagini e altri asset statici
    event.respondWith(
        caches.match(request, { ignoreSearch: true }).then(cached => {
            if (cached) return cached;
            return fetch(request).then(response => {
                if (response.ok) {
                    const clone = response.clone();
                    caches.open(CACHE_NAME).then(cache => cache.put(request, clone));
                }
                return response;
            });
        })
    );
});
