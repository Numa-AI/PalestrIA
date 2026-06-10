# Lessons — PalestrIA

## 2026-06-09 — Encoding UTF-8 con PowerShell (Windows PS 5.1)
**Errore:** ho fatto un find-replace dei `?v=` su tutti gli `*.html` con `Get-Content -Raw` + `[IO.File]::WriteAllText(...UTF8)`. In Windows PowerShell 5.1 `Get-Content -Raw` legge i file UTF-8 SENZA BOM come ANSI (Windows-1252), corrompendo ogni carattere multibyte (en-dash `–` → `â€“`, emoji `🎬` → `ðŸŽ¬`). Il successivo WriteAllText UTF-8 ha persistito il mojibake.

**Regola:** per modificare file di testo UTF-8 via PowerShell, leggere SEMPRE con `[System.IO.File]::ReadAllText($p)` (auto-detect, default UTF-8) e scrivere con `[System.IO.File]::WriteAllText($p, $c, (New-Object System.Text.UTF8Encoding $false))`. MAI `Get-Content -Raw`/`Set-Content` per contenuti con accenti/emoji. Meglio ancora: usare il tool **Edit** per modifiche puntuali (preserva i byte non toccati). Per bulk-replace su molti file, il loop .NET ReadAllText/WriteAllText è l'unico modo sicuro.

**Recupero:** `git checkout -- <files>` per ripristinare i byte originali, poi riapplicare le modifiche legittime con Edit (per i file con anche altre modifiche non committate, riapplicarle a mano dopo il checkout).

## 2026-06-09 — Edge Functions service-role: scoping org obbligatorio
Le edge function che usano `SUPABASE_SERVICE_ROLE_KEY` bypassano la RLS: DEVONO validare il Bearer (`supabase.auth.getUser(token)`), derivare la org dal chiamante (mai dal body) e filtrare `org_id` su OGNI query. `verify_jwt=true` garantisce solo un JWT valido qualsiasi, NON il ruolo né il tenant. Pattern di riferimento corretto: `notify-admin-booking`.

## 2026-06-09 — Diff su cache mutata in place
`replaceAllBookings` confronta `[...this._cache]` (shallow, stessi riferimenti) con l'array passato. Se il chiamante muta gli oggetti in place e ripassa lo stesso array, il diff è SEMPRE vuoto → nessuna sync. Regola: i mutatori di cache devono creare NUOVI oggetti (`{...b, ...patch}`) per le entry modificate, lasciando intatti gli originali nella cache fino alla sostituzione.
