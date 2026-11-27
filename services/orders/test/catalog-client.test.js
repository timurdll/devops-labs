'use strict';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { createCatalogClient, CatalogUnavailableError } = require('../src/catalog-client');
const { createCircuitBreaker } = require('../src/circuit-breaker');

let server;
let base;
let hits = {};
let flaky = 0; // product 3 fails this many times with 503, then answers
let latencyMs = 0; // product 1 delay (chaos)
before(async () => {
  server = http.createServer((req, res) => {
    const id = req.url.split('/').pop();
    hits[id] = (hits[id] || 0) + 1;
    const answer = (item) => {
      res.writeHead(200, { 'Content-Type': 'application/json', 'X-Served-By': 'catalog-a' });
      res.end(JSON.stringify({ item }));
    };
    if (id === '1') return setTimeout(() => answer({ id: 1, priceCents: 100, stock: 1 }), latencyMs);
    if (id === '2') return setTimeout(() => res.end('{}'), 1000);
    if (id === '3') {
      if (flaky > 0) { flaky -= 1; res.writeHead(503); return res.end(); }
      return answer({ id: 3, priceCents: 300, stock: 5 });
    }
    res.writeHead({ 9: 500, 8: 400 }[id] || 404);
    return res.end();
  });
  await new Promise((resolve) => server.listen(0, resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});
after(() => server.close());

const noSleep = { sleep: async () => {} };

test('getProduct resolves products and records each call', async () => {
  hits = {};
  const calls = [];
  const client = createCatalogClient({ baseUrl: base, timeoutMs: 250, observe: (...a) => calls.push(a), retryOptions: noSleep });

  assert.deepEqual(await client.getProduct(1), {
    product: { id: 1, priceCents: 100, stock: 1 }, servedBy: 'catalog-a', degraded: false,
  });
  assert.equal((await client.getProduct(5)).product, null);
  await assert.rejects(client.getProduct(9), CatalogUnavailableError);
  await assert.rejects(client.getProduct(8), /catalog responded 400/);
  await assert.rejects(client.getProduct(2), CatalogUnavailableError);

  assert.deepEqual(calls.map(([host, status]) => [host, status]), [
    ['127.0.0.1', 200],
    ['127.0.0.1', 404],
    ['127.0.0.1', 500], // 500 is not retried (not a transient status)
    ['127.0.0.1', 400],
    ['127.0.0.1', 'timeout'], // timeouts are not retried
  ]);
  assert.ok(calls.every(([, , seconds]) => seconds >= 0));
});

test('transient 503 is retried with backoff', async () => {
  hits = {};
  flaky = 2;
  const retries = [];
  const client = createCatalogClient({ baseUrl: base, retryOptions: { ...noSleep, onRetry: (r) => retries.push(r.attempt) } });
  assert.equal((await client.getProduct(3)).product.priceCents, 300);
  assert.equal(hits['3'], 3);
  assert.deepEqual(retries, [1, 2]);
});

test('network errors are recorded as "error" and retried', async () => {
  const calls = [];
  const client = createCatalogClient({ baseUrl: 'http://127.0.0.1:1', observe: (...a) => calls.push(a), retryOptions: noSleep });
  await assert.rejects(client.getProduct(1), CatalogUnavailableError);
  assert.deepEqual(calls.map((c) => c[1]), ['error', 'error', 'error']);
});

test('chaos hypothesis: 3000 ms latency trips the breaker and the cached product is served', async () => {
  hits = {};
  latencyMs = 0;
  const fallbacks = [];
  const breaker = createCircuitBreaker({ name: 'catalog', consecutiveFailureThreshold: 3 });
  const client = createCatalogClient({
    baseUrl: base, timeoutMs: 50, breaker, retryOptions: noSleep,
    onFallback: (reason, result) => fallbacks.push(`${reason}/${result}`),
  });
  await client.getProduct(1); // warms the last-known-good cache
  latencyMs = 3000; // the injected fault (scaled: 3000 ms ≫ 50 ms timeout)

  const first = await client.getProduct(1);
  assert.deepEqual([first.degraded, first.degradedReason, first.servedBy], [true, 'timeout', 'cache']);
  await client.getProduct(1);
  await client.getProduct(1);
  assert.equal(breaker.state(), 'open');

  const before = hits['1'];
  const started = Date.now();
  const fast = await client.getProduct(1);
  assert.equal(fast.degradedReason, 'circuit_open');
  assert.equal(hits['1'], before, 'open circuit must not call catalog');
  assert.ok(Date.now() - started < 20, 'open circuit answers immediately');
  assert.deepEqual(fallbacks, ['timeout/cache_hit', 'timeout/cache_hit', 'timeout/cache_hit', 'circuit_open/cache_hit']);

  await assert.rejects(client.getProduct(4), (e) => e instanceof CatalogUnavailableError && e.retryAfterMs > 0);
  latencyMs = 0;
});

test('cache entries expire', async () => {
  let t = 0;
  const breaker = createCircuitBreaker({ name: 'c', consecutiveFailureThreshold: 1 });
  const client = createCatalogClient({ baseUrl: base, breaker, cacheTtlMs: 1000, now: () => t, retryOptions: noSleep });
  await client.getProduct(1);
  breaker.execute(async () => { throw new Error('x'); }).catch(() => {});
  await new Promise((r) => setImmediate(r));
  t = 999;
  assert.equal((await client.getProduct(1)).degraded, true);
  t = 1001;
  await assert.rejects(client.getProduct(1), CatalogUnavailableError);
});
