'use strict';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { createHandler, validateOrder } = require('../src/app');

const catalogProducts = {
  1: { id: 1, priceCents: 8900, stock: 3 },
};

let ready = true;
let catalogDown = false;
const saved = [];
const repo = {
  ping: async () => ready,
  list: async () => saved,
  insert: async (o) => {
    const order = { id: saved.length + 1, ...o };
    saved.push(order);
    return order;
  },
};
const catalog = {
  getProduct: async (id) => {
    if (catalogDown) throw new Error('ECONNREFUSED');
    return { product: catalogProducts[id] || null, servedBy: 'catalog-pod-a' };
  },
};

let server;
let base;
before(async () => {
  server = http.createServer(createHandler({ repo, catalog, logger: { error() {} } }));
  await new Promise((resolve) => server.listen(0, resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});
after(() => server.close());

const post = (body, raw) =>
  fetch(`${base}/api/orders`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: raw ?? JSON.stringify(body),
  });

test('validateOrder accepts valid input and rejects invalid input', () => {
  assert.deepEqual(validateOrder({ productId: '2', quantity: 5 }), { productId: 2, quantity: 5 });
  assert.throws(() => validateOrder({ productId: 0, quantity: 1 }), /productId/);
  assert.throws(() => validateOrder({ productId: 1, quantity: 0 }), /quantity/);
  assert.throws(() => validateOrder({ productId: 1, quantity: 101 }), /quantity/);
  assert.throws(() => validateOrder(null), /productId/);
});

test('health and readiness endpoints', async () => {
  assert.equal((await fetch(`${base}/healthz`)).status, 200);
  ready = false;
  assert.equal((await fetch(`${base}/readyz`)).status, 503);
  ready = true;
  assert.equal((await fetch(`${base}/readyz`)).status, 200);
});

test('POST /api/orders creates an order priced by the catalog', async () => {
  const res = await post({ productId: 1, quantity: 2 });
  const body = await res.json();
  assert.equal(res.status, 201);
  assert.equal(body.order.totalCents, 17800);
  assert.equal(body.catalogServedBy, 'catalog-pod-a');

  const list = await (await fetch(`${base}/api/orders`)).json();
  assert.equal(list.items.length, 1);
});

test('POST /api/orders maps business errors to 4xx', async () => {
  assert.equal((await post({ productId: 42, quantity: 1 })).status, 422);
  assert.equal((await post({ productId: 1, quantity: 50 })).status, 409);
  assert.equal((await post(null, '{not json')).status, 400);
  assert.equal((await post(null, JSON.stringify({ pad: 'x'.repeat(20000) }))).status, 413);
});

test('catalog outage returns 502 and unknown routes return 404', async () => {
  catalogDown = true;
  assert.equal((await post({ productId: 1, quantity: 1 })).status, 502);
  catalogDown = false;
  assert.equal((await fetch(`${base}/api/unknown`)).status, 404);
});
