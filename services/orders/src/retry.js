'use strict';

// Week 11 — retry with exponential backoff and full jitter (AWS Architecture Blog, "Exponential
// Backoff And Jitter"): sleep = random(0, min(cap, base · 2^attempt)). Full jitter spreads the
// retries of many clients over time, so a dependency that just recovered is not hit by a
// synchronized wave of retries.
//
// Only idempotent calls (GET product) are retried, and only for errors where another attempt can
// help (connection reset, 502/503/504). Timeouts are NOT retried: if catalog is slow, a second
// call doubles the load on it and the user waits twice as long — that case is the breaker's job.

const sleepMs = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function backoffDelay(attempt, { baseMs, maxMs, random = Math.random }) {
  return Math.floor(random() * Math.min(maxMs, baseMs * 2 ** attempt));
}

async function retry(
  fn,
  {
    attempts = 3,
    baseMs = 50,
    maxMs = 500,
    shouldRetry = () => true,
    random = Math.random,
    sleep = sleepMs,
    onRetry = () => {},
  } = {},
) {
  for (let attempt = 0; ; attempt += 1) {
    try {
      return await fn(attempt);
    } catch (err) {
      if (attempt + 1 >= attempts || !shouldRetry(err)) throw err;
      const delay = backoffDelay(attempt, { baseMs, maxMs, random });
      onRetry({ attempt: attempt + 1, delay, err });
      await sleep(delay);
    }
  }
}

module.exports = { retry, backoffDelay };
