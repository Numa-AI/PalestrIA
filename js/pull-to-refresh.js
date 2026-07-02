// Pull-to-refresh per iOS in modalita standalone (PWA aggiunta a Home).
// Su Android e Safari normale il browser gestisce gia il gesto nativo.
(function () {
    var ua = navigator.userAgent || '';
    var isIOS = /iPad|iPhone|iPod/.test(ua) ||
        (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
    var isStandalone =
        (window.matchMedia && window.matchMedia('(display-mode: standalone)').matches) ||
        window.navigator.standalone === true;

    if (!isIOS || !isStandalone) return;

    var THRESHOLD = 70;
    var MAX_PULL = 120;
    var RESISTANCE = 0.5;
    var startY = 0;
    var currentPull = 0;
    var pulling = false;
    var armed = false;

    var indicator = document.createElement('div');
    indicator.setAttribute('aria-hidden', 'true');
    indicator.style.cssText = [
        'position:fixed', 'top:0', 'left:50%',
        'transform:translate(-50%,-100%)',
        'z-index:99999', 'width:40px', 'height:40px',
        'border-radius:50%', 'background:rgba(255,255,255,0.95)',
        'box-shadow:0 2px 8px rgba(0,0,0,0.15)',
        'display:flex', 'align-items:center', 'justify-content:center',
        'pointer-events:none',
        'transition:transform 0.2s ease, opacity 0.2s ease',
        'opacity:0',
        'margin-top:env(safe-area-inset-top, 0px)'
    ].join(';');
    indicator.innerHTML =
        '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="#222" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">' +
        '<polyline points="1 4 1 10 7 10"></polyline>' +
        '<path d="M3.51 15a9 9 0 1 0 2.13-9.36L1 10"></path>' +
        '</svg>';

    function attachIndicator() {
        if (!indicator.isConnected && document.body) document.body.appendChild(indicator);
    }
    if (document.body) attachIndicator();
    else document.addEventListener('DOMContentLoaded', attachIndicator);

    function isInsideScrollable(el) {
        var node = el;
        while (node && node !== document.body && node !== document.documentElement) {
            try {
                var s = window.getComputedStyle(node);
                var oy = s.overflowY;
                if ((oy === 'auto' || oy === 'scroll') && node.scrollHeight > node.clientHeight) return true;
            } catch (_) {}
            node = node.parentElement;
        }
        return false;
    }

    function setIndicator(progress) {
        var translateY = Math.min(progress, 1.4) * 70;
        var opacity = Math.min(progress, 1);
        var rotate = progress * 270;
        indicator.style.opacity = opacity;
        indicator.style.transform =
            'translate(-50%, ' + (translateY - 50) + 'px) rotate(' + rotate + 'deg)';
    }

    function reset(animated) {
        indicator.style.transition = animated ? 'transform 0.25s ease, opacity 0.25s ease' : 'none';
        indicator.style.opacity = '0';
        indicator.style.transform = 'translate(-50%, -100%)';
        if (!animated) {
            indicator.offsetHeight;
            indicator.style.transition = 'transform 0.2s ease, opacity 0.2s ease';
        }
    }

    // Con la shell iOS strutturale (admin.html: html overflow:hidden, scroller = body)
    // window.scrollY vale sempre 0 e lo scroll reale è su document.body. Leggendo
    // entrambi il gesto si arma solo a pagina in cima anche col body-scroller (senza,
    // un pull-down a metà pagina ricaricherebbe l'app). Sulle pagine col root scroller
    // classico body.scrollTop è 0 → comportamento invariato.
    function pageScrollTop() {
        return window.scrollY || document.body.scrollTop || 0;
    }

    function onTouchStart(e) {
        if (e.touches.length !== 1 || pageScrollTop() > 0 || isInsideScrollable(e.target)) {
            armed = false;
            return;
        }
        startY = e.touches[0].clientY;
        currentPull = 0;
        pulling = false;
        armed = true;
    }

    function onTouchMove(e) {
        if (!armed) return;
        if (pageScrollTop() > 0) {
            armed = false;
            reset(true);
            return;
        }
        var dy = e.touches[0].clientY - startY;
        if (dy <= 0) {
            if (pulling) {
                pulling = false;
                reset(true);
            }
            return;
        }
        currentPull = Math.min(dy * RESISTANCE, MAX_PULL);
        pulling = true;
        setIndicator(currentPull / THRESHOLD);
    }

    function onTouchEnd() {
        if (!armed || !pulling) {
            armed = false;
            return;
        }
        armed = false;
        if (currentPull >= THRESHOLD) {
            indicator.style.transition = 'transform 0.15s ease, opacity 0.15s ease';
            indicator.style.transform = 'translate(-50%, 20px) rotate(0deg)';
            indicator.style.opacity = '1';
            setTimeout(function () { window.location.reload(); }, 150);
        } else {
            reset(true);
        }
        pulling = false;
        currentPull = 0;
    }

    document.addEventListener('touchstart', onTouchStart, { passive: true });
    document.addEventListener('touchmove', onTouchMove, { passive: true });
    document.addEventListener('touchend', onTouchEnd, { passive: true });
    document.addEventListener('touchcancel', function () {
        if (pulling) reset(true);
        armed = false;
        pulling = false;
        currentPull = 0;
    }, { passive: true });
})();
