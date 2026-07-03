-- ──────────────────────────────────────────────────────────────────────────────
-- 00000000000025_profiles_block_self_email
--
-- Port (adattato al multi-tenant SaaS) di un fix della security review del gemello
-- Thomas Bresciani (2026-07-03): estende il trigger anti self-update
-- `_trg_profiles_block_self_admin_flags` (introdotto in 00000000000023) per bloccare
-- anche il cambio SELF della propria `profiles.email` verso un valore diverso.
--
-- Gli altri finding SQL del pacchetto gemello sono N/A qui:
--   • apply_credit_on_booking / apply_credit_to_past_bookings / fulfill_pending_cancellation
--     → sistema crediti RIMOSSO nel SaaS; il rimborso in cancellazione è già derivato
--       server-side da pacchetto/membership (cancel_booking), niente `p_slot_prices`,
--       nessun grant anon → nulla da revocare/clampare.
--   • book_slot_atomic identity spoofing → in PalestrIA `book_slot` usa `p_for_user_id`
--     già dietro il gate `is_org_admin` + verifica appartenenza org.
--
-- PERCHÉ. La policy `profiles_update` lascia al cliente aggiornare la PROPRIA riga
-- (id = auth.uid()) per i campi legittimamente self-owned (privacy_prenotazioni,
-- push_enabled, geo_enabled). Ma `profiles.email` è (org_id, email) UNIQUE ed è la
-- chiave con cui le prenotazioni guest vengono agganciate al profilo (stessa email +
-- org). Un cliente che via PostgREST cambia la propria email in quella di un altro
-- utente della org potrebbe reidentificarsi e agganciare prenotazioni non sue. Il
-- cambio email legittimo passa SEMPRE dai flussi admin (SECURITY DEFINER con caller
-- admin) o dal server (service_role, senza auth.uid()): quelli restano esenti.
--
-- Blocco MIRATO e non distruttivo (come per documento_firmato): reverte il valore solo
-- quando è un SELF-update (auth.uid() = old.id) di un NON-admin che cambia una email
-- già valorizzata. La prima assegnazione (old.email vuota) resta permessa; un update
-- legittimo che includa la colonna nel payload non va in errore, semplicemente non la
-- cambia.
--
-- `documento_firmato` (già coperto da 00000000000023) è lasciato INVARIATO.
-- Nota: `role` non esiste su `profiles` (vive in org_members) → nulla da bloccare lì.
--
-- Idempotente e rieseguibile: CREATE OR REPLACE della trigger function esistente (il
-- binding del trigger persiste); trigger e revoke ri-asseriti per robustezza.
-- ──────────────────────────────────────────────────────────────────────────────

create or replace function _trg_profiles_block_self_admin_flags()
returns trigger language plpgsql security definer set search_path = public as $$
begin
    -- documento_firmato: flag admin-only (invariato da 00000000000023).
    if new.documento_firmato is distinct from old.documento_firmato
       and not is_org_admin(old.org_id) then
        new.documento_firmato := old.documento_firmato;
    end if;

    -- email: un cliente non può cambiare da sé la propria email verso un valore diverso.
    -- Esenti: prima assegnazione (old.email vuota), admin della org, contesti server
    -- (service_role/definer → auth.uid() NULL, quindi `auth.uid() = old.id` è falso).
    if new.email is distinct from old.email
       and old.email is not null and btrim(old.email) <> ''
       and auth.uid() = old.id
       and not is_org_admin(old.org_id) then
        new.email := old.email;
    end if;

    return new;
end;
$$;

drop trigger if exists trg_profiles_block_self_admin_flags on profiles;
create trigger trg_profiles_block_self_admin_flags
    before update on profiles
    for each row execute function _trg_profiles_block_self_admin_flags();
-- Coerenza con l'hardening di 00000000000022: togli l'EXECUTE di default a public/anon.
-- Il trigger scatta comunque (le trigger function non richiedono EXECUTE); una chiamata
-- diretta via REST fallisce.
revoke all on function _trg_profiles_block_self_admin_flags() from public, anon;
