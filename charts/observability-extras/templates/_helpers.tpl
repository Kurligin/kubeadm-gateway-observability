{{- define "observability-extras.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}

{{/* Allowed error ratio (1 - objective) of an SLO entry, e.g. "0.001". */}}
{{- define "observability-extras.sloBudget" -}}
{{ printf "%.6g" (subf 1.0 .objective) }}
{{- end }}
