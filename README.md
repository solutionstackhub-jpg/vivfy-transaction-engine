# VIVFY Transaction Engine

Reference implementation for the unified commerce checkout problem: multi-tenant data isolation, idempotent webhook processing, concurrency control under contention, and atomic settlement of a bundle that mixes physical inventory with an event ticket.

This README documents the architecture and the reasoning behind each decision before production code is written. The 4-week implementation plan is at the bottom.

## The problem

A single cart can contain a physical product (limited stock, must not oversell) and an event ticket (must persist a ticket row and later render a QR code). Payment confirmation arrives as a webhook from Paytime:

```json
{
  "transaction_id": "txn_01HX...",
  "status": "paid",
  "amount": 12990,
  "metadata": {
    "cart_id": "cart_01HX...",
    "tenant_id": "tenant_01HX..."
  }
}
```

Three properties must hold:

1. The same webhook delivered twice produces exactly one stock decrement and one ticket.
2. When 50 buyers race for the last unit of an item, exactly one wins and the rest fail cleanly. Stock never goes negative.
3. The bundle settles atomically. Either the stock is decremented and the ticket exists, or neither happens.

And throughout: data from one tenant never reaches another, regardless of application-level bugs.

## Architecture at a glance

The pipeline splits into a fast synchronous edge and an asynchronous settlement worker.

```
Paytime ──webhook──▶ POST /webhooks/paytime
                          │
                          │  INSERT INTO webhook_inbox (transaction_id, payload, received_at)
                          │  ON CONFLICT (transaction_id) DO NOTHING RETURNING id
                          ▼
                     respond 200 OK   (target: under 50 ms)
                          │
                          │  if a new row was inserted, enqueue settle-checkout(inbox_id)
                          ▼
                     BullMQ: settle-checkout
                          │
                          ▼
                  Settlement worker
                          │
                          │  BEGIN
                          │    SET LOCAL app.tenant_id = $1
                          │    SELECT FOR UPDATE inventory rows in product_id order
                          │    validate stock for every bundle item
                          │    UPDATE inventory SET stock = stock - qty
                          │    INSERT order, order_items, tickets
                          │  COMMIT
                          ▼
                  After commit (best effort):
                    enqueue render-qr(ticket_id)
                    enqueue notify-buyer(order_id)
```

The rule that drives the layout: anything that must be atomic with the stock decrement lives inside the transaction. Anything that is a pure side effect lives after the commit. The ticket's source of truth is the row in `tickets`. The QR image is just a rendering of `tickets.code` and can be regenerated at any time.

## Five decisions

### 1. Idempotency via a database inbox, not application checks

The webhook handler runs one statement and returns:

```sql
INSERT INTO webhook_inbox (transaction_id, payload, received_at)
VALUES ($1, $2, now())
ON CONFLICT (transaction_id) DO NOTHING
RETURNING id;
```

If `RETURNING id` yields a row, this is the first time we have seen the transaction and a settlement job is enqueued. If it yields nothing, the row already exists and we do not enqueue. Duplicates die at the unique constraint instead of in business logic.

Application-level "if exists then update" has a TOCTOU window: two duplicate webhooks arriving within microseconds can both read "not exists" and both insert. Pushing the check into a unique constraint makes the database the arbiter, which is the only place that does not race with itself.

The job payload references `webhook_inbox.id`, not the raw webhook body. If the worker crashes mid-job and BullMQ retries it, the worker re-reads the inbox row and proceeds deterministically. The body lives in one place, version-controlled by its inbox row, never copy-pasted into the queue.

### 2. Tenant isolation at the engine, not in every query

Every tenant table carries `tenant_id` and has Row-Level Security on:

```sql
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON orders
  USING (tenant_id = current_setting('app.tenant_id')::uuid);
```

A Prisma middleware issues `SET LOCAL app.tenant_id = $1` at the start of every transaction, sourced from validated request context. A query that forgets to filter by tenant simply returns zero rows. A bug cannot leak data across tenants, because the engine refuses to surface cross-tenant rows.

The webhook metadata also carries `tenant_id`. Before the worker sets `app.tenant_id`, it loads the cart by `cart_id` and asserts `metadata.tenant_id == cart.tenant_id`. A spoofed webhook with a mismatched tenant fails fast and the inbox row is marked as rejected.

The test suite includes a leak test that runs a query without setting `app.tenant_id` and asserts zero rows returned. If RLS is ever weakened, that test goes red.

### 3. Pessimistic locking on the contended path

Optimistic locking with a version column works when conflicts are rare. With 50 buyers racing for the last unit, conflict is the norm and optimistic retries turn into a thundering herd. Pessimistic locking serializes them with no application-side retry loop:

```sql
SELECT product_id, stock_count
FROM inventory
WHERE tenant_id = current_setting('app.tenant_id')::uuid
  AND product_id = ANY($1)
ORDER BY product_id ASC          -- deterministic lock order
FOR UPDATE;
```

The `ORDER BY product_id ASC` matters. A bundle that locks items in a different order from another concurrent bundle risks a deadlock that Postgres will resolve by killing one transaction. Always locking in `product_id` order across the codebase removes the entire class of bug. It is a single discipline applied consistently, not a coordination protocol between workers.

### 4. Bundle atomicity by transaction scope, not by saga

The bundle "physical product plus ticket" sits inside one `BEGIN ... COMMIT` block:

```
BEGIN
  SET LOCAL app.tenant_id = $tenant
  SELECT FOR UPDATE inventory rows for all bundle items (product_id order)
  for each item:
    if stock_count < requested: raise InsufficientStock
  UPDATE inventory SET stock_count = stock_count - requested
  INSERT INTO orders (...)
  INSERT INTO order_items (...)
  INSERT INTO tickets (code, status='valid', ...)
COMMIT
```

