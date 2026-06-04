-- ─── RPC: user_request_cancellation ──────────────────────────────────────────
-- Permette all'utente proprietario di richiedere l'annullamento di un booking.
-- Setta status = 'cancellation_requested' e cancellation_requested_at = now().
-- SECURITY DEFINER per bypassare RLS (utenti non hanno policy UPDATE su bookings).

CREATE OR REPLACE FUNCTION user_request_cancellation(
    p_booking_id UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
    v_booking RECORD;
BEGIN
    SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'booking_not_found');
    END IF;

    -- Solo il proprietario o admin
    IF v_booking.user_id IS DISTINCT FROM auth.uid() AND NOT is_admin() THEN
        RETURN jsonb_build_object('success', false, 'error', 'unauthorized');
    END IF;

    -- Solo booking confermati
    IF v_booking.status <> 'confirmed' THEN
        RETURN jsonb_build_object('success', false, 'error', 'not_confirmed');
    END IF;

    UPDATE bookings
    SET status = 'cancellation_requested',
        cancellation_requested_at = now()
    WHERE id = p_booking_id;

    RETURN jsonb_build_object('success', true);
END;
$$;

REVOKE ALL ON FUNCTION user_request_cancellation FROM public;
GRANT EXECUTE ON FUNCTION user_request_cancellation TO authenticated;
GRANT EXECUTE ON FUNCTION user_request_cancellation TO service_role;
