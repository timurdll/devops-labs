'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { createCircuitBreaker, CircuitOpenError } = require('../src/circuit-breaker');

function harness(opts = {}) {
  let t = 0;
  const transitions = [];
  const calls = [];
  const cb = createCircuitBreaker({
    name: 'catalog',
    now: () => t,
    onStateChange: (x) => transitions.push(`${x.from}→${x.to}`),
    onCall: (x) => calls.push(x.outcome),
    ...opts,
  });
  const ok = () => cb.execute(async () => 'ok');
  const fail = () => cb.execute(async () => { throw new Error('boom'); }).catch((e) => e);
  return { cb, ok, fail, transitions, calls, advance: (ms) => { t += ms; } };
}

test('trips on 5 consecutive failures and rejects without calling the dependency', async () => {
  const h = harness();
  for (let i = 0; i < 4; i += 1) await h.fail();
  assert.equal(h.cb.state(), 'closed');
  await h.fail();
  assert.equal(h.cb.state(), 'open');
  let called = false;
  const err = await h.cb.execute(async () => { called = true; }).catch((e) => e);
  assert.ok(err instanceof CircuitOpenError);
  assert.equal(err.retryAfterMs, 15000);
  assert.equal(called, false);
  assert.deepEqual(h.calls.slice(-1), ['rejected']);
});

test('trips on failure rate ≥ 50 % once the minimum number of calls is reached', async () => {
  const h = harness({ consecutiveFailureThreshold: 100 });
  // ok, fail alternating: 50 % but only 8 calls → stays closed
  for (let i = 0; i < 4; i += 1) { await h.ok(); await h.fail(); }
  assert.equal(h.cb.state(), 'closed');
  await h.ok(); // 9 calls, 4 failures
  await h.fail(); // 10 calls, 5 failures = 50 %
  assert.equal(h.cb.state(), 'open');
});

test('sliding window forgets old failures', async () => {
  const h = harness({ windowSize: 10, minimumCalls: 10, consecutiveFailureThreshold: 100 });
  for (let i = 0; i < 4; i += 1) await h.fail();
  for (let i = 0; i < 20; i += 1) await h.ok();
  for (let i = 0; i < 4; i += 1) await h.fail();
  assert.equal(h.cb.state(), 'closed'); // 4/10 in the window
});

test('half-open: 3 successful trials close the circuit', async () => {
  const h = harness();
  for (let i = 0; i < 5; i += 1) await h.fail();
  h.advance(14999);
  assert.equal(h.cb.state(), 'open');
  h.advance(1);
  assert.equal(h.cb.state(), 'half_open');
  await h.ok();
  await h.ok();
  assert.equal(h.cb.state(), 'half_open');
  await h.ok();
  assert.equal(h.cb.state(), 'closed');
  assert.deepEqual(h.transitions, ['closed→open', 'open→half_open', 'half_open→closed']);
});

test('half-open: a failing trial re-opens, extra concurrent trials are rejected', async () => {
  const h = harness();
  for (let i = 0; i < 5; i += 1) await h.fail();
  h.advance(15000);
  let release;
  const gate = new Promise((r) => { release = r; });
  const slow = [1, 2, 3].map(() => h.cb.execute(() => gate));
  const fourth = await h.cb.execute(async () => 'x').catch((e) => e);
  assert.ok(fourth instanceof CircuitOpenError);
  release('done');
  await Promise.all(slow);
  assert.equal(h.cb.state(), 'closed');

  for (let i = 0; i < 5; i += 1) await h.fail();
  h.advance(15000);
  await h.fail();
  assert.equal(h.cb.state(), 'open');
  assert.deepEqual(h.transitions.slice(-3), ['closed→open', 'open→half_open', 'half_open→open']);
});

test('errors classified as non-failures do not trip the breaker', async () => {
  const h = harness({ isFailure: (e) => e.message !== 'not found' });
  for (let i = 0; i < 10; i += 1) {
    await h.cb.execute(async () => { throw new Error('not found'); }).catch(() => {});
  }
  assert.equal(h.cb.state(), 'closed');
  h.cb.execute(async () => 'ok');
  // a non-failure error during half-open counts as a successful trial
  for (let i = 0; i < 5; i += 1) await h.fail();
  h.advance(15000);
  for (let i = 0; i < 3; i += 1) await h.cb.execute(async () => { throw new Error('not found'); }).catch(() => {});
  assert.equal(h.cb.state(), 'closed');
});
