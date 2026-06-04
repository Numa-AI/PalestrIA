-- ─── Fix get_debtors: includi clienti con solo debiti manuali ────────────────
-- La versione precedente partiva solo dalle prenotazioni non pagate (CTE "unpaid")
-- e faceva LEFT JOIN su manual_debts. Clienti con SOLO debito manuale (senza
-- prenotazioni non pagate) non comparivano nel conteggio.
-- Ora aggiungiamo i debiti manuali orfani con UNION ALL.

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
    -- Booking non pagati il cui orario di inizio è già passato (fuso italiano)
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
            coalesce((p_slot_prices ->> b.slot_type)::numeric, 0) AS price,
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
    -- ── Raggruppamento contatti (stessa logica di prima) ─────────────────────
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
    -- Assegna chiave contatto a ogni booking
    keyed AS (
        SELECT u.*, coalesce(r.ckey, u.norm_email) AS ckey
        FROM unpaid u
        LEFT JOIN resolved r ON u.norm_email = r.norm_email
    ),
    -- Aggrega prenotazioni per contatto
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
    -- ── Debiti manuali come fonte indipendente ──────────────────────────────
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
    -- ── Unisci prenotazioni + debiti manuali ────────────────────────────────
    with_debts AS (
        -- Clienti con prenotazioni (possono anche avere debiti manuali)
        SELECT
            g.*,
            coalesce(md.balance, 0)         AS manual_debt,
            coalesce(md.history, '[]'::jsonb) AS manual_debt_history
        FROM grouped g
        LEFT JOIN manual_debts md ON lower(md.email) = g.ckey
        UNION ALL
        -- Clienti con SOLO debiti manuali
        SELECT * FROM manual_only
    ),
    -- Sottrai crediti
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
