(function () {
    function _storageSize(key) {
        try { return (localStorage.getItem(key) || '').length; } catch (_) { return 0; }
    }

    window.adminCheckBodyLocks = function () {
        var overlays = Array.prototype.slice.call(document.querySelectorAll('[id$="Modal"], [id$="modal"], .modal-overlay, .popup-overlay'))
            .filter(function (el) {
                var s = getComputedStyle(el);
                var r = el.getBoundingClientRect();
                return s.display !== 'none' && s.visibility !== 'hidden' && Number(s.opacity || 1) !== 0 && (r.width || r.height);
            })
            .map(function (el) { return el.id || el.className || el.tagName; });
        var result = {
            bodyOverflow: document.body && document.body.style.overflow,
            htmlOverflow: document.documentElement && document.documentElement.style.overflow,
            openOverlays: overlays
        };
        console.table(result);
        return result;
    };

    window.adminHealth = async function () {
        var session = null;
        try {
            if (typeof supabaseClient !== 'undefined') {
                var res = await supabaseClient.auth.getSession();
                session = res && res.data && res.data.session;
            }
        } catch (_) {}
        var activeTab = document.querySelector('.admin-tab.active');
        var result = {
            path: location.pathname,
            online: navigator.onLine,
            visibility: document.visibilityState,
            activeTab: activeTab && activeTab.dataset.tab,
            adminAuth: sessionStorage.getItem('adminAuth') === 'true',
            hasSession: !!session,
            bookings: typeof BookingStorage !== 'undefined' && BookingStorage.getAllBookings ? BookingStorage.getAllBookings().length : null,
            users: typeof UserStorage !== 'undefined' && UserStorage.getAll ? UserStorage.getAll().length : null,
            localBookingsBytes: _storageSize('gym_bookings')
        };
        console.table(result);
        return result;
    };

    window.adminDebugLog = function () {
        localStorage.setItem('admin_debug', '1');
        console.log('[Admin] debug log abilitato');
    };

    window.adminMeasure = async function (label, fn) {
        var t0 = performance.now();
        try { return await fn(); }
        finally { console.log('[AdminMeasure]', label, Math.round(performance.now() - t0) + 'ms'); }
    };
})();
