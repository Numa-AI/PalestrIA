-- ─── PULIZIA TOTALE credit_history + ricalcolo balance ──────────────────────
-- Problema: voci duplicate create da vecchio codice client-side, RPC, e
-- migrazione di riconciliazione. Questo script:
--   1. Elimina TUTTE le voci negative (deduzioni) non-hidden
--   2. Rimuove le voci hidden (residui della revert migration)
--   3. Per ogni booking pagato con credito, crea UNA sola voce negativa
--   4. Ricalcola il balance dalla somma pulita

DO $$
DECLARE
    v_credit    RECORD;
    v_booking   RECORD;
    v_price     NUMERIC(10,2);
    v_correct   NUMERIC(10,2);
    v_count     INTEGER := 0;
    v_del       INTEGER;
    v_slot_prices JSONB := '{"personal-training":5,"small-group":10,"group-class":30}';
BEGIN
    FOR v_credit IN
        SELECT id, email, balance, coalesce(free_balance, 0) AS free_balance FROM credits
    LOOP
        -- 1. Elimina tutte le voci negative (duplicate e non)
        DELETE FROM credit_history
        WHERE  credit_id = v_credit.id
          AND  amount < 0;
        GET DIAGNOSTICS v_del = ROW_COUNT;

        -- 2. Elimina anche le voci hidden (residui revert migration)
        DELETE FROM credit_history
        WHERE  credit_id = v_credit.id
          AND  hidden = true;

        -- 3. Per ogni booking pagato con credito, crea UNA voce
        FOR v_booking IN
            SELECT b.id, b.slot_type, b.date, b.time, b.paid_at
            FROM   bookings b
            WHERE  lower(b.email) = v_credit.email
              AND  b.paid = true
              AND  b.payment_method IN ('credito', 'lezione-gratuita')
              AND  b.status = 'confirmed'
            ORDER  BY b.date, b.time
        LOOP
            v_price := coalesce((v_slot_prices ->> v_booking.slot_type)::numeric, 0);
            IF v_price <= 0 THEN CONTINUE; END IF;

            INSERT INTO credit_history (credit_id, amount, note, created_at)
            VALUES (
                v_credit.id,
                -v_price,
                'Pagamento lezione ' || v_booking.date || ' ' || v_booking.time,
                coalesce(v_booking.paid_at, now())
            );
        END LOOP;

        -- 4. Ricalcola balance dalla somma pulita
        SELECT coalesce(sum(amount), 0) INTO v_correct
        FROM   credit_history
        WHERE  credit_id = v_credit.id;

        v_correct := greatest(0, round(v_correct::numeric, 2));

        IF v_credit.balance <> v_correct THEN
            UPDATE credits SET balance = v_correct WHERE id = v_credit.id;
            RAISE NOTICE '% : % → % (eliminate % voci duplicate)',
                v_credit.email, v_credit.balance, v_correct, v_del;
            v_count := v_count + 1;
        END IF;
    END LOOP;

    RAISE NOTICE 'Corretti % clienti', v_count;
END;
$$;
