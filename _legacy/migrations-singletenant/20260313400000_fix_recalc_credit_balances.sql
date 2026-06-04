-- ─── ONE-TIME FIX: ricalcola balance credits ────────────────────────────────
-- Calcola il balance corretto per ogni cliente come:
--   (somma credit_history non nascosti)
--   MENO (prezzo booking pagati con credito che NON hanno una voce negativa visibile)
-- Poi crea le voci credit_history mancanti per i booking pagati.

DO $$
DECLARE
    v_credit   RECORD;
    v_booking  RECORD;
    v_hist_sum NUMERIC(10,2);
    v_paid_sum NUMERIC(10,2);
    v_correct  NUMERIC(10,2);
    v_price    NUMERIC(10,2);
    v_has_entry BOOLEAN;
    v_count    INTEGER := 0;
    v_slot_prices JSONB := '{"personal-training":5,"small-group":10,"group-class":30}';
BEGIN
    FOR v_credit IN
        SELECT id, email, balance FROM credits
    LOOP
        -- 1. Somma credit_history visibili
        SELECT coalesce(sum(amount), 0) INTO v_hist_sum
        FROM   credit_history
        WHERE  credit_id = v_credit.id AND hidden = false;

        -- 2. Per ogni booking pagato con credito, verifica che esista una voce negativa visibile
        v_paid_sum := 0;
        FOR v_booking IN
            SELECT b.id, b.slot_type, b.paid_at, b.date, b.time
            FROM   bookings b
            WHERE  lower(b.email) = v_credit.email
              AND  b.paid = true
              AND  b.payment_method IN ('credito', 'lezione-gratuita')
              AND  b.status = 'confirmed'
        LOOP
            v_price := coalesce((v_slot_prices ->> v_booking.slot_type)::numeric, 0);

            -- Cerca una voce negativa non-hidden vicina al paid_at
            SELECT EXISTS(
                SELECT 1 FROM credit_history
                WHERE  credit_id = v_credit.id
                  AND  amount < 0
                  AND  hidden = false
                  AND  (
                      -- Matcha per timestamp vicino al paid_at
                      (v_booking.paid_at IS NOT NULL AND
                       created_at BETWEEN v_booking.paid_at - interval '10 seconds'
                                      AND v_booking.paid_at + interval '10 seconds')
                      OR
                      -- Oppure matcha per nota contenente la data del booking
                      (note ILIKE '%' || v_booking.date || '%')
                  )
            ) INTO v_has_entry;

            IF NOT v_has_entry THEN
                -- Crea la voce mancante
                INSERT INTO credit_history (credit_id, amount, note, created_at)
                VALUES (
                    v_credit.id,
                    -v_price,
                    'Pagamento lezione ' || v_booking.date || ' ' || v_booking.time || ' (riconciliazione)',
                    coalesce(v_booking.paid_at, now())
                );
                v_paid_sum := v_paid_sum + v_price;
            END IF;
        END LOOP;

        -- 3. Ricalcola il balance = somma di TUTTE le voci non-hidden (incluse quelle appena create)
        SELECT coalesce(sum(amount), 0) INTO v_correct
        FROM   credit_history
        WHERE  credit_id = v_credit.id AND hidden = false;

        v_correct := greatest(0, round(v_correct::numeric, 2));

        IF v_credit.balance <> v_correct THEN
            UPDATE credits SET balance = v_correct WHERE id = v_credit.id;
            RAISE NOTICE 'Fix %: % → % (mancavano % di deduzioni)',
                v_credit.email, v_credit.balance, v_correct, v_paid_sum;
            v_count := v_count + 1;
        END IF;
    END LOOP;

    RAISE NOTICE 'Corretti % record credits', v_count;
END;
$$;
