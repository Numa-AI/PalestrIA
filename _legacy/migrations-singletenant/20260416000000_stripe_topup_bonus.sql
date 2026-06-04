-- ─── Stripe top-up: applica bonus "lezione gratuita" ─────────────────────────
-- Problema:
--   La RPC stripe_topup_credit accreditava solo `balance`, ignorando il bonus
--   ricarica (Ogni Xeuro ricaricati → Yeuro di lezione gratuita) già applicato
--   dal flusso admin manuale (js/admin-payments.js). I clienti che ricaricavano
--   online via Stripe NON ricevevano il bonus.
--
-- Fix:
--   La RPC ora legge la config da `settings` (recharge_bonus_enabled/threshold/
--   amount) e, se attiva, somma `floor(amount/threshold) * bonus_amount` a
--   `free_balance` e inserisce una riga dedicata in `credit_history` con
--   method='lezione-gratuita'.
--
-- Gate debito:
--   Il bonus NON viene applicato se il debito pre-ricarica del cliente supera
--   `debt_threshold` (settings). Debito = debiti manuali + prenotazioni passate
--   non pagate (prezzi default personal-training/small-group/group-class)
--   − credito disponibile. Allineato a BookingStorage.getUnpaidPastDebt in
--   js/data.js e alla semantica usata in booking.js per bloccare le prenotazioni.
--
-- Idempotenza:
--   Il guard iniziale su stripe_session_id è invariato — se il webhook arriva
--   due volte, entrambi i rami (topup + bonus) vengono saltati insieme.
--   La riga di bonus in credit_history ha stripe_session_id=NULL perché la
--   unique index lo permette (WHERE stripe_session_id IS NOT NULL).

