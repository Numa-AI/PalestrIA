-- ═══════════════════════════════════════════════════════════════════════════
-- Slot condiviso (group-class con 2 persone a metà prezzo)
-- ═══════════════════════════════════════════════════════════════════════════
-- Aggiunge bookings.custom_price: quando valorizzato (es. 15€ per slot
-- group-class condiviso tra 2 persone) sovrascrive il prezzo standard del
-- listino SLOT_PRICES. NULL → si usa il listino.
--
-- Tutte le RPC che calcolano un importo da slot_type + p_slot_prices sono
-- ridefinite per rispettare custom_price via:
--     coalesce(custom_price, (p_slot_prices ->> slot_type)::numeric, 0)
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE bookings ADD COLUMN IF NOT EXISTS custom_price NUMERIC(10,2);

-- ─── apply_credit_to_past_bookings (versione corrente + custom_price) ─────────
CREATE OR REPLACE FUNCTION apply_credit_to_past_bookings(
    p_email       TEXT,
    p_slot_prices JSONB DEFAULT '{"personal-training":5,"small-group":10,"group-class":30}'
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
    v_email         TEXT        := lower(trim(p_email));
    v_now           TIMESTAMPTZ := now();
    v_now_rome      TIMESTAMP   := (v_now AT TIME ZONE 'Europe/Rome');
    v_today         DATE        := v_now_rome::date;
    v_current_time  TIME        := v_now_rome::time;
    v_credit_id     UUID;
    v_balance       NUMERIC(10,2);
    v_free_balance  NUMERIC(10,2);
    v_debt_balance  NUMERIC(10,2) := 0;
    v_net_credit    NUMERIC(10,2);
    v_booking       RECORD;
    v_price         NUMERIC(10,2);
    v_remain        NUMERIC(10,2);
    v_method        TEXT;
    v_free_used     NUMERIC(10,2);
    v_count         INTEGER       := 0;
    v_total_applied NUMERIC(10,2) := 0;
BEGIN
    SELECT id, balance, coalesce(free_balance, 0)
    INTO   v_credit_id, v_balance, v_free_balance
    FROM   credits
    WHERE  lower(trim(email)) = v_email
    FOR UPDATE;

    IF NOT FOUND OR v_balance <= 0 THEN
        RETURN jsonb_build_object('success', true, 'bookings_paid', 0, 'total_applied', 0);
    END IF;

    SELECT coalesce(balance, 0)
    INTO   v_debt_balance
    FROM   manual_debts
    WHERE  lower(email) = v_email;
    IF NOT FOUND THEN v_debt_balance := 0; END IF;

    v_net_credit := round(greatest(0, v_balance - v_debt_balance)::numeric, 2);

    IF v_net_credit <= 0 THEN
        RETURN jsonb_build_object('success', true, 'bookings_paid', 0, 'total_applied', 0);
    END IF;

    FOR v_booking IN
        SELECT id, slot_type, coalesce(credit_applied, 0) AS credit_applied,
               custom_price, date, time
        FROM   bookings
        WHERE  lower(email) = v_email
          AND  paid = false
          AND  status = 'confirmed'
          AND  (
                date < v_today
                OR (date = v_today AND split_part(time, ' - ', 1)::time <= v_current_time)
          )
        ORDER  BY date ASC, time ASC
        FOR UPDATE
    LOOP
        v_price  := round(coalesce(v_booking.custom_price, (p_slot_prices ->> v_booking.slot_type)::numeric, 0), 2);
        v_remain := v_price - v_booking.credit_applied;

        IF v_remain <= 0 THEN CONTINUE; END IF;

        IF v_net_credit >= v_remain THEN
            v_free_used    := least(v_free_balance, v_remain);
            v_method       := CASE WHEN v_free_balance >= v_remain THEN 'lezione-gratuita' ELSE 'credito' END;
            v_free_balance := round((v_free_balance - v_free_used)::numeric, 2);
            v_balance      := round((v_balance - v_remain)::numeric, 2);
            v_net_credit   := round((v_net_credit - v_remain)::numeric, 2);
            v_total_applied := v_total_applied + v_remain;
            v_count        := v_count + 1;

            UPDATE bookings
            SET    paid           = true,
                   payment_method = v_method,
                   paid_at        = v_now,
                   credit_applied = 0
            WHERE  id = v_booking.id;

        ELSIF v_net_credit > 0 AND v_booking.credit_applied = 0 THEN
            v_free_used    := least(v_free_balance, v_net_credit);
            v_free_balance := round((v_free_balance - v_free_used)::numeric, 2);
            v_total_applied := v_total_applied + v_net_credit;
            UPDATE bookings SET credit_applied = v_net_credit WHERE id = v_booking.id;
            v_balance    := round((v_balance - v_net_credit)::numeric, 2);
            v_net_credit := 0;
        END IF;

        EXIT WHEN v_net_credit <= 0;
    END LOOP;

    IF v_total_applied > 0 THEN
        UPDATE credits
        SET    balance      = v_balance,
               free_balance = v_free_balance
        WHERE  id = v_credit_id;

        INSERT INTO credit_history (credit_id, amount, note, created_at)
        VALUES (
            v_credit_id,
            -v_total_applied,
            CASE WHEN v_count = 1
                THEN 'Pagamento automatico lezione con credito'
                ELSE 'Pagamento automatico ' || v_count || ' lezioni con credito'
            END,
            v_now
        );
    END IF;

    RETURN jsonb_build_object(
        'success',        true,
        'bookings_paid',  v_count,
        'total_applied',  v_total_applied,
        'new_balance',    v_balance
    );
END;
$$;

REVOKE ALL ON FUNCTION apply_credit_to_past_bookings FROM public;
GRANT EXECUTE ON FUNCTION apply_credit_to_past_bookings TO anon, authenticated, service_role;


-- ─── apply_credit_on_booking (+ custom_price) ────────────────────────────────
CREATE OR REPLACE FUNCTION apply_credit_on_booking(
    p_booking_id  UUID,
    p_email       TEXT,
    p_slot_prices JSONB DEFAULT '{"personal-training":5,"small-group":10,"group-class":30}'
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
    v_email         TEXT        := lower(trim(p_email));
    v_now           TIMESTAMPTZ := now();
    v_booking       RECORD;
    v_credit_id     UUID;
    v_balance       NUMERIC(10,2);
    v_free_balance  NUMERIC(10,2);
    v_debt_balance  NUMERIC(10,2) := 0;
    v_net_credit    NUMERIC(10,2);
    v_price         NUMERIC(10,2);
    v_method        TEXT;
    v_free_used     NUMERIC(10,2);
    v_other         RECORD;
    v_other_price   NUMERIC(10,2);
    v_other_remain  NUMERIC(10,2);
    v_other_free    NUMERIC(10,2);
    v_other_method  TEXT;
    v_total_applied NUMERIC(10,2) := 0;
    v_count         INTEGER       := 0;
BEGIN
    SELECT id, slot_type, paid, custom_price, lower(email) AS v_email_bk
    INTO   v_booking
    FROM   bookings
    WHERE  id = p_booking_id
    FOR UPDATE;

    IF NOT FOUND OR v_booking.paid THEN
        RETURN jsonb_build_object('success', true, 'paid', false, 'credit_applied', 0, 'new_balance', 0);
    END IF;

    SELECT id, balance, coalesce(free_balance, 0)
    INTO   v_credit_id, v_balance, v_free_balance
    FROM   credits
    WHERE  email = v_email
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', true, 'paid', false, 'credit_applied', 0, 'new_balance', 0);
    END IF;

    SELECT coalesce(balance, 0)
    INTO   v_debt_balance
    FROM   manual_debts
    WHERE  lower(email) = v_email;

    v_net_credit := round(greatest(0, v_balance - v_debt_balance)::numeric, 2);
    v_price      := round(coalesce(v_booking.custom_price, (p_slot_prices ->> v_booking.slot_type)::numeric, 0), 2);

    IF v_net_credit <= 0 THEN
        RETURN jsonb_build_object('success', true, 'paid', false, 'credit_applied', 0, 'new_balance', v_balance);
    END IF;

    IF v_net_credit >= v_price THEN
        v_method       := CASE WHEN v_free_balance >= v_price THEN 'lezione-gratuita' ELSE 'credito' END;
        v_free_used    := least(v_free_balance, v_price);
        v_free_balance := round((v_free_balance - v_free_used)::numeric, 2);
        v_balance      := round((v_balance - v_price)::numeric, 2);

        UPDATE bookings
        SET    paid           = true,
               payment_method = v_method,
               paid_at        = v_now,
               credit_applied = 0
        WHERE  id = p_booking_id;

        INSERT INTO credit_history (credit_id, amount, note, created_at)
        VALUES (
            v_credit_id,
            -v_price,
            'Lezione ' || v_booking.slot_type || ' — pagata con ' ||
                CASE v_method WHEN 'lezione-gratuita' THEN 'lezione gratuita' ELSE 'credito' END,
            v_now
        );

        IF v_balance > 0 THEN
            FOR v_other IN
                SELECT id, slot_type, coalesce(credit_applied, 0) AS credit_applied, custom_price
                FROM   bookings
                WHERE  lower(email) = v_email
                  AND  paid = false
                  AND  id <> p_booking_id
                  AND  status NOT IN ('cancelled', 'cancellation_requested')
                ORDER  BY date ASC, time ASC
                FOR UPDATE
            LOOP
                v_other_price  := round(coalesce(v_other.custom_price, (p_slot_prices ->> v_other.slot_type)::numeric, 0), 2);
                v_other_remain := v_other_price - v_other.credit_applied;

                IF v_balance >= v_other_remain THEN
                    v_other_free   := least(v_free_balance, v_other_remain);
                    v_other_method := CASE WHEN v_free_balance >= v_other_remain THEN 'lezione-gratuita' ELSE 'credito' END;
                    v_free_balance := round((v_free_balance - v_other_free)::numeric, 2);
                    v_balance      := round((v_balance - v_other_remain)::numeric, 2);
                    v_total_applied := v_total_applied + v_other_remain;
                    v_count        := v_count + 1;
                    UPDATE bookings
                    SET    paid = true, payment_method = v_other_method,
                           paid_at = v_now, credit_applied = 0
                    WHERE  id = v_other.id;

                ELSIF v_balance > 0 AND v_other.credit_applied = 0 THEN
                    v_other_free   := least(v_free_balance, v_balance);
                    v_free_balance := round((v_free_balance - v_other_free)::numeric, 2);
                    v_total_applied := v_total_applied + v_balance;
                    UPDATE bookings SET credit_applied = v_balance WHERE id = v_other.id;
                    v_balance := 0;
                END IF;

                EXIT WHEN v_balance <= 0;
            END LOOP;

            IF v_count > 0 THEN
                INSERT INTO credit_history (credit_id, amount, note, created_at)
                VALUES (
                    v_credit_id,
                    -v_total_applied,
                    'Auto-pagamento ' || v_count || ' lezione' || CASE WHEN v_count > 1 THEN 'i' ELSE '' END || ' con credito',
                    v_now + interval '1 millisecond'
                );
            END IF;
        END IF;

        UPDATE credits
        SET    balance      = v_balance,
               free_balance = v_free_balance
        WHERE  id = v_credit_id;

        RETURN jsonb_build_object('success', true, 'paid', true, 'credit_applied', 0, 'new_balance', v_balance);

    ELSE
        v_free_used    := least(v_free_balance, v_net_credit);
        v_free_balance := round((v_free_balance - v_free_used)::numeric, 2);
        v_balance      := round((v_balance - v_net_credit)::numeric, 2);

        UPDATE bookings
        SET    credit_applied = v_net_credit
        WHERE  id = p_booking_id;

        INSERT INTO credit_history (credit_id, amount, note, created_at)
        VALUES (
            v_credit_id,
            -v_net_credit,
            'Credito parziale lezione ' || v_booking.slot_type,
            v_now
        );

        UPDATE credits
        SET    balance      = v_balance,
               free_balance = v_free_balance
        WHERE  id = v_credit_id;

        RETURN jsonb_build_object('success', true, 'paid', false, 'credit_applied', v_net_credit, 'new_balance', v_balance);
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION apply_credit_on_booking FROM public;
GRANT EXECUTE ON FUNCTION apply_credit_on_booking TO anon, authenticated, service_role;


-- ─── get_debtors (+ custom_price) ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_debtors(
    p_slot_prices jsonb DEFAULT '{"personal-training":5,"small-group":10,"group-class":30,"cleaning":0}'
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
SET timezone = 'Europe/Rome' AS $$
DECLARE
    v_result jsonb;
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'Accesso negato: richiesto ruolo admin';
    END IF;

    WITH
    unpaid AS (
        SELECT
            b.id,
            b.date::text                          AS date,
            b.time,
            b.slot_type                           AS "slotType",
            b.name,
            b.email,
            b.whatsapp,
            b.status,
            b.paid,
            b.notes,
            b.payment_method                      AS "paymentMethod",
            b.paid_at                             AS "paidAt",
            coalesce(b.credit_applied, 0)         AS "creditApplied",
            coalesce(b.custom_price, (p_slot_prices ->> b.slot_type)::numeric, 0) AS price,
            lower(b.email)                        AS norm_email,
            normalize_phone(b.whatsapp)           AS norm_phone
        FROM bookings b
        WHERE b.paid = false
          AND b.status <> 'cancelled'
          AND (
              b.date < current_date
              OR (
                  b.date = current_date
                  AND (b.date + (split_part(b.time, ' - ', 1) || ':00')::time)
                      <= now()
              )
          )
    ),
    phone_groups AS (
        SELECT norm_phone, min(norm_email) AS canon_email
        FROM unpaid
        WHERE norm_phone <> ''
        GROUP BY norm_phone
    ),
    email_groups AS (
        SELECT u.norm_email,
            least(
                u.norm_email,
                coalesce(min(pg.canon_email), u.norm_email)
            ) AS canon_email
        FROM unpaid u
        LEFT JOIN phone_groups pg ON u.norm_phone = pg.norm_phone AND u.norm_phone <> ''
        GROUP BY u.norm_email
    ),
    resolved AS (
        SELECT eg.norm_email,
            least(
                eg.canon_email,
                coalesce(min(eg2.canon_email), eg.canon_email)
            ) AS ckey
        FROM email_groups eg
        LEFT JOIN phone_groups pg ON pg.canon_email = eg.norm_email
        LEFT JOIN email_groups eg2 ON eg2.norm_email = (
            SELECT min(u2.norm_email)
            FROM unpaid u2
            WHERE u2.norm_phone = pg.norm_phone AND u2.norm_phone <> ''
        )
        GROUP BY eg.norm_email, eg.canon_email
    ),
    keyed AS (
        SELECT u.*, coalesce(r.ckey, u.norm_email) AS ckey
        FROM unpaid u
        LEFT JOIN resolved r ON u.norm_email = r.norm_email
    ),
    grouped AS (
        SELECT
            ckey,
            (array_agg(name ORDER BY date ASC, time ASC))[1]      AS name,
            (array_agg(whatsapp ORDER BY date ASC, time ASC))[1]  AS whatsapp,
            (array_agg(email ORDER BY date ASC, time ASC))[1]     AS email,
            sum(price)                                             AS booking_debt,
            jsonb_agg(
                jsonb_build_object(
                    'id',            id,
                    'date',          date,
                    'time',          time,
                    'slotType',      "slotType",
                    'name',          name,
                    'email',         email,
                    'whatsapp',      whatsapp,
                    'status',        status,
                    'paid',          paid,
                    'notes',         notes,
                    'paymentMethod', "paymentMethod",
                    'paidAt',        "paidAt",
                    'creditApplied', "creditApplied",
                    'price',         price
                )
                ORDER BY date DESC, time DESC
            ) AS "unpaidBookings"
        FROM keyed
        GROUP BY ckey
    ),
    manual_only AS (
        SELECT
            lower(md.email)              AS ckey,
            md.name,
            coalesce(md.whatsapp, '')    AS whatsapp,
            md.email,
            0::numeric                   AS booking_debt,
            '[]'::jsonb                  AS "unpaidBookings",
            md.balance                   AS manual_debt,
            md.history                   AS manual_debt_history
        FROM manual_debts md
        WHERE md.balance > 0
          AND NOT EXISTS (
              SELECT 1 FROM grouped g WHERE g.ckey = lower(md.email)
          )
    ),
    with_debts AS (
        SELECT
            g.*,
            coalesce(md.balance, 0)         AS manual_debt,
            coalesce(md.history, '[]'::jsonb) AS manual_debt_history
        FROM grouped g
        LEFT JOIN manual_debts md ON lower(md.email) = g.ckey
        UNION ALL
        SELECT * FROM manual_only
    ),
    with_credits AS (
        SELECT
            wd.*,
            round(
                (wd.booking_debt + wd.manual_debt - coalesce(cr.balance, 0))::numeric,
                2
            ) AS total_amount
        FROM with_debts wd
        LEFT JOIN credits cr ON lower(cr.email) = wd.ckey
    )
    SELECT coalesce(
        jsonb_agg(
            jsonb_build_object(
                'name',               name,
                'whatsapp',           whatsapp,
                'email',              email,
                'unpaidBookings',     "unpaidBookings",
                'manualDebt',         manual_debt,
                'manualDebtHistory',  manual_debt_history,
                'totalAmount',        total_amount
            )
            ORDER BY total_amount DESC
        ),
        '[]'::jsonb
    )
    INTO v_result
    FROM with_credits
    WHERE total_amount > 0;

    RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION get_debtors(jsonb) FROM public;
GRANT EXECUTE ON FUNCTION get_debtors(jsonb) TO authenticated;


-- ─── admin_pay_bookings (+ custom_price) ─────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_pay_bookings(
    p_booking_sb_ids     UUID[],
    p_email              TEXT,
    p_whatsapp           TEXT     DEFAULT NULL,
    p_name               TEXT     DEFAULT '',
    p_payment_method     TEXT     DEFAULT 'contanti',
    p_amount_paid        NUMERIC  DEFAULT 0,
    p_manual_debt_offset NUMERIC  DEFAULT 0,
    p_slot_prices        JSONB    DEFAULT '{"personal-training":5,"small-group":10,"group-class":30}'
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
    v_email         TEXT        := lower(trim(p_email));
    v_now           TIMESTAMPTZ := now();
    v_credit_id     UUID;
    v_balance       NUMERIC(10,2);
    v_free_balance  NUMERIC(10,2);
    v_debt_id       UUID;
    v_debt_balance  NUMERIC(10,2);
    v_due_total     NUMERIC(10,2) := 0;
    v_credit_delta  NUMERIC(10,2) := 0;
    v_booked_count  INTEGER       := 0;
    v_price         NUMERIC(10,2);
    v_method_label  TEXT;
    v_sb_id         UUID;
    v_row           RECORD;
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'Accesso negato: richiesto ruolo admin';
    END IF;

    v_method_label := CASE p_payment_method
        WHEN 'contanti' THEN 'Contanti'
        WHEN 'carta'    THEN 'Carta'
        WHEN 'iban'     THEN 'Bonifico'
        ELSE p_payment_method
    END;

    FOREACH v_sb_id IN ARRAY p_booking_sb_ids
    LOOP
        SELECT id, slot_type, coalesce(credit_applied, 0) AS credit_applied, custom_price
        INTO   v_row
        FROM   bookings
        WHERE  id = v_sb_id
        FOR UPDATE;

        IF FOUND THEN
            v_price     := round(coalesce(v_row.custom_price, (p_slot_prices ->> v_row.slot_type)::numeric, 0), 2);
            v_due_total := round((v_due_total + v_price - v_row.credit_applied)::numeric, 2);

            UPDATE bookings
            SET    paid           = true,
                   payment_method = p_payment_method,
                   paid_at        = v_now,
                   credit_applied = 0
            WHERE  id = v_sb_id;

            v_booked_count := v_booked_count + 1;
        END IF;
    END LOOP;

    IF p_manual_debt_offset > 0 THEN
        SELECT id, balance
        INTO   v_debt_id, v_debt_balance
        FROM   manual_debts
        WHERE  lower(email) = v_email
        FOR UPDATE;

        IF FOUND THEN
            UPDATE manual_debts
            SET    balance = round((balance - p_manual_debt_offset)::numeric, 2),
                   history = history || jsonb_build_array(jsonb_build_object(
                       'date',   v_now,
                       'amount', -p_manual_debt_offset,
                       'note',   'Saldo debito manuale',
                       'method', p_payment_method
                   ))
            WHERE  id = v_debt_id;
        END IF;
    END IF;

    IF p_payment_method <> 'lezione-gratuita' AND p_amount_paid > 0 THEN

        v_credit_delta := round((p_amount_paid - v_due_total - p_manual_debt_offset)::numeric, 2);

        SELECT id, balance, coalesce(free_balance, 0)
        INTO   v_credit_id, v_balance, v_free_balance
        FROM   credits
        WHERE  email = v_email
        FOR UPDATE;

        IF NOT FOUND THEN
            INSERT INTO credits (name, whatsapp, email, balance, free_balance)
            VALUES (p_name, p_whatsapp, v_email, 0, 0)
            RETURNING id, balance, coalesce(free_balance, 0)
            INTO v_credit_id, v_balance, v_free_balance;
        END IF;

        IF v_credit_delta > 0 THEN
            v_balance := round((v_balance + v_credit_delta)::numeric, 2);

            INSERT INTO credit_history (credit_id, amount, display_amount, note, created_at, method)
            VALUES (v_credit_id, v_credit_delta, p_amount_paid,
                    'Pagamento in acconto di €' || p_amount_paid, v_now, p_payment_method);

            UPDATE credits
            SET    balance      = v_balance,
                   free_balance = v_free_balance
            WHERE  id = v_credit_id;
        ELSE
            INSERT INTO credit_history (credit_id, amount, display_amount, note, created_at, method)
            VALUES (v_credit_id, 0, p_amount_paid, v_method_label || ' ricevuto', v_now, p_payment_method);
        END IF;

    END IF;

    RETURN jsonb_build_object(
        'success',       true,
        'new_balance',   coalesce(v_balance, 0),
        'bookings_paid', v_booked_count,
        'credit_delta',  v_credit_delta
    );
END;
$$;


-- ─── admin_delete_booking_with_refund (+ custom_price) ───────────────────────
CREATE OR REPLACE FUNCTION admin_delete_booking_with_refund(
    p_booking_id  UUID,
    p_slot_prices JSONB DEFAULT '{"personal-training":5,"small-group":10,"group-class":30}'
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
    v_booking        RECORD;
    v_credit_id      UUID;
    v_refund_amount  NUMERIC(10,2) := 0;
    v_now            TIMESTAMPTZ := now();
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'Accesso negato: richiesto ruolo admin';
    END IF;

    SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'booking_not_found');
    END IF;

    IF v_booking.paid THEN
        v_refund_amount := round(coalesce(v_booking.custom_price, (p_slot_prices ->> v_booking.slot_type)::numeric, 0), 2);
    END IF;

    IF v_refund_amount > 0
       AND v_booking.email IS NOT NULL
       AND trim(v_booking.email) <> '' THEN

        SELECT id INTO v_credit_id
        FROM   credits
        WHERE  email = lower(trim(v_booking.email))
        FOR UPDATE;

        IF NOT FOUND THEN
            INSERT INTO credits (name, whatsapp, email, balance, free_balance)
            VALUES (v_booking.name, v_booking.whatsapp, lower(trim(v_booking.email)), v_refund_amount, 0)
            RETURNING id INTO v_credit_id;
        ELSE
            UPDATE credits
            SET    balance = round((balance + v_refund_amount)::numeric, 2)
            WHERE  id = v_credit_id;
        END IF;

        INSERT INTO credit_history (credit_id, amount, note, created_at)
        VALUES (v_credit_id, v_refund_amount,
                'Rimborso lezione ' || v_booking.date::text,
                v_now);
    END IF;

    DELETE FROM bookings WHERE id = p_booking_id;

    RETURN jsonb_build_object('success', true, 'credit_refunded', v_refund_amount);
END;
$$;

REVOKE ALL ON FUNCTION admin_delete_booking_with_refund FROM public;
GRANT EXECUTE ON FUNCTION admin_delete_booking_with_refund TO authenticated;


-- ─── fulfill_pending_cancellation (+ custom_price) ───────────────────────────
CREATE OR REPLACE FUNCTION fulfill_pending_cancellation(
    p_date        TEXT,
    p_time        TEXT,
    p_slot_prices JSONB DEFAULT '{"personal-training":5,"small-group":10,"group-class":30}'
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
    v_booking        RECORD;
    v_credit_id      UUID;
    v_refund_amount  NUMERIC(10,2) := 0;
    v_now            TIMESTAMPTZ := now();
BEGIN
    SELECT * INTO v_booking
    FROM   bookings
    WHERE  date::text = p_date
      AND  time       = p_time
      AND  (status = 'cancellation_requested'
            OR (status = 'confirmed' AND cancellation_requested_at IS NOT NULL))
    ORDER  BY cancellation_requested_at ASC NULLS LAST
    LIMIT  1
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', true, 'found', false);
    END IF;

    IF v_booking.paid OR coalesce(v_booking.credit_applied, 0) > 0 THEN
        v_refund_amount := round(coalesce(v_booking.custom_price, (p_slot_prices ->> v_booking.slot_type)::numeric, 0), 2);
    END IF;

    UPDATE bookings SET
        status                   = 'cancelled',
        cancelled_at             = v_now,
        cancelled_payment_method = v_booking.payment_method,
        cancelled_paid_at        = v_booking.paid_at,
        paid                     = false,
        payment_method           = null,
        paid_at                  = null,
        credit_applied           = 0
    WHERE id = v_booking.id;

    IF v_refund_amount > 0
       AND v_booking.email IS NOT NULL
       AND trim(v_booking.email) <> '' THEN

        SELECT id INTO v_credit_id
        FROM   credits
        WHERE  email = lower(trim(v_booking.email))
        FOR UPDATE;

        IF NOT FOUND THEN
            INSERT INTO credits (name, whatsapp, email, balance, free_balance)
            VALUES (v_booking.name, v_booking.whatsapp, lower(trim(v_booking.email)), v_refund_amount, 0)
            RETURNING id INTO v_credit_id;
        ELSE
            UPDATE credits
            SET    balance = round((balance + v_refund_amount)::numeric, 2)
            WHERE  id = v_credit_id;
        END IF;

        INSERT INTO credit_history (credit_id, amount, note, created_at)
        VALUES (v_credit_id, v_refund_amount,
                'Rimborso lezione ' || p_date || ' (annullamento soddisfatto)',
                v_now);
    END IF;

    RETURN jsonb_build_object(
        'success',         true,
        'found',           true,
        'booking_id',      v_booking.id,
        'credit_refunded', v_refund_amount
    );
END;
$$;

REVOKE ALL ON FUNCTION fulfill_pending_cancellation FROM public;
GRANT EXECUTE ON FUNCTION fulfill_pending_cancellation TO anon, authenticated, service_role;


-- ─── admin_change_payment_method (+ custom_price) ────────────────────────────
-- Stessa logica della 20260311300000, ma il prezzo ora rispetta custom_price.
CREATE OR REPLACE FUNCTION admin_change_payment_method(
    p_booking_id   UUID,
    p_new_paid     BOOLEAN,
    p_new_method   TEXT,
    p_new_paid_at  TIMESTAMPTZ DEFAULT NULL,
    p_slot_prices  JSONB DEFAULT '{"personal-training":5,"small-group":10,"group-class":30}'
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
    v_booking       RECORD;
    v_now           TIMESTAMPTZ   := now();
    v_credit_id     UUID;
    v_balance       NUMERIC(10,2);
    v_free_balance  NUMERIC(10,2);
    v_price         NUMERIC(10,2);
    v_method_label  TEXT;
    v_debt_id       UUID;
    v_debt_balance  NUMERIC(10,2);
    v_to_offset     NUMERIC(10,2);
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'Accesso negato: richiesto ruolo admin';
    END IF;

    SELECT id,
           paid              AS old_paid,
           payment_method    AS old_method,
           slot_type,
           custom_price,
           lower(email)      AS v_email,
           whatsapp,
           name,
           date,
           time
    INTO   v_booking
    FROM   bookings
    WHERE  id = p_booking_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'booking_not_found');
    END IF;

    v_price := round(coalesce(v_booking.custom_price, (p_slot_prices ->> v_booking.slot_type)::numeric, 0), 2);

    v_method_label := CASE p_new_method
        WHEN 'contanti' THEN 'Contanti'
        WHEN 'carta'    THEN 'Carta'
        WHEN 'iban'     THEN 'Bonifico'
        ELSE p_new_method
    END;

    SELECT id, balance, coalesce(free_balance, 0)
    INTO   v_credit_id, v_balance, v_free_balance
    FROM   credits
    WHERE  email = v_booking.v_email
    FOR UPDATE;

    IF v_booking.old_paid AND v_booking.old_method = 'credito' AND NOT p_new_paid THEN
        IF v_credit_id IS NULL THEN
            INSERT INTO credits (name, whatsapp, email, balance, free_balance)
            VALUES (v_booking.name, v_booking.whatsapp, v_booking.v_email, 0, 0)
            RETURNING id, balance, coalesce(free_balance, 0)
            INTO v_credit_id, v_balance, v_free_balance;
        END IF;

        v_balance := round((v_balance + v_price)::numeric, 2);

        UPDATE bookings
        SET    paid = false, payment_method = null, paid_at = null, credit_applied = 0
        WHERE  id = p_booking_id;

        INSERT INTO credit_history (credit_id, amount, note, created_at)
        VALUES (v_credit_id, v_price,
                'Rimborso modifica pagamento ' || v_booking.date || ' ' || v_booking.time, v_now);

        SELECT id, balance INTO v_debt_id, v_debt_balance
        FROM   manual_debts
        WHERE  lower(email) = v_booking.v_email
        FOR UPDATE;

        IF FOUND AND v_debt_balance > 0 AND v_balance > 0 THEN
            v_to_offset := round(least(v_debt_balance, v_balance)::numeric, 2);
            UPDATE manual_debts
            SET    balance = round((balance - v_to_offset)::numeric, 2),
                   history = history || jsonb_build_array(jsonb_build_object(
                       'date',   v_now,
                       'amount', -v_to_offset,
                       'note',   'Compensato con credito',
                       'method', ''
                   ))
            WHERE  id = v_debt_id;
            v_balance := round((v_balance - v_to_offset)::numeric, 2);
            INSERT INTO credit_history (credit_id, amount, note, created_at)
            VALUES (v_credit_id, -v_to_offset, 'Applicato a debito manuale',
                    v_now + interval '1 millisecond');
        END IF;

    ELSIF NOT v_booking.old_paid AND p_new_paid AND p_new_method = 'credito' THEN
        IF v_credit_id IS NULL OR v_balance < v_price THEN
            RETURN jsonb_build_object(
                'success', false,
                'error',   'insufficient_credit',
                'balance', coalesce(v_balance, 0)
            );
        END IF;

        v_balance := round((v_balance - v_price)::numeric, 2);

        UPDATE bookings
        SET    paid = true, payment_method = 'credito',
               paid_at = coalesce(p_new_paid_at, v_now)
        WHERE  id = p_booking_id;

        INSERT INTO credit_history (credit_id, amount, note, created_at)
        VALUES (v_credit_id, -v_price,
                'Pagamento lezione ' || v_booking.date || ' ' || v_booking.time || ' con credito', v_now);

    ELSIF v_booking.old_paid AND v_booking.old_method = 'credito'
          AND p_new_paid AND p_new_method <> 'credito' THEN
        IF v_credit_id IS NULL THEN
            INSERT INTO credits (name, whatsapp, email, balance, free_balance)
            VALUES (v_booking.name, v_booking.whatsapp, v_booking.v_email, 0, 0)
            RETURNING id, balance, coalesce(free_balance, 0)
            INTO v_credit_id, v_balance, v_free_balance;
        END IF;

        v_balance := round((v_balance + v_price)::numeric, 2);

        UPDATE bookings
        SET    payment_method = p_new_method,
               paid_at = coalesce(p_new_paid_at, v_now)
        WHERE  id = p_booking_id;

        INSERT INTO credit_history (credit_id, amount, note, created_at)
        VALUES (v_credit_id, v_price,
                'Cambio metodo da credito — lezione ' || v_booking.date || ' ' || v_booking.time, v_now);

        SELECT id, balance INTO v_debt_id, v_debt_balance
        FROM   manual_debts
        WHERE  lower(email) = v_booking.v_email
        FOR UPDATE;

        IF FOUND AND v_debt_balance > 0 AND v_balance > 0 THEN
            v_to_offset := round(least(v_debt_balance, v_balance)::numeric, 2);
            UPDATE manual_debts
            SET    balance = round((balance - v_to_offset)::numeric, 2),
                   history = history || jsonb_build_array(jsonb_build_object(
                       'date',   v_now,
                       'amount', -v_to_offset,
                       'note',   'Compensato con credito',
                       'method', ''
                   ))
            WHERE  id = v_debt_id;
            v_balance := round((v_balance - v_to_offset)::numeric, 2);
            INSERT INTO credit_history (credit_id, amount, note, created_at)
            VALUES (v_credit_id, -v_to_offset, 'Applicato a debito manuale',
                    v_now + interval '1 millisecond');
        END IF;

        IF p_new_method NOT IN ('lezione-gratuita', 'credito') THEN
            INSERT INTO credit_history (credit_id, amount, display_amount, booking_ref, note, created_at)
            VALUES (v_credit_id, 0, v_price, p_booking_id, v_method_label || ' ricevuto',
                    v_now + interval '2 milliseconds');
        END IF;

    ELSIF v_booking.old_paid
          AND coalesce(v_booking.old_method, '') NOT IN ('credito', 'lezione-gratuita')
          AND p_new_paid AND p_new_method = 'credito' THEN
        IF v_credit_id IS NULL OR v_balance < v_price THEN
            RETURN jsonb_build_object(
                'success', false,
                'error',   'insufficient_credit',
                'balance', coalesce(v_balance, 0)
            );
        END IF;

        IF v_credit_id IS NOT NULL THEN
            UPDATE credit_history
            SET    hidden = true
            WHERE  credit_id = v_credit_id
              AND  booking_ref = p_booking_id
              AND  amount = 0;
        END IF;

        v_balance := round((v_balance - v_price)::numeric, 2);

        UPDATE bookings
        SET    payment_method = 'credito',
               paid_at = coalesce(p_new_paid_at, v_now)
        WHERE  id = p_booking_id;

        INSERT INTO credit_history (credit_id, amount, note, created_at)
        VALUES (v_credit_id, -v_price,
                'Cambio metodo a credito — lezione ' || v_booking.date || ' ' || v_booking.time, v_now);

    ELSIF v_booking.old_paid AND v_booking.old_method = 'lezione-gratuita'
          AND p_new_paid AND p_new_method = 'credito' THEN
        IF v_credit_id IS NULL OR v_balance < v_price THEN
            RETURN jsonb_build_object(
                'success', false,
                'error',   'insufficient_credit',
                'balance', coalesce(v_balance, 0)
            );
        END IF;

        v_balance := round((v_balance - v_price)::numeric, 2);

        UPDATE bookings
        SET    payment_method = 'credito',
               paid_at = coalesce(p_new_paid_at, v_now)
        WHERE  id = p_booking_id;

        INSERT INTO credit_history (credit_id, amount, note, created_at)
        VALUES (v_credit_id, -v_price,
                'Cambio metodo a credito — lezione ' || v_booking.date || ' ' || v_booking.time, v_now);

    ELSIF NOT v_booking.old_paid AND p_new_paid
          AND p_new_method NOT IN ('credito', 'lezione-gratuita') THEN
        UPDATE bookings
        SET    paid = true, payment_method = p_new_method,
               paid_at = coalesce(p_new_paid_at, v_now)
        WHERE  id = p_booking_id;

        IF v_credit_id IS NULL THEN
            INSERT INTO credits (name, whatsapp, email, balance, free_balance)
            VALUES (v_booking.name, v_booking.whatsapp, v_booking.v_email, 0, 0)
            RETURNING id, balance, coalesce(free_balance, 0)
            INTO v_credit_id, v_balance, v_free_balance;
        END IF;

        INSERT INTO credit_history (credit_id, amount, display_amount, booking_ref, note, created_at)
        VALUES (v_credit_id, 0, v_price, p_booking_id, v_method_label || ' ricevuto', v_now);

    ELSIF v_booking.old_paid
          AND coalesce(v_booking.old_method, '') NOT IN ('credito', 'lezione-gratuita')
          AND NOT p_new_paid THEN
        UPDATE bookings
        SET    paid = false, payment_method = null, paid_at = null, credit_applied = 0
        WHERE  id = p_booking_id;

        IF v_credit_id IS NOT NULL THEN
            UPDATE credit_history
            SET    hidden = true
            WHERE  credit_id = v_credit_id
              AND  booking_ref = p_booking_id
              AND  amount = 0;
        END IF;

    ELSE
        UPDATE bookings
        SET    paid = p_new_paid,
               payment_method = p_new_method,
               paid_at = coalesce(p_new_paid_at, v_now)
        WHERE  id = p_booking_id;

    END IF;

    IF v_credit_id IS NOT NULL THEN
        UPDATE credits
        SET    balance      = v_balance,
               free_balance = v_free_balance
        WHERE  id = v_credit_id;
    END IF;

    RETURN jsonb_build_object('success', true, 'new_balance', coalesce(v_balance, 0));
END;
$$;

REVOKE ALL ON FUNCTION admin_change_payment_method FROM public;
GRANT EXECUTE ON FUNCTION admin_change_payment_method TO authenticated;


-- ─── admin_add_credit (+ custom_price nell'auto-pay FIFO) ────────────────────
-- Stessa logica della 20260316000000, ma i prezzi booking nell'auto-pay
-- rispettano custom_price.
CREATE OR REPLACE FUNCTION admin_add_credit(
    p_email       TEXT,
    p_whatsapp    TEXT    DEFAULT NULL,
    p_name        TEXT    DEFAULT '',
    p_amount      NUMERIC DEFAULT 0,
    p_note        TEXT    DEFAULT '',
    p_method      TEXT    DEFAULT '',
    p_free_lesson BOOLEAN DEFAULT false,
    p_slot_prices JSONB   DEFAULT '{"personal-training":5,"small-group":10,"group-class":30}'
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
    v_email         TEXT        := lower(trim(p_email));
    v_credit_id     UUID;
    v_balance       NUMERIC(10,2);
    v_free_balance  NUMERIC(10,2);
    v_booking       RECORD;
    v_price         NUMERIC(10,2);
    v_remaining     NUMERIC(10,2);
    v_free_used     NUMERIC(10,2);
    v_pay_method    TEXT;
    v_total_applied NUMERIC(10,2) := 0;
    v_free_applied  NUMERIC(10,2) := 0;
    v_count         INTEGER       := 0;
    v_now           TIMESTAMPTZ   := now();
    v_debt_id       UUID;
    v_debt_balance  NUMERIC(10,2);
    v_to_offset     NUMERIC(10,2);
    v_debt_offset   NUMERIC(10,2) := 0;
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'Accesso negato: richiesto ruolo admin';
    END IF;

    SELECT id, balance, coalesce(free_balance, 0)
    INTO   v_credit_id, v_balance, v_free_balance
    FROM   credits
    WHERE  email = v_email
    FOR UPDATE;

    IF NOT FOUND THEN
        INSERT INTO credits (name, whatsapp, email, balance, free_balance)
        VALUES (p_name, p_whatsapp, v_email, 0, 0)
        RETURNING id, balance, coalesce(free_balance, 0) INTO v_credit_id, v_balance, v_free_balance;
    END IF;

    IF p_amount <> 0 THEN
        v_balance := round((v_balance + p_amount)::numeric, 2);
        IF p_free_lesson AND p_amount > 0 THEN
            v_free_balance := round((v_free_balance + p_amount)::numeric, 2);
        END IF;
    END IF;

    INSERT INTO credit_history (credit_id, amount, note, created_at, method)
    VALUES (v_credit_id, p_amount, p_note, v_now, coalesce(p_method, ''));

    IF v_balance > 0 THEN
        FOR v_booking IN
            SELECT id, slot_type, coalesce(credit_applied, 0) AS credit_applied, custom_price
            FROM   bookings
            WHERE  lower(email) = v_email
              AND  paid = false
              AND  status NOT IN ('cancelled', 'cancellation_requested')
              AND  (
                    date < (v_now AT TIME ZONE 'Europe/Rome')::date
                    OR (date = (v_now AT TIME ZONE 'Europe/Rome')::date
                        AND split_part(time, ' - ', 1)::time <= (v_now AT TIME ZONE 'Europe/Rome')::time)
              )
            ORDER  BY date ASC, time ASC
            FOR UPDATE
        LOOP
            v_price     := round(coalesce(v_booking.custom_price, (p_slot_prices ->> v_booking.slot_type)::numeric, 0), 2);
            v_remaining := v_price - v_booking.credit_applied;

            IF v_balance >= v_remaining THEN
                v_free_used    := least(v_free_balance, v_remaining);
                v_pay_method   := CASE WHEN v_free_balance >= v_remaining THEN 'lezione-gratuita' ELSE 'credito' END;
                v_free_balance := round((v_free_balance - v_free_used)::numeric, 2);
                v_free_applied := v_free_applied + v_free_used;
                v_balance      := round((v_balance - v_remaining)::numeric, 2);
                v_total_applied := v_total_applied + v_remaining;
                v_count        := v_count + 1;
                UPDATE bookings
                SET    paid = true, payment_method = v_pay_method,
                       paid_at = v_now, credit_applied = 0
                WHERE  id = v_booking.id;

            ELSIF v_balance > 0 AND v_booking.credit_applied = 0 THEN
                v_free_used     := least(v_free_balance, v_balance);
                v_free_balance  := round((v_free_balance - v_free_used)::numeric, 2);
                v_free_applied  := v_free_applied + v_free_used;
                v_total_applied := v_total_applied + v_balance;
                UPDATE bookings SET credit_applied = v_balance WHERE id = v_booking.id;
                v_balance := 0;
            END IF;

            EXIT WHEN v_balance <= 0;
        END LOOP;

        IF v_count > 0 THEN
            INSERT INTO credit_history (credit_id, amount, note, created_at)
            VALUES (
                v_credit_id,
                -v_total_applied,
                'Auto-pagamento ' || v_count || ' lezione' || CASE WHEN v_count > 1 THEN 'i' ELSE '' END || ' con credito',
                v_now + interval '1 millisecond'
            );
        END IF;
    END IF;

    IF v_balance > 0 THEN
        SELECT id, balance INTO v_debt_id, v_debt_balance
        FROM   manual_debts
        WHERE  lower(email) = v_email
        FOR UPDATE;

        IF FOUND AND v_debt_balance > 0 THEN
            v_to_offset := round(least(v_debt_balance, v_balance)::numeric, 2);

            UPDATE manual_debts
            SET    balance = round((balance - v_to_offset)::numeric, 2),
                   history = history || jsonb_build_array(jsonb_build_object(
                       'date',   v_now,
                       'amount', -v_to_offset,
                       'note',   'Compensato con credito',
                       'method', ''
                   ))
            WHERE  id = v_debt_id;

            v_balance     := round((v_balance - v_to_offset)::numeric, 2);
            v_debt_offset := v_to_offset;

            INSERT INTO credit_history (credit_id, amount, note, created_at)
            VALUES (v_credit_id, -v_to_offset, 'Applicato a debito manuale',
                    v_now + interval '2 milliseconds');
        END IF;
    END IF;

    UPDATE credits
    SET    balance      = v_balance,
           free_balance = v_free_balance
    WHERE  id = v_credit_id;

    RETURN jsonb_build_object(
        'success',       true,
        'new_balance',   v_balance,
        'bookings_paid', v_count,
        'total_applied', v_total_applied,
        'debt_offset',   v_debt_offset
    );
END;
$$;

REVOKE ALL ON FUNCTION admin_add_credit FROM public;
GRANT EXECUTE ON FUNCTION admin_add_credit TO authenticated;
