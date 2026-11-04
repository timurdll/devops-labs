'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { createMetrics } = require('../src/telemetry/metrics');

const SPAN = { traceId: '4bf92f3577b34da6a3ce929d0e0e4736', spanId: '00f067aa0ba902b7', traceFlags: 1 };

test('startRequest records a RED histogram sample with a trace exemplar', async () => {
  const m = createMetrics({ service: 'svc', collectDefaults: false });
  const end = m.startRequest('GET', SPAN);
  end('/api/x/:id', 200);
  m.startRequest('GET', SPAN)('/api/x/:id', 503);

  const text = await m.registry.metrics();
  assert.match(m.contentType, /openmetrics/);
  assert.match(
    text,
    /http_server_request_duration_seconds_count\{service="svc",http_request_method="GET",http_route="\/api\/x\/:id",http_response_status_code="200"\} 1/,
  );
  assert.match(text, /_count\{[^}]*http_response_status_code="503"\} 1/);
  assert.match(text, /# \{trace_id="4bf92f3577b34da6a3ce929d0e0e4736",span_id="00f067aa0ba902b7"\}/);
  assert.match(text, /http_server_active_requests\{http_request_method="GET",service="svc"\} 0/);
});

test('requests without a valid span carry no exemplar', async () => {
  const m = createMetrics({ service: 'svc', collectDefaults: false });
  m.startRequest('POST', undefined)('/a', 201);
  m.startRequest('POST', { traceId: '0'.repeat(32), spanId: '0'.repeat(16), traceFlags: 0 })('/a', 201);
  const text = await m.registry.metrics();
  assert.match(text, /_count\{service="svc",http_request_method="POST",http_route="\/a",http_response_status_code="201"\} 2/);
  assert.doesNotMatch(text, /trace_id=/);
});

test('active requests gauge counts in-flight requests', async () => {
  const m = createMetrics({ service: 'svc', collectDefaults: false });
  const end = m.startRequest('GET');
  assert.match(await m.registry.metrics(), /http_server_active_requests\{http_request_method="GET",service="svc"\} 1/);
  end('/a', 200);
  assert.match(await m.registry.metrics(), /http_server_active_requests\{http_request_method="GET",service="svc"\} 0/);
});

test('default process metrics are collected unless disabled', async () => {
  const m = createMetrics({ service: 'svc' });
  assert.match(await m.registry.metrics(), /process_cpu_seconds_total/);
});
