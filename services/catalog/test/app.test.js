'use strict';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { createHandler } = require('../src/app');

const products = [
  { id: 1, sku: 'SKU-001', name: 'Keyboard', priceCents: 8900, stock: 3 },
  { id: 2, sku: 'SKU-002', name: 'Dock', priceCents: 12900, stock: 0 },
];

let ready = true;
let failList = false;
const repo = {
  ping: async () => ready,
  list: async () => {
    if (failList) throw new Error('boom');
    return products;
  },
  get: async (id) => products.find((p) => p.id === id) || null,
};

let server;
let base;
before(async () => {
  server = http.createServer(createHandler({ repo, logger: { error() {} } }));
  await new Promise((resolve) => server.listen(0, resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});
after(() => server.close());

test('GET /healthz returns 200', async () => {
  const res = await fetch(`${base}/healthz`);
  assert.equal(res.status, 200);
  assert.ok(res.headers.get('x-served-by'));
});

test('GET /readyz reflects database state', async () => {
  ready = true;
  assert.equal((await fetch(`${base}/readyz`)).status, 200);
  ready = false;
  assert.equal((await fetch(`${base}/readyz`)).status, 503);
  ready = true;
});

test('GET /api/catalog/products lists products', async () => {
  const res = await fetch(`${base}/api/catalog/products`);
  const body = await res.json();
  assert.equal(res.status, 200);
  assert.equal(body.items.length, 2);
  assert.ok(body.servedBy);
});

test('GET /api/catalog/products/:id returns one product or 404', async () => {
  const ok = await fetch(`${base}/api/catalog/products/1`);
  assert.equal(ok.status, 200);
  assert.equal((await ok.json()).item.sku, 'SKU-001');

  const missing = await fetch(`${base}/api/catalog/products/99`);
  assert.equal(missing.status, 404);
});

test('trailing slash is tolerated and unknown routes are 404', async () => {
  assert.equal((await fetch(`${base}/api/catalog/products/`)).status, 200);
  assert.equal((await fetch(`${base}/nope`)).status, 404);
  assert.equal((await fetch(`${base}/api/catalog/products/abc`)).status, 404);
});

test('repository errors become 500 without leaking details', async () => {
  failList = true;
  const res = await fetch(`${base}/api/catalog/products`);
  failList = false;
  assert.equal(res.status, 500);
  assert.deepEqual(await res.json(), { error: 'internal error' });
});
