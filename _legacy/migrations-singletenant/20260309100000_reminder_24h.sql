-- Colonna per tracciare se il promemoria 24h è già stato inviato
alter table bookings
    add column if not exists reminder_24h_sent boolean not null default false;
