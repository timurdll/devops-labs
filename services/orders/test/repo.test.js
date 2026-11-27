'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { createRepo, isConnectError } = require('../src/repo');

const reset = () => Object.assign(new Error('read ECONNRESET'), { code: 'ECONNRESET' });

function fakePool({ connectFailures = 0, queryError } = {}) {
  const calls = { connect: 0, released: [], queries: [] };
  return {
    calls,
    async connect() {
      calls.connect += 1;
      if (calls.connect <= connectFailures) throw reset();
      return {
        async query(text, params) {
          calls.queries.push([text, params]);
          if (queryError) throw queryError;
          if (/INSERT/.test(text)) return { rows: [{ id: 7, productId: params[0], quantity: params[1], totalCents: params[2] }] };
          if (/advisory|BEGIN|COMMIT|CREATE/.test(text)) return { rows: [] };
          return { rows: [{ ok: 1 }] };
        },
        release(err) { calls.released.push(err ? 'destroyed' : 'returned'); },
      };
    },
    end: async () => {},
  };
}
const fast = { sleep: async () => {} };

test('PM-W11-02: a reset while connecting is retried, the INSERT is sent exactly once', async () => {
  const pool = fakePool({ connectFailures: 2 });
  const retries = [];
  const repo = createRepo({ pool, retryOptions: fast, onConnectRetry: (r) => retries.push(r.attempt) });
  const order = await repo.insert({ productId: 1, quantity: 2, totalCents: 200 });
  assert.equal(order.id, 7);
  assert.equal(pool.calls.connect, 3);
  assert.deepEqual(retries, [1, 2]);
  assert.equal(pool.calls.queries.filter(([t]) => /INSERT/.test(t)).length, 1);
  assert.deepEqual(pool.calls.released, ['returned']);
});

test('gives up after 3 connect attempts', async () => {
  const repo = createRepo({ pool: fakePool({ connectFailures: 5 }), retryOptions: fast });
  await assert.rejects(repo.insert({ productId: 1, quantity: 1, totalCents: 1 }), /ECONNRESET/);
});

test('an error after the query was sent is not retried and the connection is destroyed', async () => {
  const pool = fakePool({ queryError: reset() });
  const repo = createRepo({ pool, retryOptions: fast });
  await assert.rejects(repo.insert({ productId: 1, quantity: 1, totalCents: 1 }), /ECONNRESET/);
  assert.equal(pool.calls.connect, 1);
  assert.deepEqual(pool.calls.released, ['destroyed']);
});

test('migrate, ping, list and close', async () => {
  const pool = fakePool();
  const repo = createRepo({ pool, retryOptions: fast });
  assert.equal(await repo.ping(), false); // not migrated yet
  await repo.migrate();
  assert.equal(await repo.ping(), true);
  assert.equal((await repo.list()).length, 1);
  await repo.close();

  const broken = createRepo({ pool: fakePool({ connectFailures: 99 }), retryOptions: fast });
  const failing = fakePool({ queryError: new Error('relation does not exist') });
  await assert.rejects(createRepo({ pool: failing, retryOptions: fast }).migrate(), /relation/);
  assert.deepEqual(failing.calls.queries.map(([t]) => t.trim().split(/\s+/)[0]), ['BEGIN', 'ROLLBACK']);
  assert.equal(await broken.ping(), false);
});

test('isConnectError classifies connection-level failures only', () => {
  assert.equal(isConnectError(reset()), true);
  assert.equal(isConnectError(new Error('timeout exceeded when trying to connect')), true);
  assert.equal(isConnectError(new Error('Connection terminated due to connection timeout')), true); // E2 trace
  assert.equal(isConnectError(new Error('duplicate key value violates unique constraint')), false);
});
