'use strict';

const { Pool } = require('pg');

// Connection settings come from the standard libpq variables
// (PGHOST, PGPORT, PGDATABASE, PGUSER from a ConfigMap; PGPASSWORD from a Secret).
function createRepo() {
  const pool = new Pool({ max: 5, connectionTimeoutMillis: 2000 });
  let migrated = false;

  // Several replicas start at once: a transaction-scoped advisory lock serialises their
  // migrations (concurrent CREATE TABLE IF NOT EXISTS can otherwise fail inside Postgres).
  async function inMigrationLock(work) {
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      await client.query("SELECT pg_advisory_xact_lock(hashtext('orders-schema'))");
      await work(client);
      await client.query('COMMIT');
    } catch (err) {
      await client.query('ROLLBACK').catch(() => {});
      throw err;
    } finally {
      client.release();
    }
  }

  return {
    async migrate() {
      await inMigrationLock(async (db) => {
        await db.query(`
          CREATE TABLE IF NOT EXISTS orders (
            id          SERIAL PRIMARY KEY,
            product_id  INTEGER NOT NULL,
            quantity    INTEGER NOT NULL CHECK (quantity > 0),
            total_cents INTEGER NOT NULL CHECK (total_cents >= 0),
            created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
          )`);
      });
      migrated = true;
    },

    // Readiness = schema migrated AND database reachable, so no pod receives traffic
    // before its tables exist.
    async ping() {
      if (!migrated) return false;
      try {
        await pool.query('SELECT 1');
        return true;
      } catch {
        return false;
      }
    },

    async list() {
      const { rows } = await pool.query(
        `SELECT id, product_id AS "productId", quantity, total_cents AS "totalCents",
                created_at AS "createdAt"
         FROM orders ORDER BY id DESC LIMIT 20`,
      );
      return rows;
    },

    async insert({ productId, quantity, totalCents }) {
      const { rows } = await pool.query(
        `INSERT INTO orders (product_id, quantity, total_cents) VALUES ($1, $2, $3)
         RETURNING id, product_id AS "productId", quantity, total_cents AS "totalCents",
                   created_at AS "createdAt"`,
        [productId, quantity, totalCents],
      );
      return rows[0];
    },

    close: () => pool.end(),
  };
}

module.exports = { createRepo };
