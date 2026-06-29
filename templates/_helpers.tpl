{{/*
Core helpers: names, labels, image resolution, host wiring, profile gating,
and a generic workload renderer used by all Sentry/Snuba consumer templates.
*/}}

{{- define "sentry.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "sentry.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "sentry.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Common labels. */}}
{{- define "sentry.labels" -}}
helm.sh/chart: {{ include "sentry.chart" . }}
{{ include "sentry.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "sentry.selectorLabels" -}}
app.kubernetes.io/name: {{ include "sentry.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "sentry.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "sentry.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Resolve an image reference. Input: dict "root" $ "key" "<imageKey>" "override" <component.image>.
Component-level override of repository/tag wins; tag falls back to Chart.AppVersion.
*/}}
{{- define "sentry.image" -}}
{{- $root := .root -}}
{{- $base := index $root.Values.images .key -}}
{{- $override := default (dict) .override -}}
{{- $repo := $override.repository | default $base.repository -}}
{{- $tag := $override.tag | default $base.tag | default $root.Chart.AppVersion -}}
{{- printf "%s:%s" $repo (toString $tag) -}}
{{- end -}}

{{- define "sentry.imagePullPolicy" -}}
{{- $base := index .root.Values.images .key -}}
{{- $override := default (dict) .override -}}
{{- $override.pullPolicy | default $base.pullPolicy | default "IfNotPresent" -}}
{{- end -}}

{{/* ---------- Host / endpoint wiring ---------- */}}

{{- define "sentry.clickhouse.host" -}}
{{- if .Values.clickhouse.enabled -}}
{{- printf "%s-clickhouse" (include "sentry.fullname" .) -}}
{{- else -}}
{{- .Values.externalClickhouse.host -}}
{{- end -}}
{{- end -}}

{{- define "sentry.clickhouse.httpPort" -}}
{{- if .Values.clickhouse.enabled -}}8123{{- else -}}{{ .Values.externalClickhouse.httpPort }}{{- end -}}
{{- end -}}

{{- define "sentry.clickhouse.tcpPort" -}}
{{- if .Values.clickhouse.enabled -}}9000{{- else -}}{{ .Values.externalClickhouse.tcpPort }}{{- end -}}
{{- end -}}

{{- define "sentry.clickhouse.database" -}}
{{- if .Values.clickhouse.enabled -}}default{{- else -}}{{ .Values.externalClickhouse.database | default "default" }}{{- end -}}
{{- end -}}

{{- define "sentry.clickhouse.singleNode" -}}
{{- if .Values.clickhouse.enabled -}}
{{- if and (le (int .Values.clickhouse.layout.shardsCount) 1) (le (int .Values.clickhouse.layout.replicasCount) 1) -}}true{{- else -}}false{{- end -}}
{{- else -}}
{{- .Values.externalClickhouse.singleNode -}}
{{- end -}}
{{- end -}}

{{- define "sentry.clickhouse.clusterName" -}}
{{- if .Values.clickhouse.enabled -}}{{ .Values.clickhouse.clusterName }}{{- else -}}{{ .Values.externalClickhouse.clusterName }}{{- end -}}
{{- end -}}

{{- define "sentry.redis.host" -}}
{{- if .Values.redis.enabled -}}
{{- printf "%s-redis-master" (include "sentry.fullname" .) -}}
{{- else -}}
{{- .Values.externalRedis.host -}}
{{- end -}}
{{- end -}}

{{- define "sentry.redis.port" -}}
{{- if .Values.redis.enabled -}}6379{{- else -}}{{ .Values.externalRedis.port | default 6379 }}{{- end -}}
{{- end -}}

{{/* Bundled-Redis password secret (only consulted when redis.auth.enabled). */}}
{{- define "sentry.redis.secretName" -}}
{{- if .Values.redis.auth.existingSecret -}}{{ .Values.redis.auth.existingSecret }}{{- else -}}{{ include "sentry.secretName" . }}{{- end -}}
{{- end -}}

{{- define "sentry.redis.secretKey" -}}
{{- if .Values.redis.auth.existingSecret -}}{{ .Values.redis.auth.existingSecretKey | default "redis-password" }}{{- else -}}redis-password{{- end -}}
{{- end -}}

{{- define "sentry.postgres.host" -}}
{{- if .Values.postgresql.enabled -}}
{{- printf "%s-postgresql" (include "sentry.fullname" .) -}}
{{- else -}}
{{- .Values.externalPostgresql.host -}}
{{- end -}}
{{- end -}}

{{- define "sentry.postgres.port" -}}
{{- if .Values.postgresql.enabled -}}5432{{- else -}}{{ .Values.externalPostgresql.port | default 5432 }}{{- end -}}
{{- end -}}

{{- define "sentry.postgres.database" -}}
{{- if .Values.postgresql.enabled -}}{{ .Values.postgresql.auth.database | default "sentry" }}{{- else -}}{{ .Values.externalPostgresql.database | default "sentry" }}{{- end -}}
{{- end -}}

{{- define "sentry.postgres.username" -}}
{{- if .Values.postgresql.enabled -}}{{ .Values.postgresql.auth.username | default "postgres" }}{{- else -}}{{ .Values.externalPostgresql.username | default "postgres" }}{{- end -}}
{{- end -}}

{{/* Bundled-Postgres password secret. existingSecret overrides the generated one. */}}
{{- define "sentry.postgres.secretName" -}}
{{- if .Values.postgresql.auth.existingSecret -}}{{ .Values.postgresql.auth.existingSecret }}{{- else -}}{{ include "sentry.secretName" . }}{{- end -}}
{{- end -}}

{{- define "sentry.postgres.secretKey" -}}
{{- if .Values.postgresql.auth.existingSecret -}}{{ .Values.postgresql.auth.existingSecretKey | default "postgres-password" }}{{- else -}}postgres-password{{- end -}}
{{- end -}}

{{- define "sentry.kafka.bootstrap" -}}
{{- if .Values.kafka.enabled -}}
{{- printf "%s-kafka:9092" (include "sentry.fullname" .) -}}
{{- else -}}
{{- $hosts := list -}}
{{- range .Values.externalKafka.brokers -}}
{{- $hosts = append $hosts (printf "%s:%v" .host (.port | default 9092)) -}}
{{- end -}}
{{- join "," $hosts -}}
{{- end -}}
{{- end -}}

{{- define "sentry.memcached.host" -}}
{{- if .Values.memcached.enabled -}}
{{- printf "%s-memcached:11211" (include "sentry.fullname" .) -}}
{{- else -}}
memcached:11211
{{- end -}}
{{- end -}}

{{- define "sentry.snuba.host" -}}
{{- printf "http://%s-snuba:1218" (include "sentry.fullname" .) -}}
{{- end -}}

{{- define "sentry.vroom.host" -}}
{{- printf "http://%s-vroom:8085" (include "sentry.fullname" .) -}}
{{- end -}}

{{- define "sentry.secretName" -}}
{{- printf "%s-secrets" (include "sentry.fullname" .) -}}
{{- end -}}

{{- define "sentry.storageClass" -}}
{{- .storageClass | default .root.Values.global.storageClass -}}
{{- end -}}

{{/*
Effective enabled state for a component: purely its own `enabled` flag.
Input: dict "component" <map>. Returns "true" or "".
the example values files are the presets that
toggle these flags (see examples/ and README).
*/}}
{{- define "sentry.enabled" -}}
{{- if .component.enabled -}}true{{- end -}}
{{- end -}}

{{/* Image tag actually used (for naming the bootstrap Job). */}}
{{- define "sentry.appTag" -}}
{{- .Values.images.sentry.tag | default .Chart.AppVersion -}}
{{- end -}}

{{/* ---------- Init containers ---------- */}}

{{/*
wait-for-infra init container. Input: dict "root" $ "deps" (list "clickhouse" "kafka" "redis" "postgres").
Uses busybox nc to block until each dependency accepts TCP connections.
*/}}
{{- define "sentry.waitForInfra" -}}
{{- $root := .root -}}
{{- if $root.Values.bootstrap.waitForInfra }}
- name: wait-for-infra
  image: "{{ include "sentry.image" (dict "root" $root "key" "busybox") }}"
  imagePullPolicy: {{ include "sentry.imagePullPolicy" (dict "root" $root "key" "busybox") }}
  command:
    - /bin/sh
    - -c
    - |
      set -e
      {{- range .deps }}
      {{- if eq . "clickhouse" }}
      until nc -z {{ include "sentry.clickhouse.host" $root }} {{ include "sentry.clickhouse.tcpPort" $root }}; do echo "waiting for clickhouse"; sleep 3; done
      {{- end }}
      {{- if eq . "kafka" }}
      until nc -z {{ (splitList ":" (include "sentry.kafka.bootstrap" $root)) | first }} {{ (splitList ":" (include "sentry.kafka.bootstrap" $root)) | last }}; do echo "waiting for kafka"; sleep 3; done
      {{- end }}
      {{- if eq . "redis" }}
      until nc -z {{ include "sentry.redis.host" $root }} {{ include "sentry.redis.port" $root }}; do echo "waiting for redis"; sleep 3; done
      {{- end }}
      {{- if eq . "postgres" }}
      until nc -z {{ include "sentry.postgres.host" $root }} {{ include "sentry.postgres.port" $root }}; do echo "waiting for postgres"; sleep 3; done
      {{- end }}
      {{- end }}
      echo "infra ready"
{{- end }}
{{- end -}}

{{/*
Init container that pip-installs extra Python packages into /data/custom-packages
(on the sentry-data volume; exposed via PYTHONPATH). Combines the nodestore-s3
backend requirement with any user-supplied .Values.sentry.extraPipPackages
(e.g. "sentry-auth-oidc" for SSO). Renders nothing when there is nothing to
install. Only meaningful for Sentry-image pods. Input: $ (root).
*/}}
{{- define "sentry.pipInstallInit" -}}
{{- $pkgs := list -}}
{{- if eq .Values.nodestore.backend "s3" -}}
{{- $pkgs = append $pkgs "sentry-nodestore-s3" -}}
{{- end -}}
{{- range .Values.sentry.extraPipPackages -}}
{{- $pkgs = append $pkgs . -}}
{{- end -}}
{{- if $pkgs }}
- name: install-pip-packages
  image: "{{ include "sentry.image" (dict "root" . "key" "sentry") }}"
  imagePullPolicy: {{ include "sentry.imagePullPolicy" (dict "root" . "key" "sentry") }}
  # The Sentry image runs inside a virtualenv where `pip install --user` is
  # rejected. Install into a dir on the shared sentry-data volume and expose it
  # via PYTHONPATH on the runtime pods. rm first so a persistent (filesystem
  # filestore) PVC stays idempotent across restarts.
  command:
    - /bin/sh
    - -c
    - |
      set -e
      rm -rf /data/custom-packages
      pip install --target /data/custom-packages{{ range $pkgs }} {{ . | quote }}{{ end }}
  volumeMounts:
    - name: sentry-data
      mountPath: /data
{{- end }}
{{- end -}}

{{/* ---------- Standard env blocks ---------- */}}

{{/* Env for Sentry-image workloads. Input: $ (root). */}}
{{- define "sentry.sentryEnv" -}}
- name: SENTRY_CONF
  value: /etc/sentry
# Extra pip packages are installed with `pip install --target` into this dir
# (see sentry.pipInstallInit); PYTHONPATH makes them importable at runtime.
- name: PYTHONPATH
  value: /data/custom-packages
- name: SNUBA
  value: {{ include "sentry.snuba.host" . }}
- name: VROOM
  value: {{ include "sentry.vroom.host" . }}
- name: SENTRY_EVENT_RETENTION_DAYS
  value: {{ .Values.sentry.eventRetentionDays | quote }}
- name: SENTRY_POSTGRES_HOST
  value: {{ include "sentry.postgres.host" . }}
- name: SENTRY_POSTGRES_PORT
  value: {{ include "sentry.postgres.port" . | quote }}
- name: SENTRY_DB_NAME
  value: {{ include "sentry.postgres.database" . }}
- name: SENTRY_DB_USER
  value: {{ include "sentry.postgres.username" . }}
- name: SENTRY_DB_PASSWORD
  valueFrom:
    secretKeyRef:
      {{- if .Values.postgresql.enabled }}
      name: {{ include "sentry.postgres.secretName" . }}
      key: {{ include "sentry.postgres.secretKey" . }}
      {{- else if .Values.externalPostgresql.existingSecret }}
      name: {{ .Values.externalPostgresql.existingSecret }}
      key: password
      {{- else }}
      name: {{ include "sentry.secretName" . }}
      key: external-postgres-password
      {{- end }}
- name: SENTRY_REDIS_HOST
  value: {{ include "sentry.redis.host" . }}
- name: SENTRY_REDIS_PORT
  value: {{ include "sentry.redis.port" . | quote }}
{{- if and .Values.redis.enabled .Values.redis.auth.enabled }}
- name: SENTRY_REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "sentry.redis.secretName" . }}
      key: {{ include "sentry.redis.secretKey" . }}
{{- else if and (not .Values.redis.enabled) (or .Values.externalRedis.password .Values.externalRedis.existingSecret) }}
- name: SENTRY_REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      {{- if .Values.externalRedis.existingSecret }}
      name: {{ .Values.externalRedis.existingSecret }}
      key: password
      {{- else }}
      name: {{ include "sentry.secretName" . }}
      key: external-redis-password
      {{- end }}
{{- end }}
- name: SENTRY_MEMCACHED_HOST
  value: {{ include "sentry.memcached.host" . }}
- name: SENTRY_KAFKA_BOOTSTRAP
  value: {{ include "sentry.kafka.bootstrap" . | quote }}
{{- if .Values.sentry.system.url }}
- name: SENTRY_MAIL_HOST
  value: {{ regexReplaceAll "^https?://" .Values.sentry.system.url "" | quote }}
{{- end }}
- name: SENTRY_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "sentry.secretName" . }}
      key: secret-key
