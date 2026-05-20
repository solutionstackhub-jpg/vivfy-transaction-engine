import { Injectable, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { Prisma, PrismaClient } from '@prisma/client';

const UUID_REGEX =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * PrismaService wraps PrismaClient and adds tenant-context support.
 *
 * The application interacts with the database almost exclusively through
 * {@link withTenant}. That method opens a transaction and sets the
 * `app.tenant_id` session variable before yielding the transaction client
 * to the caller. Row-Level Security policies in the database then filter
 * every query to the tenant in scope.
 *
 * Direct use of PrismaClient methods (this.user.findMany, etc.) bypasses
 * tenant context and should be limited to non-tenant tables (only
 * `tenants` and `webhook_inbox` qualify in this codebase) or to admin
 * scripts that intentionally need a global view.
 */
@Injectable()
export class PrismaService
  extends PrismaClient
  implements OnModuleInit, OnModuleDestroy
{
  async onModuleInit() {
    await this.$connect();
  }

  async onModuleDestroy() {
    await this.$disconnect();
  }

  /**
   * Run a function inside a transaction with the tenant context set.
   *
   * The function receives a transaction client (`tx`) that should be used
   * for every query inside. Using `this.<model>` instead of `tx.<model>`
   * would run against a connection without the tenant context set, and
   * RLS would return zero rows.
   */
  async withTenant<T>(
    tenantId: string,
    fn: (tx: Prisma.TransactionClient) => Promise<T>,
  ): Promise<T> {
    if (!UUID_REGEX.test(tenantId)) {
      throw new Error(
        `Invalid tenantId passed to withTenant: ${JSON.stringify(tenantId)}`,
      );
    }

    return this.$transaction(async (tx) => {
      // set_config with is_local = true binds the value to this transaction.
      await tx.$executeRaw`SELECT set_config('app.tenant_id', ${tenantId}, true)`;
      return fn(tx);
    });
  }
}
