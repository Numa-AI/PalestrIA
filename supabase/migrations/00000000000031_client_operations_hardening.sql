-- Trainer SaaS operations hardening: idempotent billing, financial health,
-- safe schedule overrides and auditable client lifecycle operations.

alter table payments add column if not exists idempotency_key text;
create unique index if not exists payments_org_idempotency_uidx
  on payments (org_id, idempotency_key)
  where idempotency_key is not null;