- name: SENTRY_SYSTEM_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "sentry.secretName" . }}
      key: system-secret-key
{{- if .Values.sentry.jsSdk.setupAssets }}
- name: SETUP_JS_SDK_ASSETS
  value: "1"
{{- end }}
- name: SENTRY_KAFKA_MAX_POLL_INTERVAL_MS
  value: "300000"
- name: LAUNCHPAD_RPC_SHARED_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ include "sentry.secretName" . }}
      key: launchpad-rpc-shared-secret
{{- if eq .Values.filestore.backend "s3" }}
{{- if .Values.filestore.s3.existingSecret }}
- name: AWS_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ .Values.filestore.s3.existingSecret }}
      key: AWS_ACCESS_KEY_ID
- name: AWS_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.filestore.s3.existingSecret }}
      key: AWS_SECRET_ACCESS_KEY
{{- else }}
- name: AWS_ACCESS_KEY_ID
  value: {{ .Values.filestore.s3.accessKey | quote }}
- name: AWS_SECRET_ACCESS_KEY
  value: {{ .Values.filestore.s3.secretKey | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{/* Env for Snuba-image workloads. Input: $ (root). */}}
{{- define "sentry.snubaEnv" -}}
- name: SNUBA_SETTINGS
  value: self_hosted
- name: CLICKHOUSE_HOST
  value: {{ include "sentry.clickhouse.host" . }}
- name: CLICKHOUSE_PORT
  value: {{ include "sentry.clickhouse.tcpPort" . | quote }}
- name: CLICKHOUSE_HTTP_PORT
  value: {{ include "sentry.clickhouse.httpPort" . | quote }}
- name: CLICKHOUSE_DATABASE
  value: {{ include "sentry.clickhouse.database" . }}
- name: CLICKHOUSE_USER
  value: {{ if .Values.clickhouse.enabled }}default{{ else }}{{ .Values.externalClickhouse.username }}{{ end }}
- name: CLICKHOUSE_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "sentry.secretName" . }}
      key: clickhouse-password
