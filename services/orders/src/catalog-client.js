'use strict';

const { createCircuitBreaker, CircuitOpenError } = require('./circuit-breaker');
const { retry } = require('./retry');

class UpstreamStatusError extends Error {
  constructor(status) {
    super(`catalog responded ${status}`);
    this.name = 'UpstreamStatusError';
    this.status = status;
  }
}

class CatalogUnavailableError extends Error {
  constructor(cause, retryAfterMs) {
    super(`catalog unavailable (${cause.message})`, { cause });
    this.name = 'CatalogUnavailableError';
    this.retryAfterMs = retryAfterMs;
  }
}

const RETRYABLE_STATUS = new Set([502, 503, 504]);
const isTimeout = (err) => err.name === 'TimeoutError' || err.name === 'AbortError';

// CATALOG_URL points at the catalog Service, e.g. http://catalog.shop-dev.svc.cluster.local.
// The fetch() call is traced by the undici instrumentation, which injects `traceparent`, so the
// catalog span becomes a child of this orders request. `observe` records the client-side RED view.
//
// Week 11 resilience stack, outermost first (docs/week11/README.md §3):
//   fallback  — last-known-good product from an in-memory cache, the order is flagged degraded
//   retry     — up to 3 attempts, exponential backoff + full jitter, idempotent GET only
//   breaker   — fail fast while catalog is sick (each retry attempt counts as one call)
//   timeout   — per attempt (CATALOG_TIMEOUT_MS)
function createCatalogClient({
  baseUrl,
  timeoutMs = 1000,
  observe = () => {},
  breaker,
  retryOptions = {},
  cacheTtlMs = 10 * 60 * 1000,
  now = Date.now,
  onFallback = () => {},
}) {
  const serverAddress = new URL(baseUrl).hostname;
  const cb =
    breaker ??
    createCircuitBreaker({
      name: 'catalog',
      isFailure: (err) => !(err instanceof UpstreamStatusError && err.status < 500),
    });
  const cache = new Map(); // id → { product, servedBy, at }

  async function fetchOnce(id) {
    const started = process.hrtime.bigint();
    const elapsed = () => Number(process.hrtime.bigint() - started) / 1e9;
    let res;
    try {
      res = await fetch(`${baseUrl}/api/catalog/products/${id}`, {
        signal: AbortSignal.timeout(timeoutMs),
      });
    } catch (err) {
      observe(serverAddress, isTimeout(err) ? 'timeout' : 'error', elapsed());
      throw err;
    }
    observe(serverAddress, res.status, elapsed());
    const servedBy = res.headers.get('x-served-by');
    if (res.status === 404) return { product: null, servedBy };
    if (!res.ok) throw new UpstreamStatusError(res.status);
    const body = await res.json();
    return { product: body.item, servedBy };
  }

  return {
    breaker: cb,
    async getProduct(id) {
      try {
        const result = await retry(() => cb.execute(() => fetchOnce(id)), {
          shouldRetry: (err) =>
            !(err instanceof CircuitOpenError) &&
            !isTimeout(err) &&
            (!(err instanceof UpstreamStatusError) || RETRYABLE_STATUS.has(err.status)),
          ...retryOptions,
        });
        if (result.product) cache.set(id, { ...result, at: now() });
        return { ...result, degraded: false };
      } catch (err) {
        if (err instanceof UpstreamStatusError && err.status < 500) throw err;
        const reason = err instanceof CircuitOpenError ? 'circuit_open' : isTimeout(err) ? 'timeout' : 'error';
        const hit = cache.get(id);
        if (hit && now() - hit.at <= cacheTtlMs) {
          onFallback(reason, 'cache_hit');
          return { product: hit.product, servedBy: 'cache', degraded: true, degradedReason: reason };
        }
        onFallback(reason, 'cache_miss');
        throw new CatalogUnavailableError(err, err.retryAfterMs);
      }
    },
  };
}

module.exports = { createCatalogClient, CatalogUnavailableError, UpstreamStatusError };
