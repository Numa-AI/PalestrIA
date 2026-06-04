-- Privacy prenotazioni: default false per i nuovi utenti.

alter table profiles alter column privacy_prenotazioni set default false;
