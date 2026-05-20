/**
 * Tenant leak test — Week 1 deliverable.
 *
 * Verifies that Row-Level Security at the Postgres level prevents data
 * from one tenant ever being visible (or mutable) from another tenant's
 * context, including the case where the application forgets to set the
 * tenant context at all.
 *
 * Requires postgres running (docker compose up -d).
 */

import { Prisma, PrismaClient } from '@prisma/client';

const UUID_REGEX =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function withTenant<T>(
  prisma: PrismaClient,
  tenantId: string,
  fn: (tx: Prisma.TransactionClient) => Promise<T>,
): Promise<T> {
  if (!UUID_REGEX.test(tenantId)) {
    throw new Error(`Invalid tenantId: ${JSON.stringify(tenantId)}`);
  }
  return prisma.$transaction(async (tx) => {
    await tx.$executeRaw`SELECT set_config('app.tenant_id', ${tenantId}, true)`;
    return fn(tx);
  });
}

describe('tenant leak (RLS)', () => {
  const prisma = new PrismaClient();

  let tenantA: string;
  let tenantB: string;
  let productA: string;
  let productB: string;

  beforeAll(async () => {
    await prisma.$connect();

    // TRUNCATE bypasses RLS in Postgres, so we can wipe state cleanly
    // regardless of any session variables.
    await prisma.$executeRawUnsafe(`
      TRUNCATE tickets, order_items, orders, cart_items, carts,
               products, events, tenants, webhook_inbox
      RESTART IDENTITY CASCADE
    `);

    // tenants table is the only multi-tenant-adjacent table without RLS,
    // because tenants themselves are the lookup keys.
    const [a] = await prisma.$queryRaw<{ id: string }[]>`
      INSERT INTO tenants (name) VALUES ('Tenant A') RETURNING id
    `;
    const [b] = await prisma.$queryRaw<{ id: string }[]>`
      INSERT INTO tenants (name) VALUES ('Tenant B') RETURNING id
    `;
    tenantA = a.id;
    tenantB = b.id;

    productA = await withTenant(prisma, tenantA, async (tx) => {
      const row = await tx.product.create({
        data: {
          tenantId: tenantA,
          name: 'Boné Tenant A',
          unitPrice: 5000,
          stockCount: 100,
        },
      });
      return row.id;
    });

    productB = await withTenant(prisma, tenantB, async (tx) => {
      const row = await tx.product.create({
        data: {
          tenantId: tenantB,
          name: 'Ingresso Tenant B',
          unitPrice: 10000,
          stockCount: 50,
        },
      });
      return row.id;
    });
  });

  afterAll(async () => {
    await prisma.$disconnect();
  });

  describe('default-deny (no tenant context)', () => {
    it('returns zero products', async () => {
      const products = await prisma.product.findMany();
      expect(products).toEqual([]);
    });

    it('returns zero carts', async () => {
      const carts = await prisma.cart.findMany();
      expect(carts).toEqual([]);
    });

    it('returns zero orders', async () => {
      const orders = await prisma.order.findMany();
      expect(orders).toEqual([]);
    });

    it('cannot fetch a known product by id', async () => {
      const found = await prisma.product.findUnique({
        where: { id: productA },
      });
      expect(found).toBeNull();
    });
  });

  describe('tenant scope (own data visible)', () => {
    it('tenant A sees only its own products', async () => {
      const products = await withTenant(prisma, tenantA, (tx) =>
        tx.product.findMany(),
      );
      expect(products).toHaveLength(1);
      expect(products[0].name).toBe('Boné Tenant A');
      expect(products[0].id).toBe(productA);
    });

    it('tenant B sees only its own products', async () => {
      const products = await withTenant(prisma, tenantB, (tx) =>
        tx.product.findMany(),
      );
      expect(products).toHaveLength(1);
      expect(products[0].name).toBe('Ingresso Tenant B');
      expect(products[0].id).toBe(productB);
    });
  });

  describe('cross-tenant access (other tenant data invisible)', () => {
    it('tenant A cannot fetch tenant B product by id', async () => {
      const found = await withTenant(prisma, tenantA, (tx) =>
        tx.product.findUnique({ where: { id: productB } }),
      );
      expect(found).toBeNull();
    });

    it('tenant A cannot update tenant B product', async () => {
      const result = await withTenant(prisma, tenantA, (tx) =>
        tx.product.updateMany({
          where: { id: productB },
          data: { stockCount: 99999 },
        }),
      );
      expect(result.count).toBe(0);

      // confirm tenant B's stock was untouched
      const bProduct = await withTenant(prisma, tenantB, (tx) =>
        tx.product.findUnique({ where: { id: productB } }),
      );
      expect(bProduct?.stockCount).toBe(50);
    });

    it('tenant A cannot delete tenant B product', async () => {
      const result = await withTenant(prisma, tenantA, (tx) =>
        tx.product.deleteMany({ where: { id: productB } }),
      );
      expect(result.count).toBe(0);

      // confirm tenant B's product still exists
      const bProduct = await withTenant(prisma, tenantB, (tx) =>
        tx.product.findUnique({ where: { id: productB } }),
      );
      expect(bProduct).not.toBeNull();
    });
  });

  describe('webhook_inbox (no RLS — webhooks arrive pre-tenant)', () => {
    it('returns rows regardless of tenant context (admin scope)', async () => {
      await prisma.webhookInbox.createMany({
        data: [
          { transactionId: 'txn-leak-1', payload: { test: true } },
          { transactionId: 'txn-leak-2', payload: { test: true } },
        ],
      });

      const rows = await prisma.webhookInbox.findMany({
        where: { transactionId: { in: ['txn-leak-1', 'txn-leak-2'] } },
      });
      expect(rows).toHaveLength(2);
    });
  });
});