- name: CLICKHOUSE_MAX_CONNECTIONS
  value: {{ .Values.snuba.clickhouse.maxConnections | quote }}
- name: DEFAULT_BROKERS
  value: {{ include "sentry.kafka.bootstrap" . | quote }}
- name: REDIS_HOST
  value: {{ include "sentry.redis.host" . }}
- name: REDIS_PORT
  value: {{ include "sentry.redis.port" . | quote }}
{{- if and .Values.redis.enabled .Values.redis.auth.enabled }}
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "sentry.redis.secretName" . }}
      key: {{ include "sentry.redis.secretKey" . }}
{{- else if and (not .Values.redis.enabled) (or .Values.externalRedis.password .Values.externalRedis.existingSecret) }}
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      {{- if .Values.externalRedis.existingSecret }}
      name: {{ .Values.externalRedis.existingSecret }}
      key: password
      {{- else }}
      name: {{ include "sentry.secretName" . }}
      key: external-redis-password
      {{- end }}
{{- end }}
- name: SNUBA_SETTINGS_SINGLE_NODE
  value: {{ include "sentry.clickhouse.singleNode" . | quote }}
- name: UWSGI_MAX_REQUESTS
  value: "10000"
- name: UWSGI_DISABLE_LOGGING
  value: "true"
