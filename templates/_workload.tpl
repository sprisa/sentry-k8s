{{/*
Generic Deployment renderer for Sentry- and Snuba-image workloads (consumers,
forwarders, schedulers). Keeps the ~40 consumer templates DRY.

Input dict:
  root           : $ (top context)
  name           : short component name, e.g. "events-consumer"
  component      : the values map for this component (gated by its .enabled flag)
  imageKey       : "sentry" | "snuba"
  command        : list of args passed to the image entrypoint
  healthcheckFile: bool, use the /tmp/health.txt liveness probe
*/}}
{{- define "sentry.workload" -}}
{{- $root := .root -}}
{{- $c := .component -}}
{{- $enabled := include "sentry.enabled" (dict "component" $c) -}}
{{- if eq $enabled "true" -}}
{{- $fullname := include "sentry.fullname" $root -}}
{{- $compName := printf "%s-%s" $fullname .name -}}
{{- $isSnuba := eq .imageKey "snuba" -}}
{{- $deps := ternary (list "clickhouse" "kafka" "redis") (list "kafka" "redis" "postgres") $isSnuba -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ $compName }}
  labels:
    {{- include "sentry.labels" $root | nindent 4 }}
    app.kubernetes.io/component: {{ .name }}
spec:
  replicas: {{ $c.replicas | default 1 }}
  revisionHistoryLimit: {{ $root.Values.revisionHistoryLimit }}
  selector:
    matchLabels:
      {{- include "sentry.selectorLabels" $root | nindent 6 }}
      app.kubernetes.io/component: {{ .name }}
  template:
    metadata:
      labels:
        {{- include "sentry.selectorLabels" $root | nindent 8 }}
        app.kubernetes.io/component: {{ .name }}
        {{- with $c.podLabels }}{{ toYaml . | nindent 8 }}{{- end }}
      annotations:
        checksum/config: {{ include (print $root.Template.BasePath "/sentry/configmap.yaml") $root | sha256sum }}
        {{- with $c.podAnnotations }}{{ toYaml . | nindent 8 }}{{- end }}
    spec:
      serviceAccountName: {{ include "sentry.serviceAccountName" $root }}
      {{- include "sentry.imagePullSecrets" $root | nindent 6 }}
      {{- include "sentry.scheduling" (dict "root" $root "component" $c) | nindent 6 }}
      initContainers:
        {{- include "sentry.waitForInfra" (dict "root" $root "deps" $deps) | nindent 8 }}
        {{- if not $isSnuba }}
        {{- include "sentry.pipInstallInit" $root | nindent 8 }}
        {{- end }}
      containers:
        - name: {{ .name }}
          image: "{{ include "sentry.image" (dict "root" $root "key" .imageKey "override" $c.image) }}"
          imagePullPolicy: {{ include "sentry.imagePullPolicy" (dict "root" $root "key" .imageKey "override" $c.image) }}
          args:
            {{- toYaml .command | nindent 12 }}
          env:
            {{- if $isSnuba }}
            {{- include "sentry.snubaEnv" $root | nindent 12 }}
            {{- else }}
            {{- include "sentry.sentryEnv" $root | nindent 12 }}
            {{- end }}
            {{- with $c.env }}{{ toYaml . | nindent 12 }}{{- end }}
          {{- if not $isSnuba }}
          volumeMounts:
            - name: config
              mountPath: /etc/sentry
            - name: sentry-data
              mountPath: /data
          {{- end }}
          {{- if .healthcheckFile }}
          {{- include "sentry.fileLivenessProbe" $root | nindent 10 }}
          {{- end }}
          {{- with $c.containerSecurityContext }}
          securityContext:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with $c.resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
      {{- if not $isSnuba }}
      volumes:
        - name: config
          configMap:
            name: {{ $fullname }}-sentry-config
        {{- include "sentry.dataVolume" $root | nindent 8 }}
      {{- end }}
{{- end -}}
{{- end -}}
