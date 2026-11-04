'use strict';

// Tracing first: the instrumentations must patch http/pg/undici before anything loads them.
const { shutdownTracing } = require('./telemetry/tracing');
const http = require('node:http');
const { createHandler } = require('./app');
const { createRepo } = require('./repo');
const { createCatalogClient } = require('./catalog-client');
const { createMetrics } = require('./telemetry/metrics');

const PORT = Number(process.env.PORT || 8080);
const repo = createRepo();
const metrics = createMetrics({ service: 'orders' });
const catalog = createCatalogClient({
  baseUrl: process.env.CATALOG_URL || 'http://catalog',
  timeoutMs: Number(process.env.CATALOG_TIMEOUT_MS || 2000),
  observe: metrics.observeClient,
});
const server = http.createServer(createHandler({ repo, catalog, metrics }));

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
