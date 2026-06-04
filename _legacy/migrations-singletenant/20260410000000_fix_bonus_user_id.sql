-- Fix: cancel_booking_with_refund non popolava bonuses.user_id
--
-- Problema:
--   La RPC inseriva le righe di `bonuses` usando solo (name, whatsapp, email,
--   bonus, last_reset_month), lasciando `user_id` sempre NULL. Questo rendeva
--   la tabella incoerente (non si poteva fare join affidabile con `profiles`)
--   e bloccava lookup per user_id. Il frontend faceva fallback su email/phone
--   ma, se l'email del profilo differiva dall'email storata nella booking al
--   momento del consumo, il match poteva fallire — il cliente vedeva 1/1
--   anche se aveva già consumato il bonus.
--
-- Fix:
--   1. Ricrea cancel_booking_with_refund identica all'ultima versione
--      (20260407100000) ma con `user_id` nell'INSERT su `bonuses` e con
--      COALESCE nell'ON CONFLICT per non sovrascrivere mai un user_id già
--      valorizzato.
--   2. Backfill una-tantum dei record esistenti: associa user_id a bonuses
--      dove l'email del profilo combacia con quella del bonus e user_id è
--      NULL.
--
-- Note:
--   - Nessuna modifica allo schema (la colonna user_id esiste già da
--     20260308000000_assicurazione_and_missing_tables.sql).
--   - Nessuna modifica alla RPC `get_or_reset_bonus` (è tuttora non usata
--     dal frontend, vedi commento in 20260310000000_admin_role.sql — si
--     rimanda a un fix separato se/quando verrà attivata).
--   - Il frontend (BonusStorage in js/data.js) è aggiornato in parallelo
--     per usare user_id come chiave primaria di lookup, con fallback
--     email/phone per i record legacy.

CREATE OR REPLACE FUNCTION cancel_booking_with_refund(
    p_booking_id       UUID,
    p_credit_amount    NUMERIC  DEFAULT 0,
    p_credit_note      TEXT     DEFAULT '',
    p_use_bonus        BOOLEAN  DEFAULT false,
    p_with_bonus       BOOLEAN  DEFAULT false,
    p_with_penalty     BOOLEAN  DEFAULT false,
    p_mora_debt_amount NUMERIC  DEFAULT 0,
    p_mora_debt_note   TEXT     DEFAULT ''
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
    v_booking   RECORD;
    v_credit_id UUID;
    v_now       TIMESTAMPTZ := now();
    v_entry     JSONB;
BEGIN
    -- ── Leggi il booking CON LOCK per evitare race condition ─────────────────
    SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'booking_not_found');
    END IF;

    -- ── Impedisci doppia cancellazione ───────────────────────────────────────
    IF v_booking.status = 'cancelled' THEN
        RETURN jsonb_build_object('success', false, 'error', 'already_cancelled');
    END IF;

    -- ── Autorizzazione: proprietario O admin ─────────────────────────────────
    -- Booking anonimi (user_id NULL): solo admin può cancellare
    IF v_booking.user_id IS NULL AND NOT is_admin() THEN
        RETURN jsonb_build_object('success', false, 'error', 'unauthorized');
    END IF;
    IF v_booking.user_id IS NOT NULL
       AND v_booking.user_id IS DISTINCT FROM auth.uid()
       AND NOT is_admin() THEN
        RETURN jsonb_build_object('success', false, 'error', 'unauthorized');
    END IF;

    -- ── Aggiorna stato booking ───────────────────────────────────────────────
    UPDATE bookings SET
        status                    = 'cancelled',
        cancelled_at              = v_now,
        cancelled_by              = auth.uid(),
        paid                      = false,
        payment_method            = null,
        credit_applied            = 0,
        cancelled_with_bonus      = p_with_bonus,
        cancelled_with_penalty    = p_with_penalty,
        cancelled_payment_method  = v_booking.payment_method,
        cancelled_paid_at         = v_booking.paid_at
    WHERE id = p_booking_id;

    -- ── Rimborso credito (con lock sulla riga credits) ───────────────────────
    IF p_credit_amount > 0
       AND v_booking.email IS NOT NULL
       AND trim(v_booking.email) <> '' THEN

        SELECT id INTO v_credit_id
        FROM credits
        WHERE email = lower(trim(v_booking.email))
        FOR UPDATE;

        IF NOT FOUND THEN
            INSERT INTO credits (name, whatsapp, email, balance, free_balance)
            VALUES (v_booking.name, v_booking.whatsapp, lower(trim(v_booking.email)), p_credit_amount, 0)
            RETURNING id INTO v_credit_id;
        ELSE
            UPDATE credits
            SET balance = round((balance + p_credit_amount)::numeric, 2)
            WHERE id = v_credit_id;
        END IF;

        INSERT INTO credit_history (credit_id, amount, note, created_at)
        VALUES (v_credit_id, p_credit_amount, p_credit_note, v_now);
    END IF;

    -- ── Mora debito (per booking non pagati) ─────────────────────────────────
    IF p_mora_debt_amount > 0
       AND v_booking.email IS NOT NULL
       AND trim(v_booking.email) <> '' THEN

        v_entry := jsonb_build_object(
            'date',      v_now,
            'amount',    p_mora_debt_amount,
            'note',      COALESCE(NULLIF(p_mora_debt_note, ''), 'Mora 50%'),
            'method',    '',
            'entryType', 'mora'
        );

        INSERT INTO manual_debts (name, whatsapp, email, balance, history)
        VALUES (
            v_booking.name,
            v_booking.whatsapp,
            lower(trim(v_booking.email)),
            p_mora_debt_amount,
            jsonb_build_array(v_entry)
        )
        ON CONFLICT (email) DO UPDATE
        SET balance = round((manual_debts.balance + p_mora_debt_amount)::numeric, 2),
            history = manual_debts.history || jsonb_build_array(v_entry);
    END IF;

    -- ── Consumo bonus mensile ────────────────────────────────────────────────
    -- FIX: ora popoliamo anche user_id, così la tabella `bonuses` è
    -- consistente con `profiles` e il frontend può fare lookup autoritativo
    -- per user_id anziché solo per email (che può cambiare nel tempo).
    IF p_use_bonus
       AND v_booking.email IS NOT NULL
       AND trim(v_booking.email) <> '' THEN

        INSERT INTO bonuses (user_id, name, whatsapp, email, bonus, last_reset_month)
        VALUES (
            v_booking.user_id,
            v_booking.name,
            v_booking.whatsapp,
            lower(trim(v_booking.email)),
            0,
            to_char(v_now AT TIME ZONE 'Europe/Rome', 'YYYY-MM')
        )
        ON CONFLICT (email) DO UPDATE
            SET bonus            = 0,
                last_reset_month = to_char(v_now AT TIME ZONE 'Europe/Rome', 'YYYY-MM'),
                -- Preserva user_id se già valorizzato (backfill incrementale):
                -- scrivi solo se la riga esistente ha NULL e la nuova ne ha uno valido.
                user_id          = COALESCE(bonuses.user_id, EXCLUDED.user_id);
    END IF;

    RETURN jsonb_build_object('success', true);
END;
$$;

-- ─── Backfill una-tantum: associa user_id ai record bonuses esistenti ────────
-- Sicuro: aggiorna solo righe dove user_id è NULL e l'email coincide (lower+trim)
-- con un profilo esistente. Non tocca le altre.
UPDATE bonuses b
SET user_id    = p.id,
    updated_at = now()
FROM profiles p
WHERE lower(trim(b.email)) = lower(trim(p.email))
  AND b.user_id IS NULL;
