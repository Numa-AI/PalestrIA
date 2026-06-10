-- ─────────────────────────────────────────────────────────────────────────────
-- Migration incrementale — allinea imported_exercises allo schema usato dal frontend
-- ─────────────────────────────────────────────────────────────────────────────
-- Sintomo: la tab "Importa" e la creazione schede falliscono con
--   "column imported_exercises.nome_original does not exist".
-- Causa: durante il consolidamento SaaS la tabella imported_exercises e' stata
-- ridefinita con colonne diverse (muscle_group/immagine_url/...) rispetto a quelle
-- che il frontend ha sempre usato (admin-importa.js, admin-schede.js,
-- allenamento.html, tablet.html), che leggono/scrivono:
--   slug, nome_it, nome_original, nome_en, categoria, immagine,
--   immagine_thumbnail, video, popolarita
-- Il baseline e' gia' applicato sullo storico migration del progetto remoto, quindi
-- (come per la 00000000000010) le sole differenze vanno portate qui in modo idempotente.
-- ─────────────────────────────────────────────────────────────────────────────

-- 1) Colonne mancanti attese dal frontend (idempotenti)
alter table imported_exercises add column if not exists nome_original      text;
alter table imported_exercises add column if not exists nome_en            text;
alter table imported_exercises add column if not exists categoria          text;
alter table imported_exercises add column if not exists immagine           text;
alter table imported_exercises add column if not exists immagine_thumbnail text;
alter table imported_exercises add column if not exists video              text;
alter table imported_exercises add column if not exists popolarita         integer default 0;

-- 2) org_id auto = org corrente all'INSERT. Il frontend (admin-importa.js _importaAdd)
--    inserisce senza passare org_id: senza default il valore sarebbe NULL e la policy
--    di scrittura `imported_exercises_admin` (WITH CHECK org_id = current_org_id()
--    AND is_org_admin(org_id)) bloccherebbe l'import. Con questo default l'admin
--    importa nel proprio tenant e la RLS e' soddisfatta senza modifiche al JS.
alter table imported_exercises alter column org_id set default current_org_id();

-- 3) Backfill: per le righe eventualmente gia' presenti, nome_original = nome_it
update imported_exercises set nome_original = nome_it where nome_original is null;
