{{- define "demo-app.selectorLabels" -}}
app.kubernetes.io/name: {{ .root.Chart.Name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .item.name }}
{{- end }}

{{/* Arguments: dict "root" $ "item" <entry of .Values.versions> */}}
{{- define "demo-app.labels" -}}
{{ include "demo-app.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .root.Chart.Name .root.Chart.Version }}
version: {{ .item.version }}
{{- end }}

{{/* Angie configuration for one version. */}}
{{- define "demo-app.angieConf" -}}
worker_processes {{ .root.Values.angie.workerProcesses }};
pid /run/angie.pid;
error_log stderr notice;

events {
    worker_connections {{ .root.Values.angie.workerConnections }};
}

http {
    include /etc/angie/mime.types;
    default_type text/plain;
    server_tokens off;

    # Metric templates for the /p8s endpoint.
    include /etc/angie/prometheus_all.conf;

    # Read-only root filesystem: temporary files go to an emptyDir.
    client_body_temp_path /var/cache/angie/client_temp;
    proxy_temp_path /var/cache/angie/proxy_temp;
    fastcgi_temp_path /var/cache/angie/fastcgi_temp;
    uwsgi_temp_path /var/cache/angie/uwsgi_temp;
    scgi_temp_path /var/cache/angie/scgi_temp;

    # W3C trace context: the trace ID of "traceparent"
    # (version-traceid-parentid-flags), set by the gateway's tracing.
    # Logged as trace_id, the same field the gateway's access log and
    # Grafana's trace-to-logs links use. Only for sampled traces (flag bit
    # 0 set, i.e. an odd last digit): an unsampled trace is never stored,
    # so its ID would lead nowhere. Invalid per W3C (version ff, all-zero
    # trace or parent ID) and anything else: empty. A traceparent the client
    # sent itself is logged too, also with tracing off at the gateway.
    map $http_traceparent $trace_id {
        "~^(?!ff)[0-9a-f]{2}-(?!0{32})(?<tid>[0-9a-f]{32})-(?!0{16})[0-9a-f]{16}-[0-9a-f][13579bdf]$" $tid;
        default "";
    }

    # One JSON object per line; x_request_id is set by the gateway.
    log_format json_access escape=json '{'
        '"time":"$time_iso8601",'
        '"method":"$request_method",'
        '"uri":"$request_uri",'
        '"status":$status,'
        '"request_time":$request_time,'
        '"remote_addr":"$remote_addr",'
        '"x_forwarded_for":"$http_x_forwarded_for",'
        '"x_request_id":"$http_x_request_id",'
        '"trace_id":"$trace_id",'
        '"user_agent":"$http_user_agent",'
        '"bytes":$body_bytes_sent,'
        '"host":"$host",'
        '"gateway_route":"$http_x_gateway_route",'
        '"traffic":"$traffic_kind",'
        '"version":"{{ .item.version }}",'
        '"pod":"$hostname"'
    '}';
    access_log /dev/stdout json_access;

    keepalive_timeout 65;

    # Copies of requests mirrored by the gateway arrive on the shadow port
    # (Service <name>-shadow).
    map $server_port $traffic_kind {
        {{ .root.Values.ports.shadow }}  shadow;
        default app;
    }

    # Request counters are kept per key: kubelet probes ("probes") and
    # mirrored copies ("shadow") apart from application traffic ("app"),
    # see status_zone below.
    map $uri $status_zone_key {
        /healthz probes;
        default  $traffic_kind;
    }

    server {
        listen {{ .root.Values.ports.http }} default_server;
        listen {{ .root.Values.ports.shadow }};
        server_name _;
        # Request and response counters for /p8s: http server zones "app"
        # (application traffic), "shadow" (mirrored copies) and "probes"
        # (kubelet health checks).
        status_zone $status_zone_key zone=server:3;

        # Internal detail for operators; the gateway removes it from the
        # responses it sends to clients (ResponseHeaderModifier).
        add_header X-Backend-Pod $hostname always;
        # Version of this backend; the gateway records it in its trace span
        # (tag backend.version).
        add_header X-App-Version {{ .item.version }} always;

        location = /healthz {
            access_log off;
            return 200 "ok\n";
        }

        location / {
            return 200 "Hello World! version={{ .item.version }} pod=$hostname\n";
        }

        # Failure on demand, for checking error logs and 5xx alerting: the
        # upstream is unreachable, so Angie answers 502 and writes an
        # "[error] ... connect() failed" line to its error log (stderr).
        # Like any proxied request, it would pass the request headers
        # (traceparent included) on to the upstream unchanged.
        location = /broken {
            proxy_pass http://127.0.0.1:{{ .root.Values.brokenUpstreamPort }};
        }
    }

    server {
        listen {{ .root.Values.ports.metrics }};
        server_name _;
        access_log off;

        location = /p8s {
            prometheus all;
        }
    }
}
{{- end }}
