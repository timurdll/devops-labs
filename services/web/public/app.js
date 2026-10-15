'use strict';

const money = (cents, currency) =>
  new Intl.NumberFormat('en-US', { style: 'currency', currency }).format(cents / 100);

function cell(text) {
  const td = document.createElement('td');
  td.textContent = text;
  return td;
}

async function getJson(url, options) {
  const res = await fetch(url, options);
  const body = await res.json();
  if (!res.ok) throw new Error(body.error || `HTTP ${res.status}`);
  return body;
}

async function loadConfig() {
  // config.json is mounted from the `web-config` ConfigMap (see k8s/shop/web.yaml)
  try {
    return await getJson('/config/config.json');
  } catch {
    return { shopName: 'ShopLite', currency: 'USD', banner: '', environment: 'local' };
  }
}

async function render(config) {
  const products = await getJson('/api/catalog/products');
  document.getElementById('catalog-pod').textContent = `via ${products.servedBy}`;
  const tbody = document.querySelector('#products tbody');
  tbody.replaceChildren();
  for (const p of products.items) {
    const tr = document.createElement('tr');
    tr.append(cell(p.sku), cell(p.name), cell(money(p.priceCents, config.currency)), cell(p.stock));
    const td = document.createElement('td');
    const btn = document.createElement('button');
    btn.textContent = 'Order 1';
    btn.addEventListener('click', () => order(p.id, config));
    td.append(btn);
    tr.append(td);
    tbody.append(tr);
  }

  const orders = await getJson('/api/orders');
  document.getElementById('orders-pod').textContent = `via ${orders.servedBy}`;
  const otbody = document.querySelector('#orders tbody');
  otbody.replaceChildren();
  for (const o of orders.items) {
    const tr = document.createElement('tr');
    tr.append(
      cell(o.id),
      cell(o.productId),
      cell(o.quantity),
      cell(money(o.totalCents, config.currency)),
      cell(new Date(o.createdAt).toLocaleString()),
    );
    otbody.append(tr);
  }
}

async function order(productId, config) {
  const status = document.getElementById('status');
  try {
    const body = await getJson('/api/orders', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ productId, quantity: 1 }),
    });
    status.textContent = `Order #${body.order.id} created by ${body.servedBy} (price checked by ${body.catalogServedBy})`;
    await render(config);
  } catch (err) {
    status.textContent = `Order failed: ${err.message}`;
  }
}

(async () => {
  const config = await loadConfig();
  document.getElementById('shop-name').textContent = config.shopName;
  document.getElementById('web-env').textContent = config.environment;
  if (config.banner) {
    const banner = document.getElementById('banner');
    banner.textContent = config.banner;
    banner.hidden = false;
  }
  try {
    await render(config);
  } catch (err) {
    document.getElementById('status').textContent = `API unavailable: ${err.message}`;
  }
})();
