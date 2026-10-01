{{- define "network-policies.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}

{{/* One NetworkPolicyPeer per source. Arguments: dict "root" $ "source" <name> */}}
{{- define "network-policies.peer" -}}
{{- if eq .source "same-namespace" }}
- podSelector: {}
{{- else }}
{{- $peer := get .root.Values.peers .source }}
{{- if not $peer }}
{{- fail (printf "unknown peer %q (not in .Values.peers)" .source) }}
{{- end }}
- namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: {{ $peer.namespace }}
  podSelector:
    matchLabels:
      {{- toYaml $peer.labels | nindent 6 }}
{{- end }}
{{- end }}
