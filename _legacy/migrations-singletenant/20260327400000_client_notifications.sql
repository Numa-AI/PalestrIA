-- ─── Storico notifiche inviate ai clienti ───────────────────────────────
-- Traccia ogni notifica push inviata a un cliente con stato di consegna.

CREATE TABLE IF NOT EXISTS client_notifications (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    user_id     UUID REFERENCES profiles(id) ON DELETE SET NULL,
    user_name   TEXT,
    user_email  TEXT,
    type        TEXT NOT NULL,           -- 'reminder_24h', 'reminder_1h', 'slot_available', 'broadcast'
    title       TEXT NOT NULL,
    body        TEXT NOT NULL DEFAULT '',
    status      TEXT NOT NULL DEFAULT 'sent',  -- 'sent', 'failed', 'no_subscription'
    error       TEXT,                    -- dettaglio errore se fallita
    booking_date DATE,
    booking_time TEXT
);

ALTER TABLE client_notifications ENABLE ROW LEVEL SECURITY;

-- Solo admin può leggere
CREATE POLICY "client_notifications_select" ON client_notifications
    FOR SELECT TO authenticated USING (
        (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
    );

-- Indice per query filtrate per utente
CREATE INDEX IF NOT EXISTS idx_client_notifications_user ON client_notifications(user_id);
CREATE INDEX IF NOT EXISTS idx_client_notifications_type ON client_notifications(type);
