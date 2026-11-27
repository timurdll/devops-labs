'use strict';

const { Pool } = require('pg');
const { retry } = require('./retry');

// Week 11 (1.2.1, post-mortem PM-W11-02): opening a new pooled connection can fail transiently
// (in E1 two connects were reset during the mTLS handshake to postgres' sidecar → two 502s).
// Such a failure happens before any SQL is sent, so retrying the *connect* is always safe — even
// for an INSERT. Errors after the query was sent are never retried (the row might exist).
const CONNECT_ERROR_CODES = new Set(['ECONNRESET', 'ECONNREFUSED', 'EPIPE', 'ETIMEDOUT', 'EAI_AGAIN']);
function isConnectError(err) {
  return (
    CONNECT_ERROR_CODES.has(err.code) ||
    /timeout exceeded when trying to connect|Connection terminated (unexpectedly|due to connection timeout)/i.test(err.message)
  );
}

// Connection settings come from the standard libpq variables
// (PGHOST, PGPORT, PGDATABASE, PGUSER from a ConfigMap; PGPASSWORD from a Secret).
function createRepo({
  // Idle connections are kept for 60 s (pg default 10 s): fewer new connections = fewer handshakes.
  pool = new Pool({ max: 5, connectionTimeoutMillis: 2000, idleTimeoutMillis: 60000 }),
  retryOptions = {},
  onConnectRetry = () => {},
} = {}) {
  let migrated = false;

  async function query(text, params) {
    const client = await retry(() => pool.connect(), {
      attempts: 3,
      baseMs: 50,
      maxMs: 300,
      shouldRetry: isConnectError,
      onRetry: onConnectRetry,
      ...retryOptions,
    });
    try {
      const result = await client.query(text, params);
      client.release();
      return result;
    } catch (err) {
      client.release(err); // a broken connection is destroyed, not returned to the pool
      throw err;
    }
  }

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
        await query('SELECT 1');
        return true;
      } catch {
        return false;
      }
    },

    async list() {
      const { rows } = await query(
        `SELECT id, product_id AS "productId", quantity, total_cents AS "totalCents",
                created_at AS "createdAt"
         FROM orders ORDER BY id DESC LIMIT 20`,
      );
      return rows;
    },

    async insert({ productId, quantity, totalCents }) {
      const { rows } = await query(
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

module.exports = { createRepo, isConnectError };
