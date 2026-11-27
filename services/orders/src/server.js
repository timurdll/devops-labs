'use strict';

// Tracing first: the instrumentations must patch http/pg/undici before anything loads them.
const { shutdownTracing } = require('./telemetry/tracing');
const http = require('node:http');
const { createHandler } = require('./app');
const { createRepo } = require('./repo');
const { createCatalogClient, UpstreamStatusError } = require('./catalog-client');
const { createCircuitBreaker } = require('./circuit-breaker');
const { createMetrics } = require('./telemetry/metrics');

const PORT = Number(process.env.PORT || 8080);
const metrics = createMetrics({ service: 'orders' });
const repo = createRepo({ onConnectRetry: () => metrics.observeRetry('postgres') });
const env = (k, d) => Number(process.env[k] || d);
// Week 11: thresholds come from the chart (charts/shoplite/values.yaml → orders.resilience).
const breaker = createCircuitBreaker({
  name: 'catalog',
  windowSize: env('CB_WINDOW_SIZE', 20),
  minimumCalls: env('CB_MINIMUM_CALLS', 10),
  failureRateThreshold: env('CB_FAILURE_RATE', 0.5),
  consecutiveFailureThreshold: env('CB_CONSECUTIVE_FAILURES', 5),
  openMs: env('CB_OPEN_MS', 15000),
  halfOpenCalls: env('CB_HALF_OPEN_CALLS', 3),
  isFailure: (err) => !(err instanceof UpstreamStatusError && err.status < 500),
  onStateChange: (t) => {
    metrics.observeBreakerState(t);
    console.warn(`orders: circuit ${t.name} ${t.from} → ${t.to} (${t.reason})`);
  },
  onCall: metrics.observeBreakerCall,
});
const catalog = createCatalogClient({
  baseUrl: process.env.CATALOG_URL || 'http://catalog',
  timeoutMs: env('CATALOG_TIMEOUT_MS', 1000),
  observe: metrics.observeClient,
  breaker,
  retryOptions: {
    attempts: env('RETRY_ATTEMPTS', 3),
    baseMs: env('RETRY_BASE_MS', 50),
    maxMs: env('RETRY_MAX_MS', 500),
    onRetry: () => metrics.observeRetry('catalog'),
  },
  cacheTtlMs: env('CATALOG_CACHE_TTL_MS', 600000),
  onFallback: (reason, result) => metrics.observeFallback('catalog', reason, result),
});
const server = http.createServer(createHandler({ repo, catalog, metrics }));
// Week 11 (1.2.2, PM-W11-02 finding 3): the only client of this server is the local Envoy sidecar,
// which keeps idle upstream connections for 1 h. Node's default keep-alive is 5 s, so Node closed
// idle connections that Envoy was about to reuse → 503 "UC" (upstream connection termination).
// Rule: the server must keep idle connections longer than its proxy, so the proxy closes first.
server.keepAliveTimeout = Number(process.env.HTTP_KEEPALIVE_TIMEOUT_MS || 3_660_000); // 61 min
server.headersTimeout = server.keepAliveTimeout + 1000;

async function migrateWithRetry(attempt = 1) {
  try {
    await repo.migrate();
    console.log('orders: schema ready');
  } catch (err) {
    const delay = Math.min(1000 * 2 ** attempt, 15000);
    console.warn(`orders: migration attempt ${attempt} failed (${err.message}), retry in ${delay}ms`);
    setTimeout(() => migrateWithRetry(attempt + 1), delay).unref();
  }
}

server.listen(PORT, () => {
  console.log(`orders: listening on :${PORT}`);
  migrateWithRetry();
});

function shutdown(signal) {
  console.log(`orders: ${signal} received, draining connections`);
  server.close(() =>
    Promise.allSettled([repo.close(), shutdownTracing()]).finally(() => process.exit(0)),
  );
  setTimeout(() => process.exit(1), 10000).unref();
}
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
