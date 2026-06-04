-- Add client association fields to schedule_overrides
-- so that group-class slot assignments persist across refresh/sync.

ALTER TABLE schedule_overrides
    ADD COLUMN IF NOT EXISTS client_name     TEXT,
    ADD COLUMN IF NOT EXISTS client_email    TEXT,
    ADD COLUMN IF NOT EXISTS client_whatsapp TEXT,
    ADD COLUMN IF NOT EXISTS booking_id      TEXT;
