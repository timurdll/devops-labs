'use strict';

// Week 11 — circuit breaker for the orders → catalog call (docs/week11/diagrams/circuit-breaker.mmd).
//
//   CLOSED ──(failure rate ≥ 50 % over the last 20 calls, at least 10 calls,
//             or 5 consecutive failures)──────────────────────────────▶ OPEN
//   OPEN ────(15 s elapsed: next call is let through)─────────────────▶ HALF_OPEN
//   HALF_OPEN ─(3 trial calls succeed)──▶ CLOSED   ─(any trial fails)──▶ OPEN
//
// While OPEN every call is rejected immediately with CircuitOpenError: no socket, no timeout to
// wait for, no load on the sick dependency. The caller decides the fallback.

const CLOSED = 'closed';
const OPEN = 'open';
const HALF_OPEN = 'half_open';
const STATE_VALUE = { [CLOSED]: 0, [OPEN]: 1, [HALF_OPEN]: 2 };

class CircuitOpenError extends Error {
  constructor(name, retryAfterMs) {
    super(`circuit ${name} is open`);
    this.name = 'CircuitOpenError';
    this.retryAfterMs = retryAfterMs;
  }
}

function createCircuitBreaker({
  name,
  windowSize = 20,
  minimumCalls = 10,
  failureRateThreshold = 0.5,
  consecutiveFailureThreshold = 5,
  openMs = 15000,
  halfOpenCalls = 3,
  // A 404 from catalog is an answer, not a failure: only errors that say "the dependency is sick".
  isFailure = () => true,
  now = Date.now,
  onStateChange = () => {},
  onCall = () => {},
} = {}) {
  let state = CLOSED;
  let openedAt = 0;
  let window = []; // ring of booleans, true = failure
  let consecutive = 0;
  let trialsInFlight = 0;
  let trialSuccesses = 0;

  function transition(to, reason) {
    const from = state;
    if (from === to) return;
    state = to;
    if (to === OPEN) openedAt = now();
    if (to === CLOSED) {
      window = [];
      consecutive = 0;
    }
    if (to === HALF_OPEN) {
      trialsInFlight = 0;
      trialSuccesses = 0;
    }
    onStateChange({ name, from, to, reason });
  }

  function record(failed) {
    window.push(failed);
    if (window.length > windowSize) window.shift();
    consecutive = failed ? consecutive + 1 : 0;
    if (consecutive >= consecutiveFailureThreshold) {
      return transition(OPEN, `${consecutive} consecutive failures`);
    }
    if (window.length >= minimumCalls) {
      const rate = window.filter(Boolean).length / window.length;
      if (rate >= failureRateThreshold) {
        transition(OPEN, `failure rate ${Math.round(rate * 100)}% over ${window.length} calls`);
      }
    }
  }

  function currentState() {
    if (state === OPEN && now() - openedAt >= openMs) transition(HALF_OPEN, `${openMs} ms elapsed`);
    return state;
  }

  async function execute(fn) {
    const s = currentState();
    if (s === OPEN) {
      onCall({ name, outcome: 'rejected' });
      throw new CircuitOpenError(name, openMs - (now() - openedAt));
    }
    if (s === HALF_OPEN) {
      if (trialsInFlight >= halfOpenCalls) {
        onCall({ name, outcome: 'rejected' });
        throw new CircuitOpenError(name, 0);
      }
      trialsInFlight += 1;
    }

    let result;
    try {
      result = await fn();
    } catch (err) {
      const failed = isFailure(err);
      onCall({ name, outcome: failed ? 'failure' : 'success' });
      if (s === HALF_OPEN && state === HALF_OPEN) {
        if (failed) transition(OPEN, 'trial call failed');
        else afterTrialSuccess();
      } else if (state === CLOSED) {
        record(failed);
      }
      throw err;
    }
    onCall({ name, outcome: 'success' });
    if (s === HALF_OPEN && state === HALF_OPEN) afterTrialSuccess();
    else if (state === CLOSED) record(false);
    return result;
  }

  function afterTrialSuccess() {
    trialSuccesses += 1;
    if (trialSuccesses >= halfOpenCalls) transition(CLOSED, `${halfOpenCalls} trial calls succeeded`);
  }

  return { execute, state: currentState, name };
}

module.exports = { createCircuitBreaker, CircuitOpenError, CLOSED, OPEN, HALF_OPEN, STATE_VALUE };
