{{/*
Labels shared by every object. Selector labels stay limited to app.kubernetes.io/name so that the
selectors are identical to the Week 7 manifests (Deployment selectors are immutable).
*/}}
{{- define "shoplite.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/part-of: shoplite
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
shoplite.io/environment: {{ required "global.environment is required (dev|staging|prod)" .Values.global.environment }}
{{- end }}

{{/* Fully qualified in-cluster DNS name of a Service in the release namespace. */}}
{{- define "shoplite.svcHost" -}}
{{ .name }}.{{ .ctx.Release.Namespace }}.svc.cluster.local
{{- end }}

{{/*
Image reference of a stateless service.
Tag precedence: services.<name>.image.tag → image.tag → Chart.appVersion.
*/}}
{{- define "shoplite.image" -}}
{{- $svc := .svc -}}
{{- $root := .ctx -}}
{{- $tag := $svc.image.tag | default $root.Values.image.tag | default $root.Chart.AppVersion -}}
{{- if $root.Values.image.registry -}}
{{ printf "%s/%s:%s" (trimSuffix "/" $root.Values.image.registry) (base $svc.image.repository) $tag }}
{{- else -}}
{{ printf "%s:%s" $svc.image.repository $tag }}
{{- end -}}
{{- end }}

{{/* Non-secret environment of a service: chart-derived keys + services.<name>.env. */}}
{{- define "shoplite.serviceEnv" -}}
{{- $name := .name -}}
{{- $svc := .svc -}}
{{- $root := .ctx -}}
{{- $env := dict -}}
{{- if and $svc.database $root.Values.postgres.enabled -}}
{{- $_ := set $env "PGHOST" (include "shoplite.svcHost" (dict "name" "postgres" "ctx" $root)) -}}
{{- $_ := set $env "PGPORT" "5432" -}}
{{- $_ := set $env "PGDATABASE" $svc.database.name -}}
{{- $_ := set $env "PGUSER" $svc.database.name -}}
{{- end -}}
{{- if eq $name "orders" -}}
{{- $_ := set $env "CATALOG_URL" (printf "http://%s" (include "shoplite.svcHost" (dict "name" "catalog" "ctx" $root))) -}}
{{- end -}}
{{- if and $root.Values.telemetry.enabled $svc.instrumented -}}
{{- $_ := set $env "OTEL_SERVICE_NAME" $name -}}
{{- $_ := set $env "OTEL_EXPORTER_OTLP_ENDPOINT" $root.Values.telemetry.otlpEndpoint -}}
{{- $_ := set $env "OTEL_EXPORTER_OTLP_PROTOCOL" "http/protobuf" -}}
{{- $_ := set $env "OTEL_TRACES_SAMPLER" "parentbased_traceidratio" -}}
{{- $_ := set $env "OTEL_TRACES_SAMPLER_ARG" (toString $root.Values.telemetry.samplingRatio) -}}
{{- $_ := set $env "OTEL_PROPAGATORS" "tracecontext,baggage" -}}
{{- $_ := set $env "OTEL_METRICS_EXPORTER" "none" -}}{{/* metrics are pulled from /metrics */}}
{{- $_ := set $env "OTEL_LOGS_EXPORTER" "none" -}}
{{- /* OTEL_RESOURCE_ATTRIBUTES is set per Deployment (services.yaml): it carries the version. */ -}}
{{- end -}}
{{- toYaml (merge (deepCopy ($svc.env | default dict)) $env) -}}
{{- end }}

{{/* Init script of the postgres-init ConfigMap (database-per-service). */}}
{{- define "shoplite.postgresInitScript" -}}
#!/bin/sh
# Database-per-service: each microservice gets its own database and login role.
# Passwords are read from the Secret mounted at /run/secrets/db (never from env or args).
set -eu
{{- range $name, $svc := .Values.services }}
{{- if and $svc.enabled $svc.database }}
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
  -v pw="$(cat /run/secrets/db/{{ $svc.database.passwordKey }})" <<'EOSQL'
CREATE ROLE {{ $svc.database.name }} LOGIN PASSWORD :'pw';
CREATE DATABASE {{ $svc.database.name }} OWNER {{ $svc.database.name }};
REVOKE ALL ON DATABASE {{ $svc.database.name }} FROM PUBLIC;
EOSQL
{{- end }}
{{- end }}
{{- end }}

{{/*
Week 10: route of a VirtualService to one service. Without a canary: the whole Service. With a
canary: two DestinationRule subsets, weight = services.<name>.canary.weight percent to the canary.
*/}}
{{- define "shoplite.meshRoute" -}}
{{- $host := printf "%s.%s.svc.cluster.local" .name .ns -}}
{{- if and .svc.rollout .svc.rollout.enabled -}}
{{- /* Week 12: Argo Rollouts owns these weights at run time (Argo CD ignores them). */ -}}
- destination:
    host: {{ $host }}
    subset: stable
    port:
      number: 80
  weight: 100
- destination:
    host: {{ $host }}
    subset: canary
    port:
      number: 80
  weight: 0
{{- else if and .svc.canary .svc.canary.enabled -}}
- destination:
    host: {{ $host }}
    subset: {{ .svc.version | default "v1" }}
    port:
      number: 80
  weight: {{ sub 100 (int .svc.canary.weight) }}
- destination:
    host: {{ $host }}
    subset: {{ .svc.canary.version }}
    port:
      number: 80
  weight: {{ int .svc.canary.weight }}
{{- else -}}
- destination:
    host: {{ $host }}
    port:
      number: 80
{{- end -}}
{{- end }}

{{/* Week 10: client-side policy every caller's sidecar applies to a service (DestinationRule). */}}
{{- define "shoplite.meshTrafficPolicy" -}}
tls:
  mode: ISTIO_MUTUAL # originate mTLS with the workload certificate (explicit; auto-mTLS would too)
connectionPool:
  tcp:
    # Week 9 finding: a fetch to a missing catalog hung in TCP connect for 10 s. Envoy fails the
    # connect after this timeout instead and answers 503 (no healthy upstream).
    connectTimeout: {{ .connectTimeout }}
  {{- with .http }}
  http:
    {{- toYaml . | nindent 4 }}
  {{- end }}
outlierDetection:
  # Passive health checking: eject an endpoint that keeps failing, so one bad pod (e.g. a broken
  # canary replica) stops receiving traffic until it recovers.
  consecutive5xxErrors: {{ .outlierDetection.consecutive5xxErrors }}
  interval: {{ .outlierDetection.interval }}
  baseEjectionTime: {{ .outlierDetection.baseEjectionTime }}
  maxEjectionPercent: {{ .outlierDetection.maxEjectionPercent }}
{{- end }}
{{- /* Week 11: deadline + transport retries of one VirtualService route. */ -}}
{{- define "shoplite.meshRouteResilience" -}}
timeout: {{ .timeout }}
retries:
  attempts: {{ .retries.attempts }}
  perTryTimeout: {{ .retries.perTryTimeout }}
  retryOn: {{ .retries.retryOn }}
{{- end }}

{{- /*
Week 12: canary strategy of an Argo Rollout. Traffic is shifted by rewriting the weights of the
route named after the service in two VirtualServices: the east-west one (orders → catalog) and,
for exposed services, the edge one (gateway → catalog). Argo Rollouts pins the DestinationRule
subsets stable/canary to the pod-template hash of each ReplicaSet.
*/ -}}
{{- define "shoplite.rolloutStrategy" -}}
{{- $ro := .svc.rollout -}}
canary:
  # Keep the aborted canary pods for 30 s (logs, traces) before scaling them down.
  abortScaleDownDelaySeconds: 30
  trafficRouting:
    istio:
      virtualServices:
        - name: {{ .name }}
          routes: [{{ .name }}]
        {{- if and .svc.ingressPath .ctx.Values.ingress.enabled }}
        - name: shop-edge
          routes: [{{ .name }}]
        {{- end }}
      destinationRule:
        name: {{ .name }}
        stableSubsetName: stable
        canarySubsetName: canary
  # Background analysis from the first setWeight until 100 %: a failed AnalysisRun aborts.
  analysis:
    templates:
      - templateName: {{ .name }}-canary-health
    startingStep: 1
    args:
      - name: canary-version
        value: {{ .tag | quote }}
  steps:
    {{- range $w := $ro.steps }}
    - setWeight: {{ $w }}
    - pause: { duration: {{ $ro.pauseSeconds }}s }
    {{- end }}
{{- end }}
