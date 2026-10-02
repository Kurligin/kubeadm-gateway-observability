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

{{/* URLRewrite filter (list item): strip the matched prefix, the backend sees "/". */}}
{{- define "gateway.stripPrefixFilter" -}}
- type: URLRewrite
  urlRewrite:
    path:
      type: ReplacePrefixMatch
      replacePrefixMatch: /
{{- end }}

{{/*
Request and response header filters (list items) of an application rule.
Arguments: dict "root" $ "rule" <rule name, the value of the route header>
*/}}
{{- define "gateway.headerFilters" -}}
{{- $headers := .root.Values.app.headers -}}
- type: RequestHeaderModifier
  requestHeaderModifier:
    set:
      - name: {{ $headers.route }}
        value: {{ .rule | quote }}
- type: ResponseHeaderModifier
  responseHeaderModifier:
    set:
      - name: {{ $headers.route }}
        value: {{ .rule | quote }}
    {{- with $headers.removeFromResponse }}
    remove:
      {{- toYaml . | nindent 6 }}
    {{- end }}
{{- end }}

{{/* HTTPRoute rule timeouts. */}}
{{- define "gateway.timeouts" -}}
timeouts:
  request: {{ .Values.app.timeouts.request }}
{{- end }}

{{/* Labels Envoy Gateway puts on the proxy pods of this Gateway. */}}
{{- define "gateway.proxySelector" -}}
gateway.envoyproxy.io/owning-gateway-name: {{ .Values.gateway.name }}
gateway.envoyproxy.io/owning-gateway-namespace: {{ .Release.Namespace }}
{{- end }}
