{{- define "gateway.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}

{{- define "gateway.appHostname" -}}
{{ printf "%s.%s" .Values.app.host .Values.domain }}
{{- end }}

{{/* parentRefs of a route attached to the HTTPS listener. */}}
{{- define "gateway.httpsParent" -}}
parentRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: {{ .Values.gateway.name }}
    sectionName: https
{{- end }}

{{/* Arguments: dict "service" <name> "namespace" <ns> "port" <port> ["weight" <n>] */}}
{{- define "gateway.backendRef" -}}
- group: ""
  kind: Service
  name: {{ .service }}
  namespace: {{ .namespace }}
  port: {{ .port }}
  {{- if hasKey . "weight" }}
  weight: {{ .weight }}
  {{- end }}
{{- end }}

{{/* URLRewrite filter: strip the matched prefix, the backend sees "/". */}}
{{- define "gateway.stripPrefix" -}}
filters:
  - type: URLRewrite
    urlRewrite:
      path:
        type: ReplacePrefixMatch
        replacePrefixMatch: /
{{- end }}
