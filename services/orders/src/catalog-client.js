'use strict';

// CATALOG_URL points at the catalog ClusterIP Service, e.g.
// http://catalog.shop.svc.cluster.local — resolved by CoreDNS, load-balanced by kube-proxy.
// The fetch() call is traced by the undici instrumentation, which injects `traceparent`, so the
// catalog span becomes a child of this orders request. `observe` records the client-side RED view.
function createCatalogClient({ baseUrl, timeoutMs = 2000, observe = () => {} }) {
  const serverAddress = new URL(baseUrl).hostname;
  return {
    async getProduct(id) {
      const started = process.hrtime.bigint();
      const elapsed = () => Number(process.hrtime.bigint() - started) / 1e9;
      let res;
      try {
        res = await fetch(`${baseUrl}/api/catalog/products/${id}`, {
          signal: AbortSignal.timeout(timeoutMs),
        });
      } catch (err) {
        observe(serverAddress, err.name === 'TimeoutError' ? 'timeout' : 'error', elapsed());
        throw err;
      }
      observe(serverAddress, res.status, elapsed());
      const servedBy = res.headers.get('x-served-by');
      if (res.status === 404) return { product: null, servedBy };
      if (!res.ok) throw new Error(`catalog responded ${res.status}`);
      const body = await res.json();
      return { product: body.item, servedBy };
    },
  };
}

module.exports = { createCatalogClient };
