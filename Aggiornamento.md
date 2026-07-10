# Aggiornamento

Changelog delle modifiche **nate in PalestrIA** (non portate dal gemello Thomas), da
**duplicare su un altro progetto simile**. Voci nuove in cima. Ogni voce ha descrizione +
una *Parte tecnica* autosufficiente (file, identificatori, prima/dopo, deploy).

> Vedi `CLAUDE.md` §0.2 per la regola. Per le modifiche **portate da** Thomas vedi invece il
> suo `Aggiornamenti.md` (collegato da `Aggiornamenti Thomas.md.lnk`).

---

<!-- Le prossime voci vanno qui, in cima. -->

## 2026-07-08 — Profilo cliente: sezioni Prossime/Passate/Transazioni + tab Prenotazioni ridotto al solo calendario

**Problema/feature.** Nell'area cliente il tab "Prenotazioni" conteneva due sotto-viste (pill-bar *Calendario* + *Le mie*). Richiesta: (1) togliere la pill-bar → il tab Prenotazioni mostra **solo il calendario**; (2) spostare l'elenco "Le mie" **dentro il Profilo**; (3) nel Profilo tre sezioni **Prossime / Passate / Transazioni** (queste ultime = storico pagamenti del cliente); (4) rimuovere dal Profilo il "recap dati" personali; (5) mostrare **Nome e Cognome** (non solo il nome) nel Profilo.

La sezione **Transazioni** è la novità portabile: legge il **ledger unico `payments`** filtrando le sole righe del cliente. La RLS di `payments` deve consentire la lettura al cliente delle proprie righe:
```sql
-- policy attesa su payments (baseline PalestrIA):
create policy payments_select on payments for select to authenticated
  using (org_id = current_org_id() and (client_user_id = auth.uid() or is_org_admin(org_id)));
```
Colonne usate: `id, amount, currency, method, kind, created_at, note, period_start, period_end`.
- `kind` ∈ `session|membership|package_purchase|penalty_mora|adjustment` → etichette *Lezione/Abbonamento/Pacchetto/Mora/Rettifica*.
- `method` ∈ `contanti|contanti-report|carta|iban|stripe|gratuito` → etichette con emoji (💵/🧾/💳/🏦/💳/🎁).

### Parte tecnica

**Web/PWA (fonte storica).**
1. In `prenotazioni.html` (pagina profilo cliente) aggiungere la terza tab accanto a Prossime/Passate:
   ```html
   <button class="preno-tab" id="tabTransazioni" onclick="switchPrenoTab('transactions')">Transazioni</button>
   ```
2. `switchPrenoTab(tab)`: aggiungere il toggle `active` su `#tabTransazioni` e il branch `if (tab==='transactions') renderTransactions(); else renderPrenoList();`. Idem in `showMore()` (branch su `_currentTab`).
3. Nuove funzioni JS (client-side, la RLS limita alle proprie righe):
   ```js
   let _paymentsCache = null;
   const _fmtTxDate = d => { if(!d) return ''; const s=String(d).slice(0,10).split('-'); return s.length===3?`${s[2]}/${s[1]}/${s[0]}`:d; };
   async function _ensurePayments(){ if(_paymentsCache) return _paymentsCache; const u=getCurrentUser(); if(!u) return (_paymentsCache=[]);
     const {data,error}=await supabaseClient.from('payments')
       .select('id, amount, currency, method, kind, created_at, note, period_start, period_end')
       .eq('client_user_id', u.id).order('created_at',{ascending:false}).limit(200);
     _paymentsCache = error ? [] : (data||[]); return _paymentsCache; }
   async function renderTransactions(){ /* lazy-load + slice(_visibleCount) + map(buildTransactionCard) + "Mostra altro" */ }
   function buildTransactionCard(p){ /* card .preno-card con border-left-color per kind, badge importo, meta metodo/periodo/nota */ }
   ```
   Valuta: `OrgSettings.getString('locale.currency','EUR')` → simbolo `€` per EUR.
4. Invalidare `_paymentsCache=null` nel realtime full-sync (nuovo pagamento) e ri-renderizzare se la tab attiva è `transactions`.
5. (Opzionale, coerenza) hero: mostrare `user.name` completo invece di `user.name.split(' ')[0]`.
6. **Cache-busting**: bump `CACHE_NAME` in `sw.js` (qui v584→v585). `prenotazioni.html` è in `APP_SHELL` → il bump basta (JS inline).

**App Flutter (se presente).**
- `booking_screen.dart`: rimuovere la pill-bar; `body: const CalendarView()`. Eliminare `my_bookings_view.dart`.
- Estrarre la card prenotazione in `booking_card.dart` (`BookingCard{booking, config, showCancel}`) riusabile.
- `core/models/client_payment.dart`: modello `ClientPayment.fromRow` + `selectColumns`.
- `BookingRepository.fetchOwnPayments(userId)`: `from('payments').select(cols).eq('client_user_id',userId).order('created_at',desc).limit(200)`.
- `ownPaymentsProvider` (FutureProvider) accanto a `ownBookingsProvider`.
- `profile_screen.dart` → `ConsumerStatefulWidget` con pill-bar 3 tab (Prossime/Passate/Transazioni), paginazione `_visible` 5→+20; hero con nome completo; rimosso `_infoCard`; card transazione con colore bordo per `kind`.

