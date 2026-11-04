'use strict';

const os = require('node:os');
const { trace, SpanStatusCode } = require('@opentelemetry/api');
const { createMetrics } = require('./telemetry/metrics');

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

// Route template used as the `http_route` label and span name. Unknown paths collapse into
// one value so that scanners cannot blow up metric cardinality.
function routeOf(path) {
  if (path === '/healthz' || path === '/readyz' || path === '/api/catalog/products') return path;
  if (/^\/api\/catalog\/products\/\d+$/.test(path)) return '/api/catalog/products/:id';
  return 'unmatched';
}

/**
 * Builds the HTTP request handler for the catalog service.
 * `repo` is injected so the handler can be unit-tested without PostgreSQL.
 */
function createHandler({ repo, logger = console, metrics = createMetrics({ service: 'catalog' }) }) {
  return async function handler(req, res) {
    const url = new URL(req.url, 'http://localhost');
    const path = url.pathname.replace(/\/+$/, '') || '/';

    if (req.method === 'GET' && path === '/metrics') {
      const body = await metrics.registry.metrics();
      res.writeHead(200, { 'Content-Type': metrics.contentType });
      return res.end(body);
    }

    const route = routeOf(path);
    const span = trace.getActiveSpan();
    span?.updateName(`${req.method} ${route}`);
    span?.setAttribute('http.route', route);
    const end = metrics.startRequest(req.method);
    res.on('finish', () => end(route, res.statusCode));

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
      span?.recordException(err);
      span?.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
      const traceId = span?.spanContext().traceId ?? '-';
      logger.error(`catalog: ${req.method} ${path} failed: ${err.message} trace_id=${traceId}`);
      return send(res, 500, { error: 'internal error' });
    }
  };
}

module.exports = { createHandler, routeOf };
