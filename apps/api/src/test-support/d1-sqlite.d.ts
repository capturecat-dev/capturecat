/** Types for the TEST-ONLY node:sqlite-backed D1 stand-in (d1-sqlite.js). */
export interface TestD1 extends D1Database {
  /** Synchronous raw query, for assertions. */
  query<T = Record<string, unknown>>(sql: string, ...params: unknown[]): T[];
  /** Apply one migration file (e.g. "0027_project_history.sql") now. */
  migrate(file: string): void;
}

/** A fresh in-memory database with every migration in apps/api/migrations
 *  applied — or, with `before`, only those whose file name sorts before it. */
export function createTestD1(options?: { before?: string }): TestD1;
