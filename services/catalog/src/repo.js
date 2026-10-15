'use strict';

const { Pool } = require('pg');

const SEED = [
  ['SKU-001', 'Mechanical keyboard', 8900, 25],
  ['SKU-002', 'USB-C dock', 12900, 10],
  ['SKU-003', '27" monitor', 31900, 5],
  ['SKU-004', 'Noise-cancelling headphones', 19900, 12],
];

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
      await client.query("SELECT pg_advisory_xact_lock(hashtext('catalog-schema'))");
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
          CREATE TABLE IF NOT EXISTS products (
            id          SERIAL PRIMARY KEY,
            sku         TEXT UNIQUE NOT NULL,
            name        TEXT NOT NULL,
            price_cents INTEGER NOT NULL CHECK (price_cents >= 0),
            stock       INTEGER NOT NULL CHECK (stock >= 0)
          )`);
        for (const [sku, name, price, stock] of SEED) {
          await db.query(
            `INSERT INTO products (sku, name, price_cents, stock)
             VALUES ($1, $2, $3, $4) ON CONFLICT (sku) DO NOTHING`,
            [sku, name, price, stock],
          );
        }
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
        'SELECT id, sku, name, price_cents AS "priceCents", stock FROM products ORDER BY id',
      );
      return rows;
    },

    async get(id) {
      const { rows } = await pool.query(
        'SELECT id, sku, name, price_cents AS "priceCents", stock FROM products WHERE id = $1',
        [id],
      );
      return rows[0] || null;
    },

    close: () => pool.end(),
  };
}

module.exports = { createRepo };
