'use strict';

const client = require('prom-client');
const { trace, isSpanContextValid } = require('@opentelemetry/api');
const { STATE_VALUE } = require('../circuit-breaker');

// RED metrics, named after the OpenTelemetry HTTP semantic conventions
// (http.server.request.duration → http_server_request_duration_seconds). One histogram gives all
// three signals:  Rate     = rate(…_count)
//                 Errors   = rate(…_count{http_response_status_code=~"5.."})
//                 Duration = histogram_quantile(0.95, rate(…_bucket))
const DURATION_BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5];

function activeSpanContext() {
  const span = trace.getActiveSpan();
  return span ? span.spanContext() : undefined;
}

function createMetrics({ service, collectDefaults = true } = {}) {
  const registry = new client.Registry();
  // Exemplars (a trace_id attached to a histogram sample) only exist in the OpenMetrics format.
  registry.setContentType(client.Registry.OPENMETRICS_CONTENT_TYPE);
  registry.setDefaultLabels({ service });
  if (collectDefaults) client.collectDefaultMetrics({ register: registry });

  const duration = new client.Histogram({
    name: 'http_server_request_duration_seconds',
    help: 'Duration of inbound HTTP requests.',
    labelNames: ['http_request_method', 'http_route', 'http_response_status_code'],
    buckets: DURATION_BUCKETS,
    enableExemplars: true,
    registers: [registry],
  });
  const active = new client.Gauge({
    name: 'http_server_active_requests',
    help: 'Inbound HTTP requests currently being served.',
    labelNames: ['http_request_method'],
    registers: [registry],
  });

  // Outbound calls to dependencies (orders → catalog): the same RED view one hop further.
  const clientDuration = new client.Histogram({
    name: 'http_client_request_duration_seconds',
    help: 'Duration of outbound HTTP requests to dependencies.',
    labelNames: ['server_address', 'http_response_status_code'],
    buckets: DURATION_BUCKETS,
    registers: [registry],
  });

  // Week 11: resilience patterns made visible (alert CircuitBreakerOpen, Grafana panel).
  const breakerState = new client.Gauge({
    name: 'circuit_breaker_state',
    help: 'Circuit breaker state: 0 closed, 1 open, 2 half-open.',
    labelNames: ['name'],
    registers: [registry],
  });
  const breakerTransitions = new client.Counter({
    name: 'circuit_breaker_transitions_total',
    help: 'Circuit breaker state transitions.',
    labelNames: ['name', 'from', 'to'],
    registers: [registry],
  });
  const breakerCalls = new client.Counter({
    name: 'circuit_breaker_calls_total',
    help: 'Calls through a circuit breaker by outcome (success, failure, rejected).',
    labelNames: ['name', 'outcome'],
    registers: [registry],
  });
  const fallbacks = new client.Counter({
    name: 'dependency_fallback_total',
    help: 'Dependency calls answered by a fallback, by cause and result (cache_hit, cache_miss).',
    labelNames: ['dependency', 'reason', 'result'],
    registers: [registry],
  });
  const retries = new client.Counter({
    name: 'dependency_retries_total',
    help: 'Retried dependency calls.',
    labelNames: ['dependency'],
    registers: [registry],
  });
  breakerState.set({ name: 'catalog' }, 0);

  function observeBreakerState({ name, from, to }) {
    breakerState.set({ name }, STATE_VALUE[to]);
    breakerTransitions.inc({ name, from, to });
  }
  function observeBreakerCall({ name, outcome }) {
    breakerCalls.inc({ name, outcome });
  }
  function observeFallback(dependency, reason, result) {
    fallbacks.inc({ dependency, reason, result });
  }
  function observeRetry(dependency) {
    retries.inc({ dependency });
  }

  function observeClient(serverAddress, statusCode, seconds) {
    clientDuration.observe(
      { server_address: serverAddress, http_response_status_code: String(statusCode) },
      seconds,
    );
  }

  /**
   * Call when a request arrives; call the returned function when it has been answered.
   * `http_route` must be a route template (/products/:id), never the raw path, to keep the
   * number of series bounded.
   */
  function startRequest(method, spanContext = activeSpanContext()) {
    const started = process.hrtime.bigint();
    active.inc({ http_request_method: method });
    return function end(route, statusCode) {
      active.dec({ http_request_method: method });
      const labels = {
        http_request_method: method,
        http_route: route,
        http_response_status_code: String(statusCode),
      };
      const value = Number(process.hrtime.bigint() - started) / 1e9;
      const exemplarLabels =
        spanContext && isSpanContextValid(spanContext)
          ? { trace_id: spanContext.traceId, span_id: spanContext.spanId }
          : {};
      duration.observe({ labels, value, exemplarLabels });
    };
  }

  return {
    registry,
    startRequest,
    observeClient,
    observeBreakerState,
    observeBreakerCall,
    observeFallback,
    observeRetry,
    contentType: registry.contentType,
  };
}

module.exports = { createMetrics, DURATION_BUCKETS };
