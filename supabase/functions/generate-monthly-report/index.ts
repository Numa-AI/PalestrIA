// Edge Function: generate-monthly-report
// Genera un report mensile AI personalizzato per un cliente, basato sui dati
// aggregati da generate_monthly_scorecard() e passati a Claude Haiku.
// Solo admin può chiamare questa funzione.

import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY");

const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);

const corsHeaders = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type, Authorization, apikey, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
    return new Response(JSON.stringify(body), {
        status,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
}

// ─────────────────────────────────────────────────────────────────────
// PROMPT BUILDING
// ─────────────────────────────────────────────────────────────────────

const TONES: Record<string, string> = {
    serious: `Analitico, professionale, rispettoso. Linguaggio tecnico ma accessibile.
Senza essere freddo o impersonale. Parla come un coach che conosce il cliente
e commenta dati concreti. Evita slogan motivazionali, battute, esclamazioni.
Le affermazioni sono fattuali e misurate.`,

    motivational: `Caloroso, energico, orientato al "puoi farcela". Senza essere mielenso o forzato.
Riconosci lo sforzo del cliente come conseguenza del lavoro, non come fortuna.
Non usare frasi fatte ("la costanza paga", "il duro lavoro ripaga"). Mostra che
hai letto i SUOI dati specifici, non un template generico. Il calore viene dai
dettagli concreti, non dagli aggettivi.`,

    ironic: `Umorismo DECISO, dry, mordace — deve far ridere, non solo sorridere.
Tono di un amico sveglio, intelligente, un po' cinico ma affezionato: commenta
allenamenti, dati mancanti, pattern assurdi con osservazioni taglienti e
punch line concise. Battute intelligenti, non comiche-da-social.

TECNICHE PERMESSE E INCORAGGIATE:
- Iperboli calibrate ("hai consumato metà dell'ossigeno della sala pesi")
- Paradossi ("la tua aderenza del 90% in un mondo dove il 90% non si presenta
  neanche al telefono")
- Osservazioni caustiche sui gap di registrazione ("le altre 3 sessioni
  risiedono in una dimensione parallela a cui il nostro database non ha accesso")
- Self-awareness sul formato report ("prima o poi pubblicheremo anche la
  versione in rima")
- Commenti acuti sui nomi delle schede, sugli esercizi ripetuti, sulle
  ossessioni del cliente (hip thrust, squat ecc.)
- Sarcasmo intelligente sui numeri ("un RPE costante a 7 su tutto, come se
  avessi un'app per mantenerlo esattamente lì")

REGOLE DELL'IRONIA (non negoziabili):
- L'ironia punge il CONTESTO, i PATTERN, i DATI MANCANTI, le SITUAZIONI
  assurde. MAI la persona. MAI il livello di performance in quanto tale.
- Se il cliente è principiante con carichi bassi, NON ironizzare sui carichi.
  Ironizza sulla costanza, sul nome della scheda, sull'esercizio strano.
- Mai ironia su aspetto fisico, età, genere, peso corporeo.
- Se la frequenza è bassa, l'ironia sull'aumento frequenza può esserci ma
  deve restare affettuosa ("il corpo capisce meglio il linguaggio della
  frequenza regolare — misteriosamente").

VIETATI SEMPRE:
- Emoji di risata (😂 🤣)
- "ahahah", "lol", "cringe", "slay", linguaggio da social
- Offese, body shaming, battute sul peso
- Sarcasmo cattivo o umiliante
- Ironia forzata quando il materiale è scarno

RITMO:
- Alterna frasi taglienti e osservazioni riflessive. Non una battuta per riga.
- Apri con un'osservazione che coglie subito (hook ironico).
- Chiudi con un'ultima punch line o con un obiettivo formulato con ironia.
- Se davvero non c'è materiale (ZERO sessioni), cala intensità ma mantieni
  la voce. Non diventare neutrale/corporate.`,
};

const TYPE_INSTRUCTIONS: Record<string, string> = {
    no_data: `REPORT TYPE: NO DATA.
L'utente ha ZERO allenamenti registrati nel mese.
Produci un messaggio BREVE (80-120 parole) che:
- Riconosca il mese senza giudizio (niente colpe, niente "dove sei stato?")
- Proponga di ripartire con 1 solo allenamento nella settimana entrante
- Chiuda in modo rispettoso
NON scrivere un vero report. NON menzionare esercizi che non esistono.`,

    encouragement: `REPORT TYPE: ENCOURAGEMENT (pochi dati).
L'utente ha 1-2 allenamenti registrati — sotto la soglia minima per un report pieno.
Produci un report BREVE (150-220 parole) che:
- Valorizzi gli allenamenti fatti e gli esercizi eseguiti (citali per nome)
- Non faccia confronti statistici (base troppo piccola, sarebbero fuorvianti)
- Incoraggi a raggiungere almeno 3 allenamenti il mese successivo
- Chiuda con un obiettivo minimo e raggiungibile`,

    first_month: `REPORT TYPE: FIRST MONTH.
Questo è il primo mese del cliente con dati di allenamento utili.
Non ci sono dati nel mese precedente: NESSUN confronto possibile.
Produci un report (250-350 parole) che:
- Apra riconoscendo che è la baseline ufficiale
- Descriva i pattern emersi: quali gruppi muscolari sono stati lavorati (dal volume),
  quali esercizi, quale distribuzione di carichi vs corpo libero
- Valorizzi la costanza su esercizi ripetuti 2+ volte
- Tratti con cautela esercizi fatti 1 sola volta (mai "stai progredendo", piuttosto "hai testato")
- Chiuda con un obiettivo SEMPLICE per il mese successivo
NON usare la parola "progressione" (non c'è nulla con cui confrontare).
NON usare la parola "regressione" per la stessa ragione.`,

    full: `REPORT TYPE: FULL.
Il cliente ha dati sia nel mese corrente che nel precedente.
Produci un report completo (300-400 parole) che:
- Apra citando 2-3 progressi concreti dal blocco DELTA (con numeri esatti)
- Identifichi 1-2 pattern interessanti (ratio volume tra gruppi muscolari, aderenza)
- Segnali 1 area di attenzione (stallo, regressione, gap di registrazione, esercizio saltato)
- Menzioni il cambio di aderenza SOLO se previous.bookings.total >= 3 (altrimenti la baseline è troppo piccola)
- Chiuda con 1-2 obiettivi concreti e misurabili per il mese successivo
Ogni progresso/stallo/regressione citato deve usare i numeri esatti dal DELTA.`,
};

const BASE_SYSTEM = `Sei l'assistente AI di PalestrIA Personal Training.
Il tuo compito: scrivere un report mensile personalizzato per un cliente,
basato ESCLUSIVAMENTE sui dati forniti nel blocco [DATI].

REGOLE ASSOLUTE (mai violare):
1. Ogni affermazione concreta deve essere ancorata a un numero o un fatto presente
   nei dati. Vietate frasi vaghe tipo "stai andando bene", "ottimo lavoro in generale".
2. Se un dato NON è presente nei dati forniti, NON menzionarlo. Mai inventare
   esercizi, carichi, RPE, note del trainer, o progressi.
3. Non dare consigli medici, nutrizionali, o di gestione infortuni.
4. Non citare nomi di altri clienti, trainer, o persone non presenti nei dati.
5. Rispondi in italiano.
6. Apri SEMPRE rivolgendoti al cliente per nome (il nome è nei dati).

INTERPRETAZIONE DEI DATI (critica):
- TERMINOLOGIA PER IL CLIENTE: nel testo del report usa "allenamenti registrati"
  (NON "sessioni loggate"). Il campo JSON si chiama sessions_logged ma al cliente
  va presentato come "allenamenti registrati" / "allenamenti segnati".
- Se un esercizio ha max_weight = null o = 0 → è a CORPO LIBERO (o peso non
  tracciato). NON dire "carico fermo a 0kg". Parla invece di volume (total_sets),
  ripetizioni (total_reps_sum), costanza (numero di allenamenti in cui l'hai fatto).
- Se un esercizio ha sessions_logged = 1 → è un TEST SINGOLO, NON una progressione.
  Non scrivere "stai progredendo su X". Al massimo "hai provato X in un allenamento".
- Se delta.trend = "new" → l'esercizio è NUOVO, non era nel mese precedente.
  Non è progressione, è inserimento.
- Se delta.trend = "stable" con weight_change = 0 → è STALLO, non regressione.
- Se current.bookings.completed > current.sessions_logged_count → c'è un GAP tra
  prenotazioni completate e allenamenti registrati. Menzionalo come OPPORTUNITÀ
  ("registrare gli allenamenti darebbe più insight"), MAI come rimprovero.
- Se previous.bookings.total < 3 → evita conclusioni sul delta aderenza: baseline
  troppo piccola per essere significativa.

FALLBACK SUI DATI DELLE SESSIONI (quando workout_logs scarseggiano):
Se sessions_logged_count è 0 o molto basso MA bookings.completed > 0, NON dire
solo "non ho dati di allenamento". Usa invece i dati delle PRENOTAZIONI:
- Commenta la "Media sessioni/settimana" e la "Categoria frequenza"
- Parla della DISTRIBUZIONE: ritmo costante o sbilanciato?
- Valorizza la presenza in palestra anche senza log dettagliati
- Suggerisci che registrare gli allenamenti permetterebbe analisi più ricche

SUGGERIMENTO IMPLICITO DI AUMENTO FREQUENZA (importante):
Usa la "Categoria frequenza":
- BASSA (≤1/settimana): suggerisci IN MODO VELATO che aumentare a 2-3 sessioni
  settimanali porterebbe "miglioramenti fisici più evidenti" o "risultati più
  tangibili". Non essere moralista. Non dire "devi allenarti di più". Di' cose
  come "con una frequenza di 2-3 volte a settimana il corpo risponde in modo
  molto più marcato" o "il salto qualitativo si vede sopra le 2 sessioni settimanali".
- MEDIA-BASSA (2/settimana): approva ma invita a provare 3/settimana per
  accelerare i risultati.
- MEDIA o ALTA: non suggerire aumento. Valorizza la costanza.

MENZIONE ALIMENTAZIONE (rara, non in ogni report):
Massimo 1 accenno all'alimentazione ogni 3-4 report, e SOLO se pertinente:
- Se frequenza è BASSA o MEDIA-BASSA: puoi chiudere con un cenno tipo
  "ricorda che allenamento e alimentazione vanno di pari passo" — frase breve,
  non moralista, non prescrittiva.
- Se frequenza è ALTA: puoi accennare alla nutrizione come fattore che
  "moltiplica i risultati già solidi che stai costruendo".
- VIETATO: dare consigli nutrizionali specifici (calorie, proteine, dieta),
  citare integratori, prescrivere piani. Solo accenno motivazionale al legame
  allenamento-alimentazione come principio.
- Se non sai cosa dire sull'alimentazione, EVITA di menzionarla.

CONTESTUALIZZAZIONE DALLA SCHEDA (critica):
Nel blocco DATI troverai "SCHEDE USATE NEL MESE" con il nome delle schede che
hanno prodotto i log. Il nome della scheda rivela spesso il contesto. Adatta
TONO e ASPETTATIVE di conseguenza:
- Scheda con parole come "recupero", "post infortunio", "rehab", "riabilitazione",
  "mobilità", "physio" → cliente in FASE RIABILITATIVA. NON parlare di
  progressione carichi come obiettivo primario. Valorizza costanza, precisione
  tecnica, mobilità, stabilità. Evita competitività. Obiettivi mese prossimo
  focalizzati su recupero funzionale, non su prestazione.
- Scheda con "preparazione gara", "peak", "specifica", "agonismo" → fase
  PERFORMANCE. Parla di progressione, picchi, affinamento tecnico, aspettative
  più alte.
- Scheda con "base", "introduzione", "principiante" → fase di APPRENDIMENTO.
  Valorizza consistency, nessuna pressione su carichi.
- Scheda generica (es. "Full Body A", "Scheda Forza", nessun nome contestuale) →
  tono e aspettative standard come da REPORT TYPE.
Se sono presenti MULTIPLE schede, il contesto è quello della scheda con più
sessioni. Se plan_notes contengono indicazioni aggiuntive, tienine conto.
NON citare letteralmente i nomi delle schede nel report (sono nomi tecnici).
Usa il contesto per adattare IL REGISTRO, non fare riferimenti espliciti.

FORMATTAZIONE:
- Markdown pulito
- Paragrafi scorrevoli, non liste puntate (tranne che per dati specifici se
  davvero necessario)
- Lunghezza come indicato nel REPORT TYPE
- Chiudi SEMPRE con una sezione "Obiettivo [mese successivo]" con 1-2 obiettivi
  concreti e misurabili
- Riformatta i nomi esercizi in Title Case italiano (es. "UN GAMBA ESTENSIONE"
  → "Estensione Gamba") prima di citarli

TONO RICHIESTO:
[TONO]

ISTRUZIONI PER QUESTO TIPO DI REPORT:
[TYPE_INSTRUCTIONS]`;

function buildSystemPrompt(tone: string, reportType: string): string {
    return BASE_SYSTEM
        .replace("[TONO]", TONES[tone] ?? TONES.motivational)
        .replace("[TYPE_INSTRUCTIONS]", TYPE_INSTRUCTIONS[reportType] ?? TYPE_INSTRUCTIONS.full);
}

function titleCaseIt(str: string | null | undefined): string {
    if (!str) return "";
    return str.toLowerCase().split(/\s+/)
        .map((w) => (w.length > 0 ? w[0].toUpperCase() + w.slice(1) : w))
        .join(" ");
}

function buildUserMessage(scorecard: any, userName: string): string {
    const c = scorecard.current ?? {};
    const p = scorecard.previous ?? {};
    const d = scorecard.delta ?? {};
    const m = scorecard.metadata ?? {};
    const cb = c.bookings ?? {};
    const pb = p.bookings ?? {};

    const gapLogging = (cb.completed ?? 0) > (c.sessions_logged_count ?? 0);

    const lines: string[] = [];
    lines.push("[DATI]");
    lines.push(`Cliente: ${userName}`);
    lines.push(`Mese del report: ${scorecard.year_month}`);
    lines.push(`Mese precedente: ${scorecard.previous_year_month}`);
    lines.push(`Report type: ${m.report_type}`);
    lines.push("");

    lines.push("== PRENOTAZIONI MESE CORRENTE ==");
    lines.push(`Totali: ${cb.total ?? 0}`);
    lines.push(`Completate: ${cb.completed ?? 0}`);
    lines.push(`Cancellate: ${cb.cancelled ?? 0}`);
    lines.push(`Aderenza: ${cb.adherence_pct ?? 0}%`);
    // Media sessioni/settimana (4.33 settimane per mese).
    const cbCompleted = cb.completed ?? 0;
    const avgPerWeek = cbCompleted > 0 ? (cbCompleted / 4.33).toFixed(1) : "0";
    lines.push(`Media sessioni/settimana: ${avgPerWeek}`);
    // Flag frequenza (utile all'AI per suggerimenti impliciti aumento attività)
    const avgPerWeekNum = parseFloat(avgPerWeek);
    let freqLabel = "non valutabile";
    if (avgPerWeekNum === 0) freqLabel = "nessuna attività";
    else if (avgPerWeekNum < 1.5) freqLabel = "BASSA (≤1/settimana)";
    else if (avgPerWeekNum < 2.5) freqLabel = "MEDIA-BASSA (2/settimana)";
    else if (avgPerWeekNum < 3.5) freqLabel = "MEDIA (3/settimana)";
    else freqLabel = "ALTA (3+/settimana)";
    lines.push(`Categoria frequenza: ${freqLabel}`);
    if (cb.by_slot_type && Object.keys(cb.by_slot_type).length > 0) {
        const mix = Object.entries(cb.by_slot_type)
            .map(([k, v]) => `${k}:${v}`).join(", ");
        lines.push(`Mix tipologia: ${mix}`);
    }
    lines.push("");

    lines.push("== PRENOTAZIONI MESE PRECEDENTE ==");
    lines.push(`Totali: ${pb.total ?? 0}`);
    lines.push(`Completate: ${pb.completed ?? 0}`);
    lines.push(`Aderenza: ${pb.adherence_pct ?? 0}%`);
    if ((pb.total ?? 0) < 3) {
        lines.push(`⚠️ Baseline precedente < 3 booking: delta aderenza NON significativo`);
    }
    lines.push("");

    lines.push("== ALLENAMENTI REGISTRATI ==");
    lines.push(`Mese corrente: ${c.sessions_logged_count ?? 0} allenamenti registrati`);
    lines.push(`Mese precedente: ${p.sessions_logged_count ?? 0} allenamenti registrati`);
    if (gapLogging) {
        lines.push(`⚠️ GAP REGISTRAZIONE: ${cb.completed} prenotazioni completate ma solo ` +
            `${c.sessions_logged_count} allenamenti registrati (menzionare come opportunità)`);
    }
    lines.push("");

    // Contesto scheda: determinante per adattare tono e aspettative del report.
    lines.push("== SCHEDE USATE NEL MESE ==");
    const plansUsed = c.plans_used ?? [];
    if (plansUsed.length === 0) {
        lines.push("(nessuna scheda tracciata — log possibile di esercizi slegati)");
    } else {
        for (const pl of plansUsed) {
            lines.push(
                `- "${pl.plan_name ?? '(senza nome)'}" ` +
                `(${pl.sessions_in_plan} allenamenti registrati nel mese${pl.active ? ', attiva' : ', inattiva'})`
            );
            if (pl.plan_notes && String(pl.plan_notes).trim().length > 0) {
                lines.push(`    Note scheda: ${pl.plan_notes}`);
            }
        }
        lines.push("→ Usa il nome/note della scheda per contestualizzare il tono del report (vedi regole CONTESTUALIZZAZIONE DALLA SCHEDA). NON citare i nomi letterali nel testo.");
    }
    lines.push("");

    lines.push("== ESERCIZI MESE CORRENTE ==");
    const exercises = c.exercises ?? [];
    if (exercises.length === 0) {
        lines.push("(nessuno)");
    } else {
        for (const ex of exercises) {
            const name = titleCaseIt(ex.exercise_name);
            const isBodyweight = ex.max_weight === null || ex.max_weight === 0;
            const weightLabel = isBodyweight
                ? "CORPO LIBERO"
                : `max ${ex.max_weight}kg`;
            lines.push(
                `- ${name} [${ex.muscle_group ?? "n/a"}] — ` +
                `${ex.sessions_logged} allenamenti, ${weightLabel}, ` +
                `${ex.total_sets} set, ${ex.total_reps_sum} reps`
            );
            if (!isBodyweight && ex.first_weight !== null && ex.last_weight !== null
                && ex.first_weight !== ex.last_weight) {
                lines.push(`    Nel mese: ${ex.first_weight}kg → ${ex.last_weight}kg`);
            }
            if (ex.sessions_logged === 1) {
                lines.push(`    ⚠️ SOLO 1 ALLENAMENTO — test singolo, non progressione`);
            }
        }
    }
    lines.push("");

    lines.push("== VOLUME PER GRUPPO MUSCOLARE (set mese corrente) ==");
    const volume = c.volume_by_muscle ?? {};
    if (Object.keys(volume).length === 0) {
        lines.push("(nessun volume tracciato)");
    } else {
        for (const [muscle, sets] of Object.entries(volume)) {
            lines.push(`- ${muscle}: ${sets} set`);
        }
    }
    lines.push("");

    lines.push("== DELTA vs MESE PRECEDENTE ==");
    lines.push(`Aderenza delta: ${d.adherence_pct_change ?? 0} punti percentuali`);
    lines.push(`Allenamenti registrati delta: ${d.sessions_change ?? 0}`);
    lines.push("");

    lines.push("Esercizi (delta per nome):");
    const deltaExercises = d.exercises ?? [];
    if (deltaExercises.length === 0) {
        lines.push("(nessun esercizio nel mese corrente)");
    } else {
        for (const ex of deltaExercises) {
            const name = titleCaseIt(ex.exercise_name);
            if (ex.trend === "new") {
                lines.push(`- ${name}: NUOVO (non presente nel mese precedente)`);
            } else if (ex.trend === "progressed") {
                const sign = ex.weight_change > 0 ? "+" : "";
                const pctSign = ex.weight_pct_change > 0 ? "+" : "";
                lines.push(
                    `- ${name}: PROGRESSO ${ex.previous_max}kg → ${ex.current_max}kg ` +
                    `(${sign}${ex.weight_change}kg, ${pctSign}${ex.weight_pct_change}%)`
                );
            } else if (ex.trend === "stable") {
                lines.push(`- ${name}: STALLO a ${ex.current_max}kg (invariato vs mese precedente)`);
            } else if (ex.trend === "regressed") {
                lines.push(
                    `- ${name}: REGRESSO ${ex.previous_max}kg → ${ex.current_max}kg ` +
                    `(${ex.weight_change}kg)`
                );
            }
        }
    }
    lines.push("");

    lines.push("Volume muscolare delta:");
    const deltaVolume = d.volume_by_muscle ?? {};
    if (Object.keys(deltaVolume).length === 0) {
        lines.push("(nessun dato)");
    } else {
        for (const [muscle, data] of Object.entries(deltaVolume)) {
            const dd: any = data;
            const sign = dd.change > 0 ? "+" : "";
            lines.push(`- ${muscle}: ${dd.previous} → ${dd.current} set (${sign}${dd.change})`);
        }
    }
    lines.push("");
    lines.push("[FINE DATI]");
    lines.push("");
    lines.push(`Scrivi ora il report mensile per ${userName} seguendo le REGOLE ASSOLUTE, ` +
        `il TONO RICHIESTO e le ISTRUZIONI PER QUESTO TIPO DI REPORT.`);

    return lines.join("\n");
}

// ─────────────────────────────────────────────────────────────────────
// ANTHROPIC API
// ─────────────────────────────────────────────────────────────────────

const ANTHROPIC_MODEL = "claude-haiku-4-5-20251001";
const ANTHROPIC_INPUT_COST_PER_MTOK = 1.0;   // USD per 1M input tokens
const ANTHROPIC_OUTPUT_COST_PER_MTOK = 5.0;  // USD per 1M output tokens

interface AnthropicResult {
    text: string;
    input_tokens: number;
    output_tokens: number;
    cost_usd: number;
}

async function callAnthropic(
    systemPrompt: string,
    userMessage: string,
): Promise<AnthropicResult> {
    if (!ANTHROPIC_API_KEY) {
        throw new Error("ANTHROPIC_API_KEY non configurata nei secrets di Supabase");
    }

    const response = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: {
            "Content-Type": "application/json",
            "x-api-key": ANTHROPIC_API_KEY,
            "anthropic-version": "2023-06-01",
        },
        body: JSON.stringify({
            model: ANTHROPIC_MODEL,
            max_tokens: 1500,
            system: systemPrompt,
            messages: [{ role: "user", content: userMessage }],
        }),
    });

    if (!response.ok) {
        const errText = await response.text();
        throw new Error(`Anthropic API error (${response.status}): ${errText}`);
    }

    const data = await response.json();
    const text: string = data.content?.[0]?.text ?? "";
    const input_tokens: number = data.usage?.input_tokens ?? 0;
    const output_tokens: number = data.usage?.output_tokens ?? 0;
    const cost_usd =
        (input_tokens / 1_000_000) * ANTHROPIC_INPUT_COST_PER_MTOK +
        (output_tokens / 1_000_000) * ANTHROPIC_OUTPUT_COST_PER_MTOK;

    return { text, input_tokens, output_tokens, cost_usd };
}

