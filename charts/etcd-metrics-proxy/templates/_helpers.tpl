{{- define "etcd-metrics-proxy.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "etcd-metrics-proxy.labels" -}}
{{ include "etcd-metrics-proxy.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}

{{/* Service name; also the DNS name in the serving certificate. */}}
{{- define "etcd-metrics-proxy.serviceName" -}}
etcd-metrics
{{- end }}

{{- define "etcd-metrics-proxy.serverName" -}}
{{ printf "%s.%s.svc" (include "etcd-metrics-proxy.serviceName" .) .Release.Namespace }}
{{- end }}

{{- define "etcd-metrics-proxy.tlsSecret" -}}
etcd-metrics-tls
{{- end }}
