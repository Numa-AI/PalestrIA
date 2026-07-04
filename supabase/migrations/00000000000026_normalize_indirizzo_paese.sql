-- 00000000000026_normalize_indirizzo_paese.sql
-- Normalizzazione del comune di residenza (profiles.indirizzo_paese) in title-case
-- italiano + BACKFILL una-tantum dei dati già presenti.
--
-- Contesto: alcuni clienti inserivano il comune tutto minuscolo o tutto maiuscolo.
-- Lato client la normalizzazione avviene ad ogni salvataggio (helper JS
-- normalizeComune in js/auth.js). Questa migration crea la stessa regola lato SQL e
-- riallinea i valori storici. La funzione normalize_comune() replica IDENTICA la
-- logica JS: title-case (initcap tratta spazio/'/- come confine, come il regex JS),
-- poi minuscolo sui connettivi/articoli se NON prima parola.
--
-- Idempotente: tocca SOLO le righe che cambiano davvero (IS DISTINCT FROM), quindi è
-- rilanciabile senza churn su updated_at. Post-baseline (opera su profiles, tabella
-- della baseline) → nessun impatto sul job CI baseline-only. Da applicare a mano nel
-- SQL Editor di Supabase (le migration non si auto-deployano).

create or replace function public.normalize_comune(input text)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare
    s        text;
    words    text[];
    w        text;
    lw       text;
    ap       text;
    i        int;
    matched  boolean;
    -- Connettivi (parole intere) minuscoli se non prima parola. Identici al set JS.
    conn     text[] := array[
        'di','del','dei','della','delle','dello','degli','da','dal','dai','dalle','dagli','dallo',
        'in','nel','nei','nella','nelle','nello','negli','a','ai','al','alla','alle','allo','agli',
        'e','ed','con','su','sul','sui','sulla','sulle','sullo','sugli','per','tra','fra',
        'la','le','lo','il','i','gli','l'];
    -- Prefissi con apostrofo: minuscolo solo il prefisso, resto invariato. Dal più
    -- lungo al più corto (match corretto). Identici all'array JS _COMUNE_CONN_AP.
    conn_ap  text[] := array['dell''','nell''','sull''','dall''','all''','d''','l'''];
begin
    if input is null then return null; end if;
    -- 1) apostrofo curvo → dritto, trim, collapse spazi multipli
    s := regexp_replace(btrim(translate(input, '’‘ʼ', '''''''')), '\s+', ' ', 'g');
    if s = '' then return ''; end if;
    -- 2) title-case (initcap: confine = qualsiasi non-alfanumerico, incl. spazio/'/-)
    s := initcap(s);
    -- 3) minuscolo sui connettivi quando NON prima parola
    words := string_to_array(s, ' ');
    if array_length(words, 1) is null then return s; end if;
    for i in 2 .. array_length(words, 1) loop
        w  := words[i];
        lw := lower(w);
        matched := false;
        if lw = any(conn) then
            words[i] := lw;
            matched  := true;
        end if;
        if not matched then
            foreach ap in array conn_ap loop
                if left(lw, length(ap)) = ap then
                    words[i] := ap || substr(w, length(ap) + 1);
                    exit;
                end if;
            end loop;
        end if;
    end loop;
    return array_to_string(words, ' ');
end;
$$;

-- Backfill idempotente (tutte le org: normalizzazione org-agnostica, gira come
-- ruolo migration che bypassa RLS). Solo le righe che cambiano vengono toccate.
update public.profiles
set indirizzo_paese = normalize_comune(indirizzo_paese)
where indirizzo_paese is not null
  and btrim(indirizzo_paese) <> ''
  and indirizzo_paese is distinct from normalize_comune(indirizzo_paese);
