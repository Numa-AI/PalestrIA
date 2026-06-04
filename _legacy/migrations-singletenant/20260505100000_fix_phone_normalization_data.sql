-- ─────────────────────────────────────────────────────────────────────────────
-- Bug fix: numeri di cellulare con prefisso `39X` (es. 392, 393, 395, 397...)
-- erano stati salvati senza il country code. La vecchia normalizePhone() in JS
-- considerava qualunque numero che iniziasse per "39" come già prefissato col
-- country code, perdendo le prime 2 cifre del cellulare. Quindi `3925666618`
-- (cellulare valido di 10 cifre) veniva salvato come `+3925666618` invece di
-- `+393925666618`.
--
-- Pattern dei record corrotti: `^\+39\d{8}$` (esattamente 8 cifre dopo +39).
--
-- ⚠️  ATTENZIONE: lo stesso pattern matcha anche fissi italiani brevi normalizzati
-- (es. Napoli "081 123456" → `+3981123456`). I clienti palestra sono però quasi
-- tutti da cellulare WhatsApp, quindi il rischio di falsi positivi è basso. Per
-- sicurezza, eseguire prima la query di diagnostica (sotto) e validare la lista.
--
-- Tutte le operazioni sono protette da `to_regclass()`: se una tabella non esiste
-- nello schema, viene saltata silenziosamente. Così la migration è portabile su
-- DB con sottoinsiemi diversi del modello (es. niente slot_access_requests).
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1. DIAGNOSTICA — esegui questa parte da sola per vedere cosa verrà toccato
do $$
declare
    v_count int;
    v_pairs text[][] := array[
        ['profiles',             'whatsapp'],
        ['bookings',             'whatsapp'],
        ['credits',              'whatsapp'],
        ['manual_debts',         'whatsapp'],
        ['bonuses',              'whatsapp'],
        ['slot_access_requests', 'user_whatsapp']
    ];
    v_table text;
    v_col   text;
begin
    for i in 1 .. array_length(v_pairs, 1) loop
        v_table := v_pairs[i][1];
        v_col   := v_pairs[i][2];
        if to_regclass(v_table) is null then
            raise notice '%: tabella inesistente, skip', v_table;
        else
            execute format('select count(*) from %I where %I ~ ''^\+39\d{8}$''', v_table, v_col)
                into v_count;
            raise notice '% (%): % record affetti', v_table, v_col, v_count;
        end if;
    end loop;
end $$;

-- ── 2. ELENCO DETTAGLIATO (cross-check pre-fix) — decommenta per ispezione manuale
--   select id, name, email, whatsapp,
--          '+39' || substring(whatsapp from 2) as proposed_fix
--   from profiles
--   where whatsapp ~ '^\+39\d{8}$'
--   order by name;

-- ── 3. FIX — premette `39` dopo il `+` per ricostruire il country code mancante
do $$
declare
    v_pairs text[][] := array[
        ['profiles',             'whatsapp'],
        ['bookings',             'whatsapp'],
        ['credits',              'whatsapp'],
        ['manual_debts',         'whatsapp'],
        ['bonuses',              'whatsapp'],
        ['slot_access_requests', 'user_whatsapp']
    ];
    v_table text;
    v_col   text;
    v_rows  int;
begin
    for i in 1 .. array_length(v_pairs, 1) loop
        v_table := v_pairs[i][1];
        v_col   := v_pairs[i][2];
        if to_regclass(v_table) is null then
            raise notice '%: tabella inesistente, skip update', v_table;
        else
            execute format(
                'update %I set %I = ''+39'' || substring(%I from 2) where %I ~ ''^\+39\d{8}$''',
                v_table, v_col, v_col, v_col
            );
            get diagnostics v_rows = row_count;
            raise notice '% (%): % record aggiornati', v_table, v_col, v_rows;
        end if;
    end loop;
end $$;
