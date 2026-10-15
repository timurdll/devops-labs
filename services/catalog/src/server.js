'use strict';

const http = require('node:http');
const { createHandler } = require('./app');
const { createRepo } = require('./repo');

const PORT = Number(process.env.PORT || 8080);
const repo = createRepo();
const server = http.createServer(createHandler({ repo }));

// The pod starts serving /healthz immediately; /readyz stays 503 until the
// database answers, so the Service only routes traffic to ready endpoints.
async function migrateWithRetry(attempt = 1) {
  try {
    await repo.migrate();
    console.log('catalog: schema ready');
  } catch (err) {
    const delay = Math.min(1000 * 2 ** attempt, 15000);
    console.warn(`catalog: migration attempt ${attempt} failed (${err.message}), retry in ${delay}ms`);
    setTimeout(() => migrateWithRetry(attempt + 1), delay).unref();
  }
}

server.listen(PORT, () => {
  console.log(`catalog: listening on :${PORT}`);
  migrateWithRetry();
});

function shutdown(signal) {
  console.log(`catalog: ${signal} received, draining connections`);
  server.close(() => repo.close().finally(() => process.exit(0)));
  setTimeout(() => process.exit(1), 10000).unref();
}
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
