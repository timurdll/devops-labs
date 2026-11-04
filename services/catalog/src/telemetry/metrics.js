'use strict';

const client = require('prom-client');
const { trace, isSpanContextValid } = require('@opentelemetry/api');

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

  return { registry, startRequest, contentType: registry.contentType };
}

module.exports = { createMetrics, DURATION_BUCKETS };
