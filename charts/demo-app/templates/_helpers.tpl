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
        '"user_agent":"$http_user_agent",'
        '"bytes":$body_bytes_sent,'
        '"host":"$host",'
        '"version":"{{ .item.version }}",'
        '"pod":"$hostname"'
    '}';
    access_log /dev/stdout json_access;

    keepalive_timeout 65;

    # Request counters are kept per key: kubelet probes ("probes") apart
    # from application traffic ("app"), see status_zone below.
    map $uri $status_zone_key {
        /healthz probes;
        default  app;
    }

    server {
        listen {{ .root.Values.ports.http }} default_server;
        server_name _;
        # Request and response counters for /p8s: http server zones "app"
        # (application traffic) and "probes" (kubelet health checks).
        status_zone $status_zone_key zone=server:2;

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
