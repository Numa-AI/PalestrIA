-- ─── ONE-TIME: rimborsa credito sulle prenotazioni future già pagate con credito ─
-- Con la nuova logica il credito viene scalato solo all'inizio della lezione.
-- Questa migrazione riallinea le prenotazioni future già pagate con credito:
--   1. Rimborsa il credito al saldo del cliente (solo balance, nessun log visibile)
--   2. Rimette la prenotazione come "da pagare" (paid=false)

DO $$
DECLARE
    v_now        TIMESTAMPTZ := now();
    v_now_rome   TIMESTAMP   := (v_now AT TIME ZONE 'Europe/Rome');
    v_today      DATE        := v_now_rome::date;
    v_current_time TIME      := v_now_rome::time;
    v_booking    RECORD;
    v_price      NUMERIC(10,2);
    v_credit_id  UUID;
    v_refund     NUMERIC(10,2);
    v_count      INTEGER := 0;
    v_slot_prices JSONB := '{"personal-training":5,"small-group":10,"group-class":30}';
BEGIN
    FOR v_booking IN
        SELECT b.id, b.email, b.slot_type, b.payment_method, b.date, b.time,
               coalesce(b.credit_applied, 0) AS credit_applied, b.paid, b.paid_at
        FROM   bookings b
        WHERE  b.status = 'confirmed'
          AND  (b.paid = true OR coalesce(b.credit_applied, 0) > 0)
          AND  b.payment_method IN ('credito', 'lezione-gratuita')
          AND  (
                b.date > v_today
                OR (b.date = v_today AND split_part(b.time, ' - ', 1)::time > v_current_time)
          )
    LOOP
        v_price := round(coalesce((v_slot_prices ->> v_booking.slot_type)::numeric, 0), 2);

        -- Calcola quanto rimborsare
        IF v_booking.paid THEN
            v_refund := v_price;
        ELSE
            v_refund := v_booking.credit_applied;
        END IF;

        IF v_refund <= 0 THEN CONTINUE; END IF;

        -- Trova il record credits del cliente
        SELECT id INTO v_credit_id
        FROM   credits
        WHERE  email = lower(trim(v_booking.email));

        IF NOT FOUND THEN CONTINUE; END IF;

        -- Rimborsa il credito
        UPDATE credits
        SET    balance = round((balance + v_refund)::numeric, 2)
        WHERE  id = v_credit_id;

        -- Se era lezione-gratuita, rimborsa anche il free_balance
        IF v_booking.payment_method = 'lezione-gratuita' THEN
            UPDATE credits
            SET    free_balance = round((coalesce(free_balance, 0) + v_refund)::numeric, 2)
            WHERE  id = v_credit_id;
        END IF;

        -- Nascondi la voce originale di deduzione in credit_history
        -- Matcha per credit_id, importo negativo, e timestamp vicino al paid_at del booking
        IF v_booking.paid AND v_booking.paid_at IS NOT NULL THEN
            UPDATE credit_history
            SET    hidden = true
            WHERE  credit_id = v_credit_id
              AND  amount < 0
              AND  hidden = false
              AND  created_at BETWEEN v_booking.paid_at - interval '5 seconds'
                                 AND v_booking.paid_at + interval '5 seconds';
        END IF;

        -- Rimetti la prenotazione come "da pagare"
        UPDATE bookings
        SET    paid           = false,
               payment_method = null,
               paid_at        = null,
               credit_applied = 0
        WHERE  id = v_booking.id;

        v_count := v_count + 1;
    END LOOP;

    RAISE NOTICE 'Riallineate % prenotazioni future', v_count;
END;
$$;
