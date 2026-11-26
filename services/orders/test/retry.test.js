'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { retry, backoffDelay } = require('../src/retry');

test('backoff grows exponentially, is capped and fully jittered', () => {
  const o = { baseMs: 50, maxMs: 500 };
  assert.deepEqual([0, 1, 2, 3, 4, 5].map((a) => backoffDelay(a, { ...o, random: () => 0.999999 })), [49, 99, 199, 399, 499, 499]);
  assert.equal(backoffDelay(3, { ...o, random: () => 0 }), 0);
});

test('retries until success, sleeping the jittered delay', async () => {
  const sleeps = [];
  let n = 0;
  const result = await retry(async () => { n += 1; if (n < 3) throw new Error('reset'); return 'ok'; }, {
    random: () => 0.5, sleep: async (ms) => sleeps.push(ms),
  });
  assert.equal(result, 'ok');
  assert.deepEqual(sleeps, [25, 50]);
});

test('gives up after the last attempt and never retries non-retryable errors', async () => {
  let n = 0;
  const sleep = async () => {};
  await assert.rejects(retry(async () => { n += 1; throw new Error('reset'); }, { attempts: 3, sleep }), /reset/);
  assert.equal(n, 3);
  n = 0;
  await assert.rejects(retry(async () => { n += 1; throw new Error('timeout'); }, { shouldRetry: () => false, sleep }));
  assert.equal(n, 1);
});

test('default sleep really waits', async () => {
  let n = 0;
  const started = Date.now();
  await retry(async () => { n += 1; if (n === 1) throw new Error('x'); }, { baseMs: 20, maxMs: 20, random: () => 0.99 });
  assert.ok(Date.now() - started >= 15);
});