- name: SENTRY_EVENT_RETENTION_DAYS
  value: {{ .Values.sentry.eventRetentionDays | quote }}
- name: SENTRY_KAFKA_MAX_POLL_INTERVAL_MS
  value: "300000"
{{- end -}}

{{/* File-based liveness probe used by Kafka consumers. */}}
{{- define "sentry.fileLivenessProbe" -}}
livenessProbe:
  exec:
    command:
      - python3
      - -c
      - |
        import os, sys
        try:
            os.remove('/tmp/health.txt')
        except FileNotFoundError:
            sys.exit(1)
  initialDelaySeconds: 600
  periodSeconds: 60
  timeoutSeconds: 10
  failureThreshold: 3
{{- end -}}

{{/* Common pod scheduling: nodeSelector/affinity/tolerations with global fallback. */}}
{{- define "sentry.scheduling" -}}
{{- $root := .root -}}
{{- $c := .component -}}
{{- $ns := $c.nodeSelector | default $root.Values.global.nodeSelector -}}
{{- if $ns }}
nodeSelector:
  {{- toYaml $ns | nindent 2 }}
{{- end }}
{{- if $c.affinity }}
affinity:
  {{- toYaml $c.affinity | nindent 2 }}
{{- else if .antiAffinityComponent }}
{{- /* Default soft anti-affinity for HA datastores: spread replicas across
       nodes (best-effort). Overridden entirely by an explicit component.affinity. */}}
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          topologyKey: kubernetes.io/hostname
          labelSelector:
            matchLabels:
              {{- include "sentry.selectorLabels" $root | nindent 14 }}
              app.kubernetes.io/component: {{ .antiAffinityComponent }}
{{- end }}
{{- if $c.tolerations }}
tolerations:
  {{- toYaml $c.tolerations | nindent 2 }}
{{- end }}
{{- if $c.priorityClassName }}
priorityClassName: {{ $c.priorityClassName }}
{{- end }}
{{- end -}}

{{/* The shared /data volume for Sentry pods (filestore PVC when filesystem+persistent, else emptyDir). */}}
{{- define "sentry.dataVolume" -}}
- name: sentry-data
{{- if and (eq .Values.filestore.backend "filesystem") .Values.filestore.filesystem.persistence.enabled }}
  persistentVolumeClaim:
    claimName: {{ .Values.filestore.filesystem.persistence.existingClaim | default (printf "%s-filestore" (include "sentry.fullname" .)) }}
{{- else }}
  emptyDir: {}
{{- end }}
{{- end -}}

{{- define "sentry.imagePullSecrets" -}}
{{- if .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml .Values.imagePullSecrets | nindent 2 }}
{{- end }}
{{- end -}}
