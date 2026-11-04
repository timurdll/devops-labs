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
{{- $tag := $svc.image.tag | default $root.Values.image.tag | default $root.Chart.AppVersion -}}
{{- $_ := set $env "OTEL_SERVICE_NAME" $name -}}
{{- $_ := set $env "OTEL_EXPORTER_OTLP_ENDPOINT" $root.Values.telemetry.otlpEndpoint -}}
{{- $_ := set $env "OTEL_EXPORTER_OTLP_PROTOCOL" "http/protobuf" -}}
{{- $_ := set $env "OTEL_TRACES_SAMPLER" "parentbased_traceidratio" -}}
{{- $_ := set $env "OTEL_TRACES_SAMPLER_ARG" (toString $root.Values.telemetry.samplingRatio) -}}
{{- $_ := set $env "OTEL_PROPAGATORS" "tracecontext,baggage" -}}
{{- $_ := set $env "OTEL_METRICS_EXPORTER" "none" -}}{{/* metrics are pulled from /metrics */}}
{{- $_ := set $env "OTEL_LOGS_EXPORTER" "none" -}}
{{- $_ := set $env "OTEL_RESOURCE_ATTRIBUTES" (printf "deployment.environment.name=%s,service.namespace=shoplite,service.version=%s" $root.Values.global.environment $tag) -}}
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
