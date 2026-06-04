// PWA Install Banner — mostra un banner "Installa l'app" alla prima visita
(function () {
    // Non mostrare se già in modalità standalone (app già installata)
    if (window.matchMedia('(display-mode: standalone)').matches) return;
    if (window.navigator.standalone === true) return; // iOS Safari

    // Non mostrare se l'utente ha già chiuso il banner
    if (localStorage.getItem('pwa-install-dismissed')) return;

    let deferredPrompt = null;

    // ── Android / Chrome: intercetta l'evento nativo ──────────────────────────
    window.addEventListener('beforeinstallprompt', (e) => {
        e.preventDefault();
        deferredPrompt = e;
        showBanner(false);
    });

    // ── iOS Safari: non ha beforeinstallprompt, mostra istruzioni manuali ────
    const isIOS = /iphone|ipad|ipod/i.test(navigator.userAgent) && !window.MSStream;
    const isSafari = /safari/i.test(navigator.userAgent) && !/crios|fxios|chrome/i.test(navigator.userAgent);
    if (isIOS && isSafari) {
        // Aspetta che la pagina sia caricata
        window.addEventListener('load', () => {
            setTimeout(() => showBanner(true), 1500);
        });
    }

    function showBanner(isIOS) {
        // Evita doppio banner
        if (document.querySelector('.pwa-install-banner')) return;

        const banner = document.createElement('div');
        banner.className = 'pwa-install-banner';
        banner.innerHTML = `
            <span class="pwa-install-banner-text">
                ${isIOS
                    ? 'Installa l\'app: tocca <strong>Condividi</strong> e poi <strong>Aggiungi a Home</strong>'
                    : 'Installa l\'app per un\'esperienza migliore'}
            </span>
            ${isIOS ? '' : '<button class="pwa-install-banner-btn">Installa</button>'}
            <button class="pwa-install-banner-close" aria-label="Chiudi">&times;</button>
        `;

        document.body.appendChild(banner);

        // Anima l'entrata
        requestAnimationFrame(() => {
            requestAnimationFrame(() => banner.classList.add('visible'));
        });

        // Bottone Installa (solo Android/Chrome)
        const installBtn = banner.querySelector('.pwa-install-banner-btn');
        if (installBtn) {
            installBtn.addEventListener('click', async () => {
                if (!deferredPrompt) return;
                deferredPrompt.prompt();
                const { outcome } = await deferredPrompt.userChoice;
                if (outcome === 'accepted') {
                    localStorage.setItem('pwa-install-dismissed', '1');
                }
                deferredPrompt = null;
                banner.classList.remove('visible');
                setTimeout(() => banner.remove(), 400);
            });
        }

        // Bottone chiudi
        banner.querySelector('.pwa-install-banner-close').addEventListener('click', () => {
            localStorage.setItem('pwa-install-dismissed', '1');
            banner.classList.remove('visible');
            setTimeout(() => banner.remove(), 400);
        });
    }
})();
