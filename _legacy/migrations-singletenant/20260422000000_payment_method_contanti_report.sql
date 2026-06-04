-- ─── Nuovo metodo di pagamento: 'contanti-report' ────────────────────────────
-- Contanti registrati come pagamento "reportabile" (fiscale): soldi in cassa
-- come i contanti normali, ma inclusi nel report settimanale/fiscale come
-- carta/iban/stripe.

-- Estende CHECK constraint su bookings.payment_method
alter table bookings
    drop constraint if exists bookings_payment_method_check;
alter table bookings
    add constraint bookings_payment_method_check
    check (payment_method is null or payment_method in (
        'contanti', 'contanti-report', 'carta', 'iban', 'stripe', 'credito', 'lezione-gratuita'
    ));

-- Stesso per cancelled_payment_method
alter table bookings
    drop constraint if exists bookings_cancelled_payment_method_check;
alter table bookings
    add constraint bookings_cancelled_payment_method_check
    check (cancelled_payment_method is null or cancelled_payment_method in (
        'contanti', 'contanti-report', 'carta', 'iban', 'stripe', 'credito', 'lezione-gratuita'
    ));

-- NOTA: le RPC admin_pay_bookings / admin_change_payment_method hanno un CASE
-- inline per calcolare v_method_label che termina con `ELSE p_payment_method`.
-- Per il nuovo metodo 'contanti-report' il label salvato in credit_history.note
-- sarà la stringa grezza; il rendering lato UI sostituisce con "Contanti con Report".
