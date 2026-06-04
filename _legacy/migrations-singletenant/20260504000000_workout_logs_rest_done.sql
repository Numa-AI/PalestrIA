-- Aggiunge la colonna rest_done a workout_logs.
-- Il client (allenamento.html, js/data.js, storico) la scrive da sempre, ma
-- non era mai stata creata: ogni upsert falliva con
-- "Could not find the 'rest_done' column of 'workout_logs' in the schema cache".

ALTER TABLE workout_logs ADD COLUMN IF NOT EXISTS rest_done INT;
