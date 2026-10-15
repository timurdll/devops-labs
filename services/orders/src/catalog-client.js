'use strict';

// CATALOG_URL points at the catalog ClusterIP Service, e.g.
// http://catalog.shop.svc.cluster.local — resolved by CoreDNS, load-balanced by kube-proxy.
function createCatalogClient({ baseUrl, timeoutMs = 2000 }) {
  return {
    async getProduct(id) {
      const res = await fetch(`${baseUrl}/api/catalog/products/${id}`, {
        signal: AbortSignal.timeout(timeoutMs),
      });
      const servedBy = res.headers.get('x-served-by');
      if (res.status === 404) return { product: null, servedBy };
      if (!res.ok) throw new Error(`catalog responded ${res.status}`);
      const body = await res.json();
      return { product: body.item, servedBy };
    },
  };
}

module.exports = { createCatalogClient };
