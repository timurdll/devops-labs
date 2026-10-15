'use strict';

const os = require('node:os');

const POD_NAME = process.env.POD_NAME || os.hostname();
const MAX_BODY_BYTES = 10 * 1024;

function send(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(payload),
    'X-Served-By': POD_NAME,
  });
  res.end(payload);
}

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    let tooLarge = false;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        // Stop buffering but keep draining so the 413 response can still be written.
        tooLarge = true;
        chunks.length = 0;
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (tooLarge) return reject(new HttpError(413, 'payload too large'));
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}'));
      } catch {
        reject(new HttpError(400, 'invalid JSON'));
      }
    });
    req.on('error', reject);
  });
}

function validateOrder(input) {
  const productId = Number(input && input.productId);
  const quantity = Number(input && input.quantity);
  if (!Number.isInteger(productId) || productId < 1) {
    throw new HttpError(422, 'productId must be a positive integer');
  }
  if (!Number.isInteger(quantity) || quantity < 1 || quantity > 100) {
    throw new HttpError(422, 'quantity must be an integer between 1 and 100');
  }
  return { productId, quantity };
}

/**
 * Builds the HTTP handler for the orders service.
 * `repo` persists orders; `catalog` resolves products via the catalog Service (east-west call).
 */
function createHandler({ repo, catalog, logger = console }) {
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

      if (req.method === 'GET' && path === '/api/orders') {
        return send(res, 200, { servedBy: POD_NAME, items: await repo.list() });
      }

      if (req.method === 'POST' && path === '/api/orders') {
        const { productId, quantity } = validateOrder(await readJson(req));
        const lookup = await catalog.getProduct(productId);
        if (!lookup.product) throw new HttpError(422, 'unknown product');
        if (lookup.product.stock < quantity) throw new HttpError(409, 'insufficient stock');

        const order = await repo.insert({
          productId,
          quantity,
          totalCents: lookup.product.priceCents * quantity,
        });
        return send(res, 201, {
          servedBy: POD_NAME,
          catalogServedBy: lookup.servedBy,
          order,
        });
      }

      return send(res, 404, { error: 'not found' });
    } catch (err) {
      if (err instanceof HttpError) return send(res, err.status, { error: err.message });
      logger.error(`orders: ${req.method} ${path} failed: ${err.message}`);
      return send(res, 502, { error: 'upstream or database error' });
    }
  };
}

module.exports = { createHandler, validateOrder, HttpError };
