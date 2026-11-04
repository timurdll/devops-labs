'use strict';

// OpenTelemetry tracing. Must be required before http/pg are loaded (first line of server.js) so
// the instrumentations can patch them. Configuration comes from the standard OTEL_* variables set
// by the Helm chart: OTEL_SERVICE_NAME, OTEL_EXPORTER_OTLP_ENDPOINT, OTEL_RESOURCE_ATTRIBUTES,
// OTEL_TRACES_SAMPLER(_ARG). W3C `traceparent` is extracted from and injected into HTTP headers.
const { NodeSDK } = require('@opentelemetry/sdk-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-http');
const { HttpInstrumentation } = require('@opentelemetry/instrumentation-http');
const { PgInstrumentation } = require('@opentelemetry/instrumentation-pg');
const { UndiciInstrumentation } = require('@opentelemetry/instrumentation-undici');

const NOISE = /^\/(healthz|readyz|metrics)\b/; // probes and scrapes are not user traffic

let sdk;
if (process.env.OTEL_EXPORTER_OTLP_ENDPOINT && process.env.OTEL_SDK_DISABLED !== 'true') {
  sdk = new NodeSDK({
    traceExporter: new OTLPTraceExporter(),
    instrumentations: [
      new HttpInstrumentation({ ignoreIncomingRequestHook: (req) => NOISE.test(req.url || '') }),
      new UndiciInstrumentation(), // fetch() to catalog: client span + traceparent injection
      new PgInstrumentation({ enhancedDatabaseReporting: false }), // never record query parameters
    ],
  });
  sdk.start();
}

// Flush buffered spans on shutdown (called from the SIGTERM handler).
function shutdownTracing() {
  return sdk ? sdk.shutdown().catch(() => {}) : Promise.resolve();
}

module.exports = { shutdownTracing };
