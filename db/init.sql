-- VIVFY Transaction Engine — initial schema with Row-Level Security
--
-- Loaded by Postgres on first container start via /docker-entrypoint-initdb.d.
-- This script creates the schema once on a fresh volume. To re-run, recreate the
-- volume: `docker compose down -v && docker compose up -d`.
--
-- Design notes:
--   * Every multi-tenant table carries tenant_id and has RLS enabled.
--   * The application sets `app.tenant_id` per transaction via
--     SELECT set_config('app.tenant_id', $1, true);
--   * `current_setting('app.tenant_id', true)` returns NULL when unset, which
--     causes the policy to deny all rows — the desired default-deny behavior.
--   * cart_items and order_items inherit isolation through their parent rows
--     (carts, orders) via RLS on the parent + Prisma joins.
--   * webhook_inbox is intentionally NOT multi-tenant: webhooks land here
--     before tenant context is established, then are dispatched to the
--     correct tenant by metadata.

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

------------------------------------------------------------
-- Core tenant table (no RLS — used to look up tenants)
------------------------------------------------------------
CREATE TABLE tenants (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

------------------------------------------------------------
-- Products (physical inventory)
------------------------------------------------------------
CREATE TABLE products (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  unit_price  INTEGER NOT NULL CHECK (unit_price >= 0),
  stock_count INTEGER NOT NULL DEFAULT 0 CHECK (stock_count >= 0),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_products_tenant_id ON products(tenant_id);

------------------------------------------------------------
-- Events (ticketed events)
------------------------------------------------------------
CREATE TABLE events (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  name              TEXT NOT NULL,
  unit_price        INTEGER NOT NULL CHECK (unit_price >= 0),
  available_tickets INTEGER NOT NULL DEFAULT 0 CHECK (available_tickets >= 0),
  starts_at         TIMESTAMPTZ NOT NULL,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_events_tenant_id ON events(tenant_id);

------------------------------------------------------------
-- Carts and cart items
------------------------------------------------------------
CREATE TABLE carts (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  status        TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending', 'paid', 'failed')),
  total_amount  INTEGER NOT NULL CHECK (total_amount >= 0),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_carts_tenant_id ON carts(tenant_id);

CREATE TABLE cart_items (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cart_id     UUID NOT NULL REFERENCES carts(id) ON DELETE CASCADE,
  product_id  UUID REFERENCES products(id),
  event_id    UUID REFERENCES events(id),
  qty         INTEGER NOT NULL CHECK (qty > 0),
  unit_price  INTEGER NOT NULL CHECK (unit_price >= 0),
  CONSTRAINT cart_items_product_xor_event
    CHECK ((product_id IS NOT NULL)::int + (event_id IS NOT NULL)::int = 1)
);
CREATE INDEX idx_cart_items_cart_id ON cart_items(cart_id);

------------------------------------------------------------
-- Orders (created post-settlement)
------------------------------------------------------------
CREATE TABLE orders (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  cart_id       UUID NOT NULL UNIQUE REFERENCES carts(id),
  total_amount  INTEGER NOT NULL CHECK (total_amount >= 0),
  status        TEXT NOT NULL DEFAULT 'settled'
                  CHECK (status IN ('settled', 'failed_no_stock', 'failed_other')),
  settled_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_orders_tenant_id ON orders(tenant_id);

CREATE TABLE order_items (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id    UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  product_id  UUID REFERENCES products(id),
  event_id    UUID REFERENCES events(id),
  qty         INTEGER NOT NULL CHECK (qty > 0),
  unit_price  INTEGER NOT NULL CHECK (unit_price >= 0),
  CONSTRAINT order_items_product_xor_event
    CHECK ((product_id IS NOT NULL)::int + (event_id IS NOT NULL)::int = 1)
);
CREATE INDEX idx_order_items_order_id ON order_items(order_id);

------------------------------------------------------------
-- Tickets (issued post-settlement, one per ticket qty)
------------------------------------------------------------
CREATE TABLE tickets (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  order_id    UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  event_id    UUID NOT NULL REFERENCES events(id),
  code        TEXT NOT NULL UNIQUE,
  status      TEXT NOT NULL DEFAULT 'valid'
                CHECK (status IN ('valid', 'used', 'refunded')),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_tickets_tenant_id ON tickets(tenant_id);
CREATE INDEX idx_tickets_order_id ON tickets(order_id);

------------------------------------------------------------
-- Webhook inbox (single source of truth for idempotency)
------------------------------------------------------------
CREATE TABLE webhook_inbox (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id  TEXT NOT NULL UNIQUE,
  payload         JSONB NOT NULL,
  received_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  processed_at    TIMESTAMPTZ,
  status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'processed', 'failed', 'rejected')),
  error_message   TEXT
);
CREATE INDEX idx_webhook_inbox_status ON webhook_inbox(status)
  WHERE status = 'pending';

------------------------------------------------------------
-- Row-Level Security
--
-- Strategy: enable RLS on every multi-tenant table. A query that runs
-- without app.tenant_id set returns zero rows (the policy compares
-- tenant_id::text against NULL, which is never true). A query that runs
-- with app.tenant_id set returns only rows for that tenant.
--
-- The DB owner (the role that runs migrations) bypasses RLS by default
-- in Postgres, which is what we want for setup. The application role
-- (used by the running NestJS app) does NOT bypass.
------------------------------------------------------------
ALTER TABLE products ENABLE ROW LEVEL SECURITY;
ALTER TABLE events   ENABLE ROW LEVEL SECURITY;
ALTER TABLE carts    ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders   ENABLE ROW LEVEL SECURITY;
ALTER TABLE tickets  ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON products
  USING (tenant_id::text = current_setting('app.tenant_id', true));

CREATE POLICY tenant_isolation ON events
  USING (tenant_id::text = current_setting('app.tenant_id', true));

CREATE POLICY tenant_isolation ON carts
  USING (tenant_id::text = current_setting('app.tenant_id', true));

CREATE POLICY tenant_isolation ON orders
  USING (tenant_id::text = current_setting('app.tenant_id', true));

CREATE POLICY tenant_isolation ON tickets
  USING (tenant_id::text = current_setting('app.tenant_id', true));

------------------------------------------------------------
-- Force RLS for the table owner.
--
-- By default, Postgres lets table owners bypass RLS. FORCE applies the
-- policies to owners too. This still does NOT apply to superusers — they
-- bypass RLS unconditionally — which is why the application uses a
-- non-superuser role (see vivfy_app below).
------------------------------------------------------------
ALTER TABLE products FORCE ROW LEVEL SECURITY;
ALTER TABLE events   FORCE ROW LEVEL SECURITY;
ALTER TABLE carts    FORCE ROW LEVEL SECURITY;
ALTER TABLE orders   FORCE ROW LEVEL SECURITY;
ALTER TABLE tickets  FORCE ROW LEVEL SECURITY;

------------------------------------------------------------
-- Application role.
--
-- This role is what the NestJS app (and the test suite) connects as.
-- It is intentionally NOT a superuser so that RLS policies actually
-- apply. The migration owner (the user that ran this script) keeps its
-- elevated privileges for schema changes; runtime traffic uses vivfy_app.
------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vivfy_app') THEN
    CREATE ROLE vivfy_app WITH LOGIN PASSWORD 'vivfy_app';
  END IF;
END $$;

GRANT USAGE ON SCHEMA public TO vivfy_app;

GRANT SELECT, INSERT, UPDATE, DELETE
  ON ALL TABLES IN SCHEMA public TO vivfy_app;

GRANT USAGE, SELECT
  ON ALL SEQUENCES IN SCHEMA public TO vivfy_app;

-- Without TRUNCATE the test suite cannot reset state. TRUNCATE bypasses
-- RLS, which is the documented Postgres behavior we rely on for cleanup.
GRANT TRUNCATE ON
  tenants, products, events, carts, cart_items,
  orders, order_items, tickets, webhook_inbox TO vivfy_app;

-- Future tables added in later migrations automatically pick up the
-- same grants.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO vivfy_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO vivfy_app;
