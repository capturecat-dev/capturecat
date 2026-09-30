/** Types for the TEST-ONLY node:sqlite-backed D1 stand-in (d1-sqlite.js). */
export interface TestD1 extends D1Database {
  /** Synchronous raw query, for assertions. */
  query<T = Record<string, unknown>>(sql: string, ...params: unknown[]): T[];
}

/** A fresh in-memory database with every migration in apps/api/migrations applied. */
export function createTestD1(): TestD1;