CREATE OR REPLACE FUNCTION stripe_topup_credit(
    p_user_id           UUID,
    p_amount            NUMERIC,
    p_stripe_session_id TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
    v_credit_id      UUID;
    v_balance        NUMERIC(10,2);
    v_free_balance   NUMERIC(10,2);
    v_email          TEXT;
    v_bonus_enabled  BOOLEAN := false;
    v_bonus_thresh   NUMERIC(10,2) := 100;
    v_bonus_amount   NUMERIC(10,2) := 5;
    v_bonus_total    NUMERIC(10,2) := 0;
    v_multiplier     INTEGER := 0;
    v_debt_thresh    NUMERIC(10,2) := 0;
    v_manual_debt    NUMERIC(10,2) := 0;
    v_booking_debt   NUMERIC(10,2) := 0;
    v_current_debt   NUMERIC(10,2) := 0;
    v_skip_bonus     BOOLEAN := false;
BEGIN
    -- Idempotency: skip if already processed
    IF EXISTS (
        SELECT 1 FROM credit_history WHERE stripe_session_id = p_stripe_session_id
    ) THEN
        RETURN jsonb_build_object('success', true, 'already_processed', true);
    END IF;

    -- Lookup user email
    SELECT email INTO v_email FROM profiles WHERE id = p_user_id;
    IF v_email IS NULL THEN
        RAISE EXCEPTION 'Utente non trovato: %', p_user_id;
    END IF;

    v_email := lower(trim(v_email));

    -- Find or create credits row
    SELECT id, balance, coalesce(free_balance, 0)
    INTO   v_credit_id, v_balance, v_free_balance
    FROM   credits
    WHERE  email = v_email
    FOR UPDATE;

    IF NOT FOUND THEN
        INSERT INTO credits (name, whatsapp, email, balance, free_balance, user_id)
        SELECT p.name, p.whatsapp, v_email, 0, 0, p.id
        FROM   profiles p WHERE p.id = p_user_id
        RETURNING id, balance, coalesce(free_balance, 0)
        INTO v_credit_id, v_balance, v_free_balance;
    END IF;

    -- Legge config bonus e soglia debito da settings
    BEGIN
        SELECT (value = 'true')           INTO v_bonus_enabled
        FROM settings WHERE key = 'recharge_bonus_enabled';
        SELECT NULLIF(value,'')::numeric  INTO v_bonus_thresh
        FROM settings WHERE key = 'recharge_bonus_threshold';
        SELECT NULLIF(value,'')::numeric  INTO v_bonus_amount
        FROM settings WHERE key = 'recharge_bonus_amount';
        SELECT NULLIF(value,'')::numeric  INTO v_debt_thresh
        FROM settings WHERE key = 'debt_threshold';
    EXCEPTION WHEN OTHERS THEN
        v_bonus_enabled := false;
    END;

    -- Calcola debito pre-ricarica se la soglia è attiva (solo se ci interessa
    -- per decidere sul bonus: evitiamo il lavoro se il bonus è già off).
    IF v_bonus_enabled AND coalesce(v_debt_thresh, 0) > 0 THEN
        -- Manual debts
        SELECT coalesce(balance, 0) INTO v_manual_debt
        FROM manual_debts WHERE lower(email) = v_email;
        v_manual_debt := coalesce(v_manual_debt, 0);

        -- Past unpaid bookings: stessa logica di get_debtors (prezzi default)
        SELECT coalesce(sum(
            coalesce(
                ('{"personal-training":5,"small-group":10,"group-class":30,"cleaning":0}'::jsonb
                    ->> slot_type)::numeric,
                0
            ) - coalesce(credit_applied, 0)
        ), 0)
        INTO v_booking_debt
        FROM bookings
        WHERE lower(email) = v_email
          AND paid = false
          AND status NOT IN ('cancelled', 'cancellation_requested')
          AND (
              date < (now() AT TIME ZONE 'Europe/Rome')::date
              OR (date = (now() AT TIME ZONE 'Europe/Rome')::date
                  AND split_part(time, ' - ', 1)::time
                      <= (now() AT TIME ZONE 'Europe/Rome')::time)
          );

        -- Debito netto (clampato a 0): manuale + bookings − credito corrente
        v_current_debt := greatest(
            round((v_manual_debt + v_booking_debt - v_balance)::numeric, 2),
            0
        );

        IF v_current_debt > v_debt_thresh THEN
            v_skip_bonus := true;
        END IF;
    END IF;

    -- Aggiorna balance con la ricarica
    v_balance := round((v_balance + p_amount)::numeric, 2);

    -- Applica bonus se attivo e gate debito non scattato.
    -- NB: `free_balance` è un "di cui" di `balance` (traccia la quota gratuita),
    -- quindi il bonus va sommato a ENTRAMBE le colonne — come fa
    -- admin_add_credit quando p_free_lesson=true.
    IF v_bonus_enabled
       AND NOT v_skip_bonus
       AND coalesce(v_bonus_thresh, 0) > 0
       AND coalesce(v_bonus_amount, 0) > 0
       AND p_amount >= v_bonus_thresh THEN
        v_multiplier  := floor(p_amount / v_bonus_thresh)::integer;
        v_bonus_total := round((v_multiplier * v_bonus_amount)::numeric, 2);
        IF v_bonus_total > 0 THEN
            v_balance      := round((v_balance      + v_bonus_total)::numeric, 2);
            v_free_balance := round((v_free_balance + v_bonus_total)::numeric, 2);
        END IF;
    END IF;

    UPDATE credits
    SET    balance      = v_balance,
           free_balance = v_free_balance
    WHERE  id = v_credit_id;

    -- History row per la ricarica (con session_id per idempotenza)
    INSERT INTO credit_history (credit_id, amount, note, method, stripe_session_id)
    VALUES (
        v_credit_id, p_amount,
        'Ricarica online Stripe €' || p_amount,
        'stripe', p_stripe_session_id
    );

    -- History row per il bonus (session_id NULL: idempotenza già garantita
    -- dal guard iniziale sulla riga principale).
    IF v_bonus_total > 0 THEN
        INSERT INTO credit_history (credit_id, amount, note, method, created_at)
        VALUES (
            v_credit_id, v_bonus_total,
            'Bonus ricarica Stripe €' || p_amount || ' (x' || v_multiplier || ')',
            'lezione-gratuita',
            now() + interval '1 millisecond'
        );
    END IF;

    RETURN jsonb_build_object(
        'success',     true,
        'new_balance', v_balance,
        'credit_id',   v_credit_id,
        'bonus',       v_bonus_total,
        'bonus_skipped_for_debt', v_skip_bonus,
        'debt',        v_current_debt
    );
END;
$$;

REVOKE ALL ON FUNCTION stripe_topup_credit FROM public;

-- ─── Seed config bonus se mancante ──────────────────────────────────────────
-- Garantisce che la feature funzioni out-of-the-box per Stripe (e per il flusso
-- admin manuale che legge gli stessi valori via RechargeBonusStorage). Non
-- sovrascrive eventuali valori già impostati dall'admin.
INSERT INTO settings (key, value) VALUES
    ('recharge_bonus_enabled',   'true'),
    ('recharge_bonus_threshold', '100'),
    ('recharge_bonus_amount',    '5')
ON CONFLICT (key) DO NOTHING;

-- ─── Backfill una-tantum: recupera bonus Stripe pregressi nel balance ────────
-- I record di "Bonus ricarica Stripe" creati prima di questa fix erano scritti
-- solo in `free_balance`, non in `balance`. Il saldo mostrato al cliente era
-- quindi sottostimato. Somma i loro importi a `balance`.
-- Idempotente: un flag in `settings` garantisce che il backfill venga eseguito
-- una sola volta, anche se la migration viene riapplicata manualmente dal SQL
-- Editor.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM settings
        WHERE key = 'stripe_bonus_balance_backfill_done' AND value = 'true'
    ) THEN
        RETURN;
    END IF;

    WITH stripe_bonuses AS (
        SELECT credit_id, SUM(amount) AS bonus_total
        FROM credit_history
        WHERE method = 'lezione-gratuita'
          AND note LIKE 'Bonus ricarica Stripe%'
        GROUP BY credit_id
    )
    UPDATE credits c
    SET balance = round((c.balance + sb.bonus_total)::numeric, 2)
    FROM stripe_bonuses sb
    WHERE c.id = sb.credit_id;

    INSERT INTO settings (key, value)
    VALUES ('stripe_bonus_balance_backfill_done', 'true')
    ON CONFLICT (key) DO UPDATE SET value = 'true', updated_at = now();
END $$;
