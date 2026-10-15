'use strict';

const os = require('node:os');

const POD_NAME = process.env.POD_NAME || os.hostname();

function send(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(payload),
    'X-Served-By': POD_NAME,
  });
  res.end(payload);
}

/**
 * Builds the HTTP request handler for the catalog service.
 * `repo` is injected so the handler can be unit-tested without PostgreSQL.
 */
function createHandler({ repo, logger = console }) {
  return async function handler(req, res) {
    const url = new URL(req.url, 'http://localhost');
    const path = url.pathname.replace(/\/+$/, '') || '/';

    try {
      if (req.method === 'GET' && path === '/healthz') {
        return send(res, 200, { status: 'ok' });
      }

      if (req.method === 'GET' && path === '/readyz') {
        const ready = await repo.ping();
        return send(res, ready ? 200 : 503, { status: ready ? 'ready' : 'db-unavailable' });
      }

      if (req.method === 'GET' && path === '/api/catalog/products') {
        const products = await repo.list();
        return send(res, 200, { servedBy: POD_NAME, items: products });
      }

      const match = path.match(/^\/api\/catalog\/products\/(\d+)$/);
      if (req.method === 'GET' && match) {
        const product = await repo.get(Number(match[1]));
        if (!product) return send(res, 404, { error: 'product not found' });
        return send(res, 200, { servedBy: POD_NAME, item: product });
      }

      return send(res, 404, { error: 'not found' });
    } catch (err) {
      logger.error(`catalog: ${req.method} ${path} failed: ${err.message}`);
      return send(res, 500, { error: 'internal error' });
    }
  };
}

module.exports = { createHandler };
