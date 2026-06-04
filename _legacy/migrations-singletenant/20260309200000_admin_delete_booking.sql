-- RPC: admin_delete_booking
-- Consente all'admin di eliminare fisicamente un booking da Supabase bypassando RLS.

CREATE OR REPLACE FUNCTION admin_delete_booking(p_booking_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    DELETE FROM bookings WHERE id = p_booking_id;
END;
$$;

-- Solo gli utenti autenticati possono chiamare questa RPC
REVOKE ALL ON FUNCTION admin_delete_booking(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin_delete_booking(uuid) TO authenticated;
