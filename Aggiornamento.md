# Aggiornamento

Changelog delle modifiche **nate in PalestrIA** (non portate dal gemello Thomas), da
**duplicare su un altro progetto simile**. Voci nuove in cima. Ogni voce ha descrizione +
una *Parte tecnica* autosufficiente (file, identificatori, prima/dopo, deploy).

> Vedi `CLAUDE.md` §0.2 per la regola. Per le modifiche **portate da** Thomas vedi invece il
> suo `Aggiornamenti.md` (collegato da `Aggiornamenti Thomas.md.lnk`).

---

## 2026-06-22 — Fix CI: il seed non deve dipendere da tabelle di migration post-baseline

**Descrizione.** Il job CI **"Validate baseline migration"** (`.github/workflows/ci.yml`) era
rosso dal 2026-06-19 allo step `supabase db start`. Causa: il job valida la baseline **in
isolamento** (sposta tutte le migration tranne `00000000000000_baseline.sql` in `/tmp`, poi
applica **baseline + seed PRIMA** delle altre migration). Il `seed.sql` però faceva
`INSERT INTO activated_weeks`, tabella creata da una migration **post-baseline**
(`00000000000020_per_week_activation.sql`) → a quel punto inesistente → errore, step
successivi skippati. In un `supabase db reset` locale completo non si vedeva, perché lì
tutte le migration vengono applicate prima del seed.

**Parte tecnica.**

1. **`supabase/seed.sql`** — guard di esistenza tabella sul blocco di attivazione settimane.
   La tabella `activated_weeks` nasce in una migration post-baseline, quindi in CI può non
   esistere quando gira il seed.
   - Prima:
     ```sql
     if v_tpl is not null then
         for v_wd in 0..3 loop
             insert into activated_weeks (org_id, week_start, template_id)
             values (v_org, (date_trunc('week', now())::date + (v_wd * 7)), v_tpl)
             on conflict (org_id, week_start) do nothing;
         end loop;
     end if;
     ```
   - Dopo (aggiunto `to_regclass`; in baseline-only si salta senza errore):
     ```sql
     if v_tpl is not null and to_regclass('public.activated_weeks') is not null then
         for v_wd in 0..3 loop
             insert into activated_weeks (org_id, week_start, template_id)
             values (v_org, (date_trunc('week', now())::date + (v_wd * 7)), v_tpl)
             on conflict (org_id, week_start) do nothing;
         end loop;
     end if;
     ```

2. **`tests/rls/cross_tenant.sql`** — stessa difesa + fedeltà al modello per-settimana. Dopo
   gli `insert` in `weekly_template_slots`, attiva la settimana del `2099-01-15` per le due
   org di test (guarded), usando per `week_start` la **stessa espressione** di
   `resolve_slot_config` (lunedì della settimana), così la capienza attesa (12) resta vera:
   ```sql
   if to_regclass('public.activated_weeks') is not null then
       insert into activated_weeks (org_id, week_start, template_id)
           values (v_org_a, date_trunc('week', date '2099-01-15'::timestamp)::date, v_tpl_a)
           on conflict (org_id, week_start) do nothing;
       insert into activated_weeks (org_id, week_start, template_id)
           values (v_org_b, date_trunc('week', date '2099-01-15'::timestamp)::date, v_tpl_b)
           on conflict (org_id, week_start) do nothing;
   end if;
   ```

3. **Nessun cache-bust** (file CI/DB di test, non asset frontend). Verifica: run CI verde su
   tutti e 3 i job, step 1-9 della baseline tutti `success`.

**Regola generale da portare** (vale per qualsiasi progetto con la stessa CI di
baseline-in-isolamento): se `seed.sql` (o un test SQL eseguito sul DB locale) scrive su una
tabella creata da una migration **dopo** la baseline, **proteggi il blocco** con
`if to_regclass('public.<tabella>') is not null then … end if;`, oppure consolida la tabella
nella baseline. Documentato in `CLAUDE.md` §12.
