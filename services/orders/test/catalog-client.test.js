'use strict';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { createCatalogClient } = require('../src/catalog-client');

let server;
let base;
before(async () => {
  server = http.createServer((req, res) => {
    const id = req.url.split('/').pop();
    if (id === '1') {
      res.writeHead(200, { 'Content-Type': 'application/json', 'X-Served-By': 'catalog-a' });
      return res.end(JSON.stringify({ item: { id: 1, priceCents: 100, stock: 1 } }));
    }
    if (id === '2') return setTimeout(() => res.end('{}'), 300);
    res.writeHead(id === '9' ? 500 : 404);
    return res.end();
  });
  await new Promise((resolve) => server.listen(0, resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});
after(() => server.close());

test('getProduct resolves products and records each call', async () => {
  const calls = [];
  const client = createCatalogClient({ baseUrl: base, timeoutMs: 100, observe: (...a) => calls.push(a) });

  assert.deepEqual(await client.getProduct(1), { product: { id: 1, priceCents: 100, stock: 1 }, servedBy: 'catalog-a' });
  assert.equal((await client.getProduct(5)).product, null);
  await assert.rejects(client.getProduct(9), /catalog responded 500/);
  await assert.rejects(client.getProduct(2), { name: 'TimeoutError' });

  assert.deepEqual(calls.map(([host, status]) => [host, status]), [
    ['127.0.0.1', 200],
    ['127.0.0.1', 404],
    ['127.0.0.1', 500],
    ['127.0.0.1', 'timeout'],
  ]);
  assert.ok(calls.every(([, , seconds]) => seconds >= 0));
});

test('network errors are recorded as "error"', async () => {
  const calls = [];
  const client = createCatalogClient({ baseUrl: 'http://127.0.0.1:1', observe: (...a) => calls.push(a) });
  await assert.rejects(client.getProduct(1));
  assert.equal(calls[0][1], 'error');
});
