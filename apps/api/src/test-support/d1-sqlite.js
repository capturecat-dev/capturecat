/**
 * TEST-ONLY: a D1Database stand-in over Node's built-in SQLite (`node:sqlite`,
 * Node ≥ 22.5), with the repo's real migrations applied — so route tests run
 * the exact SQL the Worker runs (upserts, RETURNING, json_set, the storage
 * sum) instead of a hand-written fake that agrees with itself.
 *
 * Plain JS on purpose: the API's tsconfig carries only the Workers types (no
 * @types/node), and this file is the one place Node APIs are needed. Typed by
 * the sibling d1-sqlite.d.ts. Never imported by Worker code.
 */

import { DatabaseSync } from "node:sqlite";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const MIGRATIONS_DIR = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "migrations");

function toSqlValue(value) {
  if (value === undefined) return null;
  if (typeof value === "boolean") return value ? 1 : 0; // D1 stores booleans as 0/1
  return value;
}

function plainRow(row) {
  return row ? { ...row } : row;
}

class Statement {
  constructor(sqlite, sql, params = []) {
    this.sqlite = sqlite;
    this.sql = sql;
    this.params = params;
  }
  bind(...params) {
    return new Statement(this.sqlite, this.sql, params.map(toSqlValue));
  }
  execute(mode) {
    const stmt = this.sqlite.prepare(this.sql);
    if (mode === "run") {
      const info = stmt.run(...this.params);
      return { success: true, results: [], meta: { changes: Number(info.changes), last_row_id: Number(info.lastInsertRowid) } };
    }
    const rows = stmt.all(...this.params).map(plainRow);
    return { success: true, results: rows, meta: { changes: 0 } };
  }
  async first(column) {
    // `all` also executes DML — and returns RETURNING rows (the rate limiter).
    const row = this.execute("all").results[0] ?? null;
    if (row && column) return row[column] ?? null;
    return row;
  }
  async all() {
    return this.execute("all");
  }
  async run() {
    return this.execute("run");
  }
}

export function createTestD1(options = {}) {
  const sqlite = new DatabaseSync(":memory:");
  sqlite.exec("PRAGMA foreign_keys = ON;"); // D1 enforces foreign keys
  // `before`: stop at the first migration whose file name sorts at or after
  // it — to put data in an OLD schema and then `migrate()` the next file.
  for (const file of readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith(".sql")).sort()) {
    if (options.before && file >= options.before) break;
    sqlite.exec(readFileSync(join(MIGRATIONS_DIR, file), "utf8"));
  }
  return {
    /** Test helper: apply one migration file (by name) now. */
    migrate(file) {
      sqlite.exec(readFileSync(join(MIGRATIONS_DIR, file), "utf8"));
    },
    prepare(sql) {
      return new Statement(sqlite, sql);
    },
    async batch(statements) {
      // D1 runs a batch as one transaction: all or nothing.
      sqlite.exec("BEGIN");
      try {
        const out = statements.map((s) => {
          const isQuery = /^\s*SELECT/i.test(s.sql) || /\bRETURNING\b/i.test(s.sql);
          return s.execute(isQuery ? "all" : "run");
        });
        sqlite.exec("COMMIT");
        return out;
      } catch (err) {
        sqlite.exec("ROLLBACK");
        throw err;
      }
    },
    async exec(sql) {
      sqlite.exec(sql);
      return { count: 0, duration: 0 };
    },
    /** Test helper: synchronous query. */
    query(sql, ...params) {
      return sqlite.prepare(sql).all(...params.map(toSqlValue)).map(plainRow);
    },
  };
}