// ─────────────────────────────────────────────────────────────────────
// MAIN HANDLER
// ─────────────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
    if (req.method === "OPTIONS") {
        return new Response(null, { status: 204, headers: corsHeaders });
    }

    if (req.method !== "POST") {
        return json({ error: "Method not allowed" }, 405);
    }

    try {
        // ── Auth: JWT richiesto (admin o cliente self-service) ────────
        const authHeader = req.headers.get("Authorization");
        if (!authHeader?.startsWith("Bearer ")) {
            return json({ error: "Missing or invalid Authorization header" }, 401);
        }
        const token = authHeader.slice("Bearer ".length).trim();

        const { data: authData, error: authErr } = await supabase.auth.getUser(token);
        if (authErr || !authData.user) {
            return json({ error: "Invalid token" }, 401);
        }

        const callerUserId = authData.user.id;
        // Ruolo e org del chiamante derivati da org_members. NON usare
        // app_metadata.role: nello schema SaaS quel claim non esiste (l'auth hook
        // inietta org_role nel JWT, ma getUser() ritorna i raw metadata, senza i
        // claim arricchiti). Lo scoping org qui sotto impedisce a un admin della org A
        // di generare/leggere il report di un cliente della org B (data-leak #1).
        const { data: callerMember } = await supabase
            .from("org_members")
            .select("org_id, role")
            .eq("user_id", callerUserId)
            .eq("status", "active")
            .maybeSingle();
        const isAdmin = ["owner", "admin"].includes(callerMember?.role ?? "");
        // org del chiamante: staff/admin da org_members, cliente self-service da profiles.
        let callerOrgId = callerMember?.org_id ?? null;
        if (!callerOrgId) {
            const { data: callerProfile } = await supabase
                .from("profiles")
                .select("org_id")
                .eq("id", callerUserId)
                .maybeSingle();
            callerOrgId = callerProfile?.org_id ?? null;
        }

        // ── Parse body ────────────────────────────────────────────────
        let body: any;
        try {
            body = await req.json();
        } catch {
            return json({ error: "Invalid JSON body" }, 400);
        }

        const {
            user_id,
            year_month,
            tone: toneOverride,
            skip_consent_check = false,
            force_regenerate = false,
        } = body;

        if (!user_id || !year_month) {
            return json({ error: "Missing required fields: user_id, year_month" }, 400);
        }
        if (!/^\d{4}-(0[1-9]|1[0-2])$/.test(year_month)) {
            return json({ error: "Invalid year_month format, expected YYYY-MM" }, 400);
        }

        // ── Autorizzazione ────────────────────────────────────────────
        // Il chiamante deve appartenere a una org. Self-service: un cliente può
        // generare SOLO il proprio report; l'admin può generarlo per chiunque
        // nella propria org (il target è poi verificato per org_id più sotto).
        if (!callerOrgId) {
            return json({
                error: "Forbidden: chiamante senza org",
                code: "NO_ORG",
            }, 403);
        }
        const isSelfService = !isAdmin && user_id === callerUserId;
        if (!isAdmin && !isSelfService) {
            return json({
                error: "Forbidden: puoi generare solo il tuo report",
                code: "NOT_AUTHORIZED_FOR_USER",
            }, 403);
        }
        // skip_consent_check è un flag riservato all'admin (bypassa il consenso GDPR).
        if (!isAdmin && skip_consent_check) {
            return json({
                error: "skip_consent_check riservato all'admin",
                code: "ADMIN_ONLY_FLAG",
            }, 403);
        }

        // Self-service: si può generare solo un report di un mese già concluso.
        if (isSelfService) {
            const now = new Date();
            const currentYM = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}`;
            if (year_month >= currentYM) {
                return json({
                    error: "Puoi generare solo report di mesi già conclusi",
                    code: "MONTH_NOT_AVAILABLE",
                    current_month: currentYM,
                    requested_month: year_month,
                }, 400);
            }
        }

        // ── Carica profilo utente target ──────────────────────────────
        const { data: profile, error: profErr } = await supabase
            .from("profiles")
            .select("id, name, email, report_tone_preference, report_ai_consent")
            .eq("id", user_id)
            .eq("org_id", callerOrgId)   // il target DEVE appartenere alla org del chiamante
            .single();

        if (profErr || !profile) {
            return json({ error: "User not found", code: "USER_NOT_FOUND" }, 404);
        }

        // ── GDPR: verifica consenso AI ────────────────────────────────
        // Il consenso è obbligatorio sia in self-service sia quando l'admin genera
        // per un cliente; l'admin può bypassarlo solo con skip_consent_check.
        if (!profile.report_ai_consent && !skip_consent_check) {
            return json({
                error: `L'utente ${profile.name ?? user_id} non ha dato il consenso AI`,
                code: "CONSENT_REQUIRED",
                user_name: profile.name,
            }, 403);
        }

        // ── Determina tono effettivo ──────────────────────────────────
        const tone: string = toneOverride ?? profile.report_tone_preference ?? "motivational";
        if (!["serious", "motivational", "ironic"].includes(tone)) {
            return json({ error: `Invalid tone: ${tone}` }, 400);
        }

        // ── Idempotenza: se esiste già e non è force_regenerate, ritorna il più recente
        if (!force_regenerate) {
            const { data: existingList } = await supabase
                .from("monthly_reports")
                .select("id, status, narrative, scorecard, cost_usd, tone, generated_at, model_used")
                .eq("org_id", callerOrgId)
                .eq("user_id", user_id)
                .eq("year_month", year_month)
                .eq("status", "generated")
                .order("generated_at", { ascending: false })
                .limit(1);

            const existing = existingList?.[0];
            if (existing) {
                return json({
                    success: true,
                    status: "existing",
                    report_id: existing.id,
                    tone: existing.tone,
                    narrative: existing.narrative,
                    scorecard: existing.scorecard,
                    cost_usd: existing.cost_usd,
                    generated_at: existing.generated_at,
                    model_used: existing.model_used,
                    message: "Report già generato per questo mese. Usa force_regenerate=true per rigenerare.",
                });
            }
        }

        // ── Rate limit: max 3 report con status='generated' per (user, year_month)
        // Non conta i 'failed' (potrebbero essere stati errori AI non attribuibili all'utente).
        // Vale per TUTTI i non-admin (non solo su force_regenerate): difesa-in-profondità.
        // Di fatto un non-admin genera ex-novo solo con force_regenerate (l'idempotenza
        // sopra ritorna l'esistente), ma non ci affidiamo a quello. Admin bypassa (testing/supporto).
        if (!isAdmin) {
            const { count: existingCount } = await supabase
                .from("monthly_reports")
                .select("id", { count: "exact", head: true })
                .eq("org_id", callerOrgId)
                .eq("user_id", user_id)
                .eq("year_month", year_month)
                .eq("status", "generated");

            if ((existingCount ?? 0) >= 3) {
                return json({
                    error: "Hai raggiunto il limite massimo di 3 generazioni per questo mese.",
                    code: "REGEN_LIMIT_REACHED",
                    limit: 3,
                    current_count: existingCount,
                }, 429);
            }
        }

        // ── Calcola scorecard via RPC SQL ─────────────────────────────
        const { data: scorecard, error: scErr } = await supabase.rpc(
            "generate_monthly_scorecard",
            { p_user_id: user_id, p_year_month: year_month },
        );

        if (scErr || !scorecard) {
            return json({
                error: `Scorecard generation failed: ${scErr?.message ?? "unknown"}`,
                code: "SQL_ERROR",
            }, 500);
        }

        const reportType: string = scorecard.metadata?.report_type ?? "full";
        const userName: string = profile.name ?? "Cliente";

        // ── Costruisci prompt ─────────────────────────────────────────
        const systemPrompt = buildSystemPrompt(tone, reportType);
        const userMessage = buildUserMessage(scorecard, userName);

        // ── Chiama Anthropic API ─────────────────────────────────────
        let aiResult: AnthropicResult;
        try {
            aiResult = await callAnthropic(systemPrompt, userMessage);
        } catch (e) {
            const errMsg = e instanceof Error ? e.message : String(e);
            console.error("Anthropic call failed:", errMsg);

            // Salva comunque una riga 'failed' per tracciabilità (INSERT, non upsert:
            // i tentativi falliti non sovrascrivono i report precedenti.)
            await supabase.from("monthly_reports").insert({
                org_id: callerOrgId,       // NOT NULL — scoping per org (M2)
                user_id,
                year_month,                // la migration 15 ha rinominato month → year_month
                tone,
                scorecard,
                status: "failed",
                error_message: errMsg,
                generated_at: null,
            });

            return json({
                error: `AI call failed: ${errMsg}`,
                code: "AI_ERROR",
            }, 502);
        }

        // ── Salva risultato in DB (INSERT per permettere multiple generazioni)
        const { data: saved, error: saveErr } = await supabase
            .from("monthly_reports")
            .insert({
                org_id: callerOrgId,       // NOT NULL — scoping per org (M2)
                user_id,
                year_month,                // la migration 15 ha rinominato month → year_month
                tone,
                scorecard,
                narrative: aiResult.text,
                status: "generated",
                model_used: ANTHROPIC_MODEL,
                input_tokens: aiResult.input_tokens,
                output_tokens: aiResult.output_tokens,
                cost_usd: aiResult.cost_usd,
                generated_at: new Date().toISOString(),
                error_message: null,
            })
            .select()
            .single();

        if (saveErr) {
            console.error("Save failed:", saveErr);
            return json({
                error: `Save failed: ${saveErr.message}`,
                code: "SAVE_ERROR",
                narrative: aiResult.text, // ritorna comunque il testo, così admin non perde il lavoro
            }, 500);
        }

        // ── Risposta OK ──────────────────────────────────────────────
        return json({
            success: true,
            status: "generated",
            report_id: saved.id,
            tone,
            report_type: reportType,
            user_name: userName,
            narrative: aiResult.text,
            scorecard,
            tokens: {
                input: aiResult.input_tokens,
                output: aiResult.output_tokens,
            },
            cost_usd: aiResult.cost_usd,
            model_used: ANTHROPIC_MODEL,
        });

    } catch (e) {
        console.error("generate-monthly-report unexpected error:", e);
        const errMsg = e instanceof Error ? e.message : String(e);
        return json({ error: errMsg, code: "UNEXPECTED" }, 500);
    }
});
