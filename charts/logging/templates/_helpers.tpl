{{- define "logging.selectorLabels" -}}
app.kubernetes.io/name: fluentd
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "logging.labels" -}}
{{ include "logging.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}
