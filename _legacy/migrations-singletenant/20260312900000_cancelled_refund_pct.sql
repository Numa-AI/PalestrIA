-- Add refund percentage column to bookings
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS cancelled_refund_pct INTEGER DEFAULT NULL;

-- Recreate admin_update_booking with the new parameter
DROP FUNCTION IF EXISTS admin_update_booking(UUID, TEXT, BOOLEAN, TEXT, TIMESTAMPTZ, NUMERIC, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TIMESTAMPTZ, BOOLEAN, BOOLEAN, TIMESTAMPTZ);

CREATE OR REPLACE FUNCTION admin_update_booking(
    p_booking_id                UUID,
    p_status                    TEXT,
    p_paid                      BOOLEAN                   DEFAULT false,
    p_payment_method            TEXT                      DEFAULT NULL,
    p_paid_at                   TIMESTAMPTZ               DEFAULT NULL,
    p_credit_applied            NUMERIC                   DEFAULT 0,
    p_cancellation_requested_at TIMESTAMPTZ               DEFAULT NULL,
    p_cancelled_at              TIMESTAMPTZ               DEFAULT NULL,
    p_cancelled_payment_method  TEXT                      DEFAULT NULL,
    p_cancelled_paid_at         TIMESTAMPTZ               DEFAULT NULL,
    p_cancelled_with_bonus      BOOLEAN                   DEFAULT false,
    p_cancelled_with_penalty    BOOLEAN                   DEFAULT false,
    p_cancelled_refund_pct      INTEGER                   DEFAULT NULL,
    p_expected_updated_at       TIMESTAMPTZ               DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
    v_booking RECORD;
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'Accesso negato: richiesto ruolo admin';
    END IF;

    SELECT id, updated_at INTO v_booking
    FROM bookings WHERE id = p_booking_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'booking_not_found');
    END IF;

    IF p_expected_updated_at IS NOT NULL
       AND v_booking.updated_at <> p_expected_updated_at THEN
        RETURN jsonb_build_object(
            'success', false,
            'error',   'stale_data',
            'server_updated_at', v_booking.updated_at
        );
    END IF;

    UPDATE bookings SET
        status                    = p_status,
        paid                      = p_paid,
        payment_method            = p_payment_method,
        paid_at                   = p_paid_at,
        credit_applied            = p_credit_applied,
        cancellation_requested_at = p_cancellation_requested_at,
        cancelled_at              = p_cancelled_at,
        cancelled_payment_method  = p_cancelled_payment_method,
        cancelled_paid_at         = p_cancelled_paid_at,
        cancelled_with_bonus      = p_cancelled_with_bonus,
        cancelled_with_penalty    = p_cancelled_with_penalty,
        cancelled_refund_pct      = p_cancelled_refund_pct
    WHERE id = p_booking_id;

    RETURN jsonb_build_object('success', true, 'updated_at', now());
END;
$$;

REVOKE ALL ON FUNCTION admin_update_booking FROM public;
GRANT EXECUTE ON FUNCTION admin_update_booking TO authenticated;
