-- Indici per velocizzare le RPC pagamento/autopay basate su lookup email.

create index if not exists idx_bookings_unpaid_lower_email
    on bookings (lower(email), date, time)
    where paid = false and status not in ('cancelled', 'cancellation_requested');

create index if not exists idx_manual_debts_lower_email
    on manual_debts (lower(email));

create index if not exists idx_credits_email
    on credits (email);

create index if not exists idx_profiles_lower_email
    on profiles (lower(email));