If any step raises, the entire transaction rolls back. The buyer enters the refund flow (a separate concern, separate queue). The buyer does not end up with a paid order that has stock taken but no ticket, nor with a ticket but no stock movement.

A saga would be the right tool if inventory and tickets lived in different databases or different vendors. Here both live in the same Postgres. Introducing a saga adds compensating actions, retries, and at-least-once semantics for no real gain. A transaction is the smaller hammer that fits.

QR image generation explicitly does not sit inside the transaction. The ticket row exists after commit, the PNG is rendered asynchronously from `tickets.code`, and if rendering fails the ticket is still valid and the PNG can be regenerated on demand.

### 5. The webhook responds before the work starts

The handler does the inbox insert, optionally enqueues a job, and returns 200. Total budget: under 50 ms. Paytime sees a fast acknowledgement and stops retrying, which keeps duplicate volume low in the first place.

Everything slower than a single insert runs in the worker. If the worker is slow or the queue backs up, Paytime is not waiting. If the worker process dies mid-transaction, Postgres rolls the transaction back, the inbox row stays with `processed_at IS NULL`, and a recovery worker picks it up.

## Walking through 50 buyers on the last unit

Stock on product P starts at 10. Fifty buyers complete payment within the same millisecond and Paytime fires 50 distinct webhooks (different `transaction_id` values, all pointing at carts that contain P).

```
t = 0       50 webhooks arrive at /webhooks/paytime
t = 1 ms    50 inbox inserts succeed (different transaction_ids)
            50 settle-checkout jobs enqueued
            50 × 200 OK returned to Paytime
t = 2 ms    Workers pick up jobs (parallelism capped by BullMQ concurrency)
t = 3 ms    Worker A acquires FOR UPDATE on inventory row for P
            Workers B..N queue on the lock
t = 8 ms    Worker A: stock 10 → 9, INSERT order/ticket, COMMIT
t = 9 ms    Worker B acquires the lock, sees stock 9, decrements to 8, COMMIT
...
t = 80 ms   Worker J acquires the lock, sees stock 1, decrements to 0, COMMIT
t = 81 ms   Worker K acquires the lock, sees stock 0
            raises InsufficientStock, ROLLBACK
            mark inbox row as failed-no-stock, enqueue refund
...
t ~ 400 ms  Last worker rolls back, last refund queued
```

End state: 10 orders settled, 40 cleanly failed and routed to refund, zero oversold units, zero cross-tenant access. The lock window per worker is small (one SELECT, one UPDATE, three INSERTs on indexed rows), so total wall time stays well under a second even under full contention.

The unit test for this scenario fires 50 concurrent settlement attempts against a seeded stock of 10 and asserts `final_stock = 0`, `successful_orders = 10`, `failed_with_no_stock = 40`.

## Failure modes covered

- Duplicate webhook from Paytime — blocked by the `webhook_inbox.transaction_id` unique constraint.
- A forgotten `tenant_id` filter in a query — blocked by the RLS policy, returns zero rows.
- Webhook with spoofed `metadata.tenant_id` — blocked by cross-validation against `cart.tenant_id`.
- Two bundles racing for the same inventory — serialized by `SELECT FOR UPDATE`.
- Two bundles locking shared items in different orders — prevented by always locking in `product_id` ASC.
- Stock decrement succeeds but ticket insert fails — full transaction rolls back, no partial settlement.
- Worker crashes mid-transaction — Postgres rolls back, inbox row remains unprocessed, recovery worker retries.
- QR generation fails after commit — ticket row already exists, generation is retried independently.
- Paytime keeps retrying because we are slow — handler is under 50 ms, retries stay rare.

## Stack

- NestJS, TypeScript
- PostgreSQL with RLS, Prisma ORM
- Redis with BullMQ for the settlement queue and the QR/notification queues
- Docker Compose for the local environment

## Local environment

```bash
cp .env.example .env       # uses vivfy_app role (non-superuser; see below)
docker compose up -d       # postgres + redis with healthchecks
npm install
npx prisma generate
npm test                   # currently runs the tenant-leak suite
npm run start:dev          # boots the API on :3000 with GET /health
```

The Postgres container loads `db/init.sql` from `docker-entrypoint-initdb.d` on first start. That script creates the schema, enables and forces RLS on every multi-tenant table, and provisions two roles: `vivfy` (superuser, owns the tables) and `vivfy_app` (non-superuser, what the app and tests connect as). The split matters because Postgres superusers bypass RLS unconditionally — without a dedicated non-superuser role, the policies look enforced but are not.

The leak test seeds two tenants in `beforeAll` and asserts that queries from tenant A cannot read, update, or delete tenant B's rows, and that queries without a tenant context return nothing at all.

## Status and weekly plan

- [x] Architecture decisions documented (this README)
- [x] Week 1: Docker Compose + Prisma schema + RLS policies + tenant-leak test
- [ ] Week 2: Settlement worker + `SELECT FOR UPDATE` + 50-concurrent oversell test
- [ ] Week 3: Webhook inbox + BullMQ wiring + duplicate-webhook test (same event x10, one effect)
- [ ] Week 4: Sequence diagram, runbook, commit-history cleanup

Commits land weekly. The repository is readable at every stage, not only at the end.

## Open questions

Two items that change implementation details, not direction:

1. On `InsufficientStock`, should the worker call a Paytime refund endpoint directly, or enqueue a refund job and treat the actual Paytime call as out of scope for this challenge?
2. Should the worker assert that `sum(order_items.unit_price * qty) == webhook.amount` and reject mismatches, or trust the webhook?

Both have defensible answers. If you do not have a preference, I will pick a default and document the choice in the relevant commit.
